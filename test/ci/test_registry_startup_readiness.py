"""Exercise the registry readiness command against real loopback HTTP failures."""

import contextlib
import http.server
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def readiness_command():
    lines = (ROOT / "scripts/ci/host/run-installed-legacy.sh").read_text().splitlines()
    commands = []
    for index, line in enumerate(lines):
        if not line.startswith("curl --fail "):
            continue
        parts = [line]
        while parts[-1].endswith("\\"):
            index += 1
            parts.append(lines[index])
        command = "\n".join(parts)
        if "registry-ready.json" in command:
            commands.append(command)
    if len(commands) != 1:
        raise ValueError("one existing registry readiness command required")
    curl = shutil.which("curl")
    if not curl:
        raise RuntimeError("real curl is required for registry transport tests")
    return commands[0].replace("curl ", curl + " ", 1)


@contextlib.contextmanager
def endpoint(mode):
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            reset = mode == "always-reset" or (
                mode in ("reset-once", "partial-once") and len(requests) == 1
            )
            if reset:
                if mode == "partial-once":
                    self.send_response(200)
                    self.send_header("Content-Length", "32")
                    self.end_headers()
                    self.wfile.write(b"{")
                    self.wfile.flush()
                self.connection.setsockopt(
                    socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
                )
                self.connection.close()
                self.close_connection = True
                return
            body = b"{}\n"
            self.send_response(403 if mode == "forbidden" else 200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_port, requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class RegistryStartupReadiness(unittest.TestCase):
    def execute(self, mode):
        with tempfile.TemporaryDirectory(prefix="registry-readiness-") as temporary:
            output = Path(temporary)
            with endpoint(mode) as (port, requests):
                completed = subprocess.run(
                    ["bash", "-Eeuo", "pipefail", "-c", readiness_command()],
                    env={
                        **os.environ,
                        "registry": f"127.0.0.1:{port}",
                        "output": temporary,
                    },
                    capture_output=True,
                    timeout=45,
                    check=False,
                )
            body = output / "registry-ready.json"
            diagnostic = (output / "registry-ready.stderr").read_bytes()
            return (
                completed,
                body.read_bytes() if body.exists() else b"",
                diagnostic,
                requests,
            )

    def test_connection_reset_then_success_retains_first_diagnostic(self):
        result, body, diagnostic, requests = self.execute("reset-once")
        self.assertEqual(result.returncode, 0, diagnostic)
        self.assertEqual(body, b"{}\n")
        self.assertIn(b"(56)", diagnostic)
        self.assertEqual(requests, ["/v2/", "/v2/"])

    def test_partial_transfer_is_removed_before_successful_body(self):
        result, body, diagnostic, requests = self.execute("partial-once")
        self.assertEqual(result.returncode, 0, diagnostic)
        self.assertEqual(body, b"{}\n")
        self.assertIn(b"(56)", diagnostic)
        self.assertEqual(requests, ["/v2/", "/v2/"])

    def test_persistent_connection_reset_exhausts_original_finite_attempts(self):
        result, _, diagnostic, requests = self.execute("always-reset")
        self.assertEqual(result.returncode, 56)
        self.assertIn(b"(56)", diagnostic)
        self.assertEqual(requests, ["/v2/"] * 11)

    def test_permanent_http_refusal_never_becomes_ready(self):
        result, _, diagnostic, requests = self.execute("forbidden")
        self.assertEqual(result.returncode, 22)
        self.assertIn(b"403", diagnostic)
        self.assertEqual(requests, ["/v2/"] * 11)


if __name__ == "__main__":
    unittest.main()
