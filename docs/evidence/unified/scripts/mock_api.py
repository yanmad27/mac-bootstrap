#!/usr/bin/env python3
"""Mock Tailscale API on 127.0.0.1 for the hand-off evidence. DUMMY values only.
Records each request to a JSON-lines file with every secret redacted."""
import hashlib, json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[2]
EXPECT_SECRET = "tskey-client-DUMMYcid-DUMMYoauthsecret0001"
ACCESS = "tskey-api-DUMMYaccess0001"
MINTED = "tskey-auth-DUMMYminted0001"
MODE = sys.argv[3] if len(sys.argv) > 3 else "ok"

def rec(obj):
    with open(LOG, "a") as f:
        f.write(json.dumps(obj, sort_keys=True) + "\n")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n).decode()
        if self.path == "/api/v2/oauth/token":
            form = urllib.parse.parse_qs(body)
            ok = form.get("client_secret", [""])[0] == EXPECT_SECRET
            rec({"path": self.path, "method": "POST", "form_fields": sorted(form.keys()),
                 "grant_type": form.get("grant_type"), "client_secret_matches_expected": ok,
                 "argv_leak_check": "n/a"})
            if not ok: return self._send(401, {"message": "invalid client"})
            return self._send(200, {"access_token": ACCESS, "token_type": "Bearer", "expires_in": 3600, "scope": "auth_keys"})
        if self.path == "/api/v2/tailnet/-/keys":
            auth = self.headers.get("Authorization", "")
            ok = auth == "Bearer " + ACCESS
            try: j = json.loads(body)
            except Exception: j = {"unparsable": True}
            rec({"path": self.path, "method": "POST", "bearer_matches_expected": ok,
                 "content_type": self.headers.get("Content-Type"), "body": j})
            if MODE == "forbid": return self._send(403, {"message": "requested tags are invalid or not permitted"})
            if not ok: return self._send(401, {"message": "unauthorized"})
            return self._send(200, {"id": "kDUMMY", "key": MINTED, "created": "2026-10-01T00:00:00Z"})
        rec({"path": self.path, "unexpected": True}); self._send(404, {"message": "not found"})

def do_DELETE(self):
    auth = self.headers.get("Authorization", "")
    rec({"path": self.path, "method": "DELETE", "bearer_matches_expected": auth == "Bearer " + ACCESS})
    if self.path == "/api/v2/tailnet/-/keys/kDUMMY": return self._send(200, {})
    return self._send(404, {"message": "not found"})
H.do_DELETE = do_DELETE

srv = HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
print("mock api on 127.0.0.1:%s" % sys.argv[1], flush=True)
srv.serve_forever()
