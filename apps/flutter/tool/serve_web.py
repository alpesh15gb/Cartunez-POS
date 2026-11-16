"""Serves build/web the way the VPS does: static files with an index.html
fallback, and /api/ forwarded to a local API on the same address.

Usage: python tool/serve_web.py [port] [api_origin]
       (defaults: 3300, http://127.0.0.1:4100)
"""
import http.server
import json
import os
import sys
import urllib.error
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 3300
API = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:4100"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "web")
INSTALLATION = {"apiUrl": f"http://localhost:{PORT}/api/v1", "organizationId": "demo", "branchId": "pune"}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def _proxy(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() in ("content-type", "authorization")}
        request = urllib.request.Request(API + self.path, data=body, headers=headers, method=self.command)
        try:
            response = urllib.request.urlopen(request, timeout=30)
            status, data, kind = response.status, response.read(), response.headers.get("Content-Type")
        except urllib.error.HTTPError as error:
            status, data, kind = error.code, error.read(), error.headers.get("Content-Type")
        self.send_response(status)
        if kind:
            self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/api/"):
            return self._proxy()
        if self.path.split("?")[0] == "/installation.json":
            data = json.dumps(INSTALLATION).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            return self.wfile.write(data)
        path = self.translate_path(self.path.split("?")[0])
        if not os.path.exists(path):
            self.path = "/index.html"
        return super().do_GET()

    do_POST = do_DELETE = _proxy


http.server.ThreadingHTTPServer.allow_reuse_address = True
print(f"Serving {os.path.abspath(ROOT)} on http://localhost:{PORT} (API {API})", flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
