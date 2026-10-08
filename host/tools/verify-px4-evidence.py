"""Recheck actual retained source bytes and native cleanup facts."""

from __future__ import annotations
import hashlib
import json
import socket
import subprocess
from pathlib import Path
from urllib.parse import urlparse, unquote

root = Path(__file__).resolve().parents[2]
proof = max(
    (
        p
        for p in (root / "artifacts/px4").glob("native-*")
        if p.is_dir() and (p / "run-completion.json").exists()
    ),
    key=lambda p: p.stat().st_mtime,
)
completion = json.loads((proof / "run-completion.json").read_text())
assert completion["status"] == "passed", completion["errors"]
assert any(
    p["phase"] == "disposing" and p["status"] == "passed" for p in completion["phases"]
)
assert all(
    p["attempted"] and p["released"] and not p.get("cleanupError")
    for p in completion["resourceOutcomes"]
)
unique = {}
for ref in completion["evidenceRefs"]:
    unique[ref["uri"]] = ref
for uri, ref in unique.items():
    parsed = urlparse(uri)
    assert parsed.scheme == "file"
    path = Path(unquote(parsed.path))
    data = path.read_bytes()
    assert (
        len(data) == ref["size_bytes"]
        and hashlib.sha256(data).hexdigest() == ref["sha256"]
    ), path
cleanup = [r for r in unique if r.endswith("/engine-cleanup.json")]
assert len(cleanup) == 1
provider = Path(unquote(urlparse(cleanup[0]).path)).parent
facts = json.loads((provider / "engine-cleanup.json").read_text())
assert (
    facts["released"]
    and not facts["observed"]["containers"]
    and not facts["observed"]["networks"]
)
assert json.loads((provider / "native-logger-stop.json").read_text())["ok"]
manifest = json.loads(
    (provider / "retained-native-logs/export-manifest.json").read_text()
)
assert manifest["status"] == "complete" and manifest["entries"]
for entry in manifest["entries"]:
    copied = (provider / "retained-native-logs" / entry["relativePath"]).read_bytes()
    assert (
        hashlib.sha256(copied).hexdigest() == entry["sha256"]
        and len(copied) == entry["size_bytes"]
    )
    original = (provider / "rootfs/log" / entry["relativePath"]).read_bytes()
    assert original == copied
ready = json.loads((provider / "gz-readiness.json").read_text())
assert (
    ready["oci_init"]["sha256"]
    == "43e9b836ca7631672f12d0610cd574875b62d236dfd62e3b86751f35862e5eba"
)
last = json.loads((provider / "last-native-state.json").read_text())
assert last["pause_request"]["executed"] and last["pause_request"]["native_response"]
tail = last["statistics"][-2:]
assert (
    all(x["paused"] for x in tail)
    and tail[0]["simulation_ns"] == tail[1]["simulation_ns"]
)
try:
    sock = socket.create_connection(("127.0.0.1", 50113), timeout=2)
except OSError as error:
    connection_outcome = type(error).__name__
else:
    sock.close()
    raise AssertionError("owned gRPC endpoint still accepts connections")
listeners = subprocess.check_output(["ss", "-ltnH"], text=True, timeout=5)
assert not any(line.split()[3].endswith(":50113") for line in listeners.splitlines())
(root / "artifacts/px4/kernel-listeners-after-cleanup.txt").write_text(listeners)
result = {
    "scope": "CPU stock PX4 source simulation only",
    "proof": str(proof),
    "owner_id": completion["runId"],
    "unique_verified_refs": len(unique),
    "native_log_bytes": manifest["totalBytes"],
    "native_init_verified": True,
    "owned_engine_resources_absent": True,
    "grpc_connection_outcome": connection_outcome,
    "owned_grpc_listener_absent": True,
    "paused_native_time_quiescent": True,
}
(root / "artifacts/px4/retained-recheck.json").write_text(
    json.dumps(result, indent=2) + "\n"
)
print(json.dumps(result))
