import http.server
import http.client
import os
import sys
import json
import cgi

T = os.environ.get("WORKER_TOKEN", "")
P = int(sys.argv[1])
B = int(os.environ.get("COMFY_PORT", "9188"))
LD = os.environ.get("LORA_DIR", "/comfyui/models/loras")


class Handler(http.server.BaseHTTPRequestHandler):
    def do(self):
        if T and self.headers.get("Authorization", "") != f"Bearer {T}":
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"Unauthorized")
            return

        # LoRA uploads are handled locally so the app can push adapters.
        if self.command == "POST" and self.path == "/lora/upload":
            ct = self.headers.get("Content-Type", "")
            if "multipart/form-data" in ct:
                fs = cgi.FieldStorage(
                    fp=self.rfile,
                    headers=self.headers,
                    environ={"REQUEST_METHOD": "POST", "CONTENT_TYPE": ct},
                )
                f = fs["file"]
                fn = os.path.basename(f.filename)
                p = os.path.join(LD, fn)
                os.makedirs(LD, exist_ok=True)
                with open(p, "wb") as out:
                    out.write(f.file.read())
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"name": fn, "path": p}).encode())
            else:
                self.send_response(400)
                self.end_headers()
            return

        conn = http.client.HTTPConnection("127.0.0.1", B, timeout=300)
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length > 0 else None
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in ("host", "authorization")
        }
        conn.request(self.command, self.path, body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in ("transfer-encoding",):
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_DELETE = do

    def log_message(self, *args):
        pass


http.server.HTTPServer(("0.0.0.0", P), Handler).serve_forever()
