#!/usr/bin/env node
/**
 * Provisions a cheap Vast.ai builder, runs build-in-vast.sh, streams the
 * build log over a temporary HTTP server, saves the log, and destroys the
 * instance. The GPU is not used for rendering; it only provides a linux/amd64
 * container with disk and bandwidth.
 *
 * Required env:
 *   VAST_API_KEY, GHCR_USER, GHCR_TOKEN, HF_TOKEN
 * Optional:
 *   IMAGE, DISK_GB, OFFER_ID, KEEP_INSTANCE=1
 */
import fs from "node:fs";
import zlib from "node:zlib";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const VAST = "https://console.vast.ai/api/v0";
const VAST_API_KEY = process.env.VAST_API_KEY;
const GHCR_USER = process.env.GHCR_USER || "MrGheek";
const GHCR_TOKEN = process.env.GHCR_TOKEN;
const HF_TOKEN = process.env.HF_TOKEN;
const IMAGE = process.env.IMAGE || "ghcr.io/mrgheek/kraken-ltx-comfy:latest";
const LOG_REPO = process.env.LOG_REPO || "MrGheek/kraken-build-logs";
const DISK_GB = Number(process.env.DISK_GB || 120);
const PORT = 8080;
const LOG_PATH = process.env.LOG_PATH || "/tmp/ltx-build.log";
const STALL_MS = Number(process.env.STALL_MINUTES || 15) * 60_000;
const SSH_KEY = process.env.SSH_KEY || path.join(os.homedir(), ".ssh", "id_ed25519");
const KANIKO_BIN = process.env.KANIKO_BIN || "/tmp/kaniko-executor";
const KANIKO_GZ = "/tmp/kaniko.gz";

