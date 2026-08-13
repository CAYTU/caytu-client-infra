"""Fake IMDS + platform, so enrolment can be exercised without an EC2 instance.

Reads a comma-separated list of HTTP statuses from argv[2] and returns them to
successive enrolment POSTs, so retry behaviour is scriptable.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
PLAN = sys.argv[2].split(",")
CALLS = {"n": 0}

DOC = json.dumps({
    "accountId": "688544396352",
    "instanceId": "i-0fake",
    "region": "us-east-1",
    "pendingTime": "2026-08-13T09:00:00Z",
})


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_PUT(self):
        self._send(200, "fake-imds-token")

    def do_GET(self):
        if self.path.endswith("/document"):
            return self._send(200, DOC)
        if self.path.endswith("/rsa2048"):
            return self._send(200, "FAKESIGNATURE")
        self._send(404, "{}")

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        i = CALLS["n"]
        CALLS["n"] += 1
        code = int(PLAN[i]) if i < len(PLAN) else int(PLAN[-1])

        # Recorded so the test can assert how many attempts were made.
        with open(sys.argv[3], "w") as f:
            f.write(str(CALLS["n"]))

        if code == 200:
            return self._send(200, json.dumps({
                "token": "tok-abc",
                "organizationId": "org-123",
                "tokenExpiresAt": "2026-09-13T00:00:00Z",
            }))
        msgs = {
            403: "That instance launched too long ago to enrol with its identity document.",
            429: "Too many requests",
            503: "upstream unavailable",
        }
        self._send(code, json.dumps({"errors": [{"message": msgs.get(code, "error")}]}))


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