if (!VAST_API_KEY || !GHCR_TOKEN || !HF_TOKEN) {
  console.error("Missing VAST_API_KEY, GHCR_TOKEN, or HF_TOKEN");
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function vast(path, opts = {}) {
  const res = await fetch(`${VAST}${path}`, {
    ...opts,
    headers: {
      Authorization: `Bearer ${VAST_API_KEY}`,
      Accept: "application/json",
      "Content-Type": "application/json",
      ...(opts.headers || {}),
    },
    signal: AbortSignal.timeout(60000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Vast ${path} ${res.status}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : {};
}

function unwrap(d) {
  if (!d) return null;
  if (Array.isArray(d)) return d[0] || null;
  if (d.instances) return Array.isArray(d.instances) ? d.instances[0] || null : d.instances;
  return d;
}

async function getInstance(id) {
  try {
    const inst = unwrap(await vast(`/instances/${id}/`));
    if (inst && inst.id) return inst;
  } catch {}
  const list = await vast(`/instances/`);
  const arr = list?.instances ?? list;
  return (Array.isArray(arr) ? arr : []).find((x) => String(x.id) === String(id)) || null;
}

function resolvePort(inst, port) {
  const p = inst?.ports?.[`${port}/tcp`] || inst?.ports?.[`${port}/http`] || inst?.ports?.[String(port)];
  if (Array.isArray(p) && p[0]?.HostPort) return Number(p[0].HostPort);
  if (p && typeof p === "object" && p.HostPort) return Number(p.HostPort);
  const dps = Number(inst?.direct_port_start);
  const dpe = Number(inst?.direct_port_end);
  if (dps > 0 && dpe >= dps) return port >= dps && port <= dpe ? port : dps;
  return port;
}

async function fetchGithubLog() {
  try {
    const { stdout } = await execFileAsync(
      "gh",
      ["api", "-H", "Accept: application/vnd.github.raw", `repos/${LOG_REPO}/contents/latest.log`],
      { timeout: 20000, maxBuffer: 20 * 1024 * 1024 },
    );
    return stdout;
  } catch {
    return "";
  }
}

async function resetGithubLog() {
  try {
    const { stdout } = await execFileAsync(
      "gh",
      ["api", `repos/${LOG_REPO}/contents/latest.log`, "--jq", ".sha"],
      { timeout: 20000 },
    );
    const sha = stdout.trim();
    if (!sha) return;
    await execFileAsync(
      "gh",
      ["api", "--method", "DELETE", `repos/${LOG_REPO}/contents/latest.log`, "-f", "message=reset for new build", "-f", `sha=${sha}`],
      { timeout: 20000 },
    );
  } catch {}
}

async function pickOffers() {
  if (process.env.OFFER_ID) return [{ id: Number(process.env.OFFER_ID), dph_total: NaN }];
  const q = encodeURIComponent(JSON.stringify({
    rentable: { eq: true },
    type: "on-demand",
    num_gpus: { gte: 1 },
    disk_space: { gte: DISK_GB },
    dph_total: { lte: 0.30 },
  }));
  const data = await vast(`/bundles/?q=${q}`);
  const offers = (data?.offers ?? [])
    .filter((o) => (o.reliability ?? 0) >= 0.98 && (o.inet_up ?? 0) >= 300)
    .filter((o) => !/V100/i.test(o.gpu_name ?? ""))
    .sort((a, b) => a.dph_total - b.dph_total);
  if (offers.length === 0) throw new Error("No suitable builder offers");
  return offers.slice(0, 6);
}

const onstart = `#!/bin/bash
set -euo pipefail
trap 'echo "BUILD_STATUS=failure $(date -u +%FT%TZ)"' ERR
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true
mkdir -p /workspace
cd /workspace
exec > >(tee -a /workspace/build.log) 2>&1
echo "BUILD_START $(date -u +%FT%TZ)"
(
  LOG_REPO_URL="https://$GHCR_USER:$GHCR_TOKEN@github.com/${LOG_REPO}.git"
  rm -rf /tmp/logrepo
  timeout 60 git clone --depth 1 "$LOG_REPO_URL" /tmp/logrepo >/dev/null 2>&1 || exit 0
  while true; do
    if [ -f /workspace/build.log ]; then
      sed -E 's/(hf_|ghp_)[A-Za-z0-9]+/\\1***/g' /workspace/build.log > /tmp/logrepo/latest.log 2>/dev/null || true
    fi
    cd /tmp/logrepo 2>/dev/null || exit 0
    git add latest.log >/dev/null 2>&1 || true
    git -c user.name=kraken-builder -c user.email=builder@kraken.local commit -m "log $(date -u +%FT%TZ)" >/dev/null 2>&1 || true
    git push >/dev/null 2>&1 || true
    cd /workspace
    sleep 45
  done
) &
echo "CLONE_MAIN"
rm -rf /workspace/kraken-ltx-comfy
timeout 300 git clone --depth 1 --progress https://github.com/MrGheek/kraken-ltx-comfy.git /workspace/kraken-ltx-comfy || { echo "CLONE_MAIN_FAILED"; exit 1; }
echo "CLONE_MAIN_DONE"
cd /workspace/kraken-ltx-comfy

echo "BUILD_SCRIPT_START"
bash build-in-vast.sh
echo "BUILD_STATUS=success $(date -u +%FT%TZ)"
`;

const offers = await pickOffers();
await resetGithubLog();

let offer = null;
let created = null;
for (const candidate of offers) {
  try {
    console.log(`[builder] trying offer ${candidate.id} ${candidate.gpu_name ?? ""} $${Number(candidate.dph_total).toFixed(3)}/h`);
    created = await vast(`/asks/${candidate.id}/`, {
      method: "PUT",
      body: JSON.stringify({
        image: "buildpack-deps:bookworm-scm",
        disk: DISK_GB,
        onstart,
        env: { GHCR_USER, GHCR_TOKEN, HF_TOKEN, IMAGE },
        ports: { [`${PORT}/http`]: PORT },
      }),
    });
    offer = candidate;
    break;
  } catch (err) {
    console.log(`[builder] offer ${candidate.id} unavailable: ${err.message}`);
  }
}

if (!created || !offer) throw new Error("Could not create a builder instance from any offer");
const id = created?.new_contract ?? created?.instance_id ?? created?.id;
if (!id) throw new Error(`No instance id in response: ${JSON.stringify(created).slice(0, 300)}`);
console.log(`[builder] instance ${id} created on offer ${offer.id} ${offer.gpu_name ?? ""}`);

let ip = null;
let hostPort = null;
let lastStatus = "";
const deadline = Date.now() + 75 * 60_000;
let logText = "";
let kanikoUploaded = true; // tool now comes from GitHub Pages in build-in-vast.sh
let lastLogAt = Date.now();
let lastLogLen = 0;
let stalled = false;
fs.writeFileSync(LOG_PATH, "");

while (Date.now() < deadline) {
  let inst = null;
  try {
    inst = await getInstance(id);
  } catch (err) {
    console.log(`[builder] getInstance: ${err.message}`);
  }

  if (inst) {
    const status = inst.actual_status ?? "unknown";
    if (status !== lastStatus) {
      console.log(`[builder] status=${status} msg=${String(inst.status_msg ?? "").replace(/\n/g, " ").slice(-120)}`);
      lastStatus = status;
    }
    if (!ip && inst.public_ipaddr) ip = inst.public_ipaddr;
    const p = resolvePort(inst, PORT);
    if (p > 0) hostPort = p;
    if (["exited", "stopped", "destroyed"].includes(status) && !logText) {
      console.log("[builder] instance exited before producing a log");
      break;
    }
  }

  if (ip && hostPort) {
    try {
      const res = await fetch(`http://${ip}:${hostPort}/build.log`, { signal: AbortSignal.timeout(20000) });
      if (res.ok) {
        const text = await res.text();
        if (text.length > logText.length) {
          const chunk = text.slice(logText.length);
          fs.appendFileSync(LOG_PATH, chunk);
          process.stdout.write(chunk);
          logText = text;
        }
        if (logText.includes("BUILD_STATUS=")) {
          console.log(`\n[builder] log saved to ${LOG_PATH}`);
          break;
        }
      }
    } catch {
      // log server not ready yet
    }
  }

  // Prefer SSH: Vast does not expose arbitrary HTTP ports on this image.
  if (!kanikoUploaded && inst?.ssh_host && inst?.ssh_port && lastStatus === "running") {
    try {
      if (!fs.existsSync(KANIKO_GZ)) {
        fs.writeFileSync(KANIKO_GZ, zlib.gzipSync(fs.readFileSync(KANIKO_BIN)));
      }
      const sshOpts = [
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=15",
        "-i", SSH_KEY,
      ];
      console.log("[builder] uploading kaniko via ssh stdin");
      const uploadCmd = `ssh ${sshOpts.map((x) => JSON.stringify(x)).join(" ")} -T -p ${inst.ssh_port} root@${inst.ssh_host} 'cat > /tmp/kaniko.gz' < ${JSON.stringify(KANIKO_GZ)}`;
      await execFileAsync(
        "sh",
        ["-c", uploadCmd],
        { timeout: 300000, maxBuffer: 10 * 1024 * 1024 },
      );
      await execFileAsync(
        "ssh",
        [...sshOpts, "-T", "-p", String(inst.ssh_port), `root@${inst.ssh_host}`,
          "gunzip -c /tmp/kaniko.gz > /usr/local/bin/kaniko && chmod +x /usr/local/bin/kaniko && /usr/local/bin/kaniko version"],
        { timeout: 120000, maxBuffer: 10 * 1024 * 1024 },
      );
      kanikoUploaded = true;
      console.log("[builder] kaniko uploaded and installed");
    } catch (err) {
      console.log(`[builder] kaniko upload failed: ${err.message}`);
    }
  }

  if (inst?.ssh_host && inst?.ssh_port) {
    if (lastStatus === "running") {
      try {
        const cmd = `tail -c +${logText.length + 1} /workspace/build.log 2>/dev/null || true`;
        const { stdout } = await execFileAsync(
          "ssh",
          [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=10",
            "-i", SSH_KEY,
            "-p", String(inst.ssh_port),
            `root@${inst.ssh_host}`,
            cmd,
          ],
          { timeout: 30000, maxBuffer: 10 * 1024 * 1024 },
        );
        if (stdout.length > 0) {
          fs.appendFileSync(LOG_PATH, stdout);
          process.stdout.write(stdout);
          logText += stdout;
          if (logText.includes("BUILD_STATUS=")) {
            console.log(`\n[builder] log saved to ${LOG_PATH}`);
            break;
          }
        }
      } catch {
        // SSH not ready yet or key not injected
      }
    }
  }

  const ghLog = await fetchGithubLog();
  const ghStart = (ghLog.match(/BUILD_START (\S+)/) || [])[1];
  const curStart = (logText.match(/BUILD_START (\S+)/) || [])[1];
  if (ghLog && ghStart && ghStart !== curStart) {
    logText = ghLog;
    const banner = `\n--- new build ${ghStart} ---\n`;
    fs.appendFileSync(LOG_PATH, banner + ghLog);
    process.stdout.write(banner + ghLog);
  } else if (ghLog.length > logText.length) {
    const chunk = ghLog.slice(logText.length);
    fs.appendFileSync(LOG_PATH, chunk);
    process.stdout.write(chunk);
    logText = ghLog;
  }

  if (logText.length !== lastLogLen) {
    lastLogLen = logText.length;
    lastLogAt = Date.now();
  }
  if (logText.length > 0 && Date.now() - lastLogAt > STALL_MS) {
    console.log(`[builder] STALL: no log progress for ${Math.round((Date.now() - lastLogAt) / 60000)}m; aborting`);
    stalled = true;
    break;
  }
  if (logText.length === 0 && lastStatus === "running" && Date.now() - lastLogAt > STALL_MS) {
    console.log(`[builder] STALL: no log after ${Math.round((Date.now() - lastLogAt) / 60000)}m; aborting`);
    stalled = true;
    break;
  }

  await sleep(15000);
}

const success = !stalled && logText.includes("BUILD_STATUS=success");
console.log(`[builder] result: ${success ? "SUCCESS" : "FAILURE/UNKNOWN"}`);
if (!success) {
  console.log(`[builder] last log lines:\n${logText.slice(-3000)}`);
}

if (process.env.KEEP_INSTANCE === "1") {
  console.log(`[builder] keeping instance ${id} (KEEP_INSTANCE=1)`);
} else {
  try {
    await vast(`/instances/${id}/`, { method: "DELETE" });
    console.log(`[builder] destroyed instance ${id}`);
  } catch (err) {
    console.log(`[builder] destroy failed: ${err.message}`);
  }
}

process.exit(success ? 0 : 1);
