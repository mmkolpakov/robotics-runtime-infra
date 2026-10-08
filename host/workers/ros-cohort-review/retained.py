import hashlib
import json
import sys
import urllib.parse
from pathlib import Path

run = sys.argv[1]
root = Path("/retained")
startup = root / ("startup-" + run)
control = root / ("control-" + run)
payload = root / ("raw-" + run) / "payloads"
completion = json.loads((startup / "completion.json").read_text())
refs = {}


def walk(value):
    if isinstance(value, dict):
        if {"uri", "sha256", "size_bytes"} <= value.keys():
            refs[value["uri"]] = (value["sha256"], value["size_bytes"])
        for child in value.values():
            walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)


walk(completion)
verified = []
for uri, (sha, size) in sorted(refs.items()):
    parsed = urllib.parse.urlparse(uri)
    assert parsed.scheme == "file" and not parsed.netloc, uri
    path = Path(urllib.parse.unquote(parsed.path))
    assert path.is_relative_to(root), uri
    assert path.is_file() and not path.is_symlink(), uri
    with path.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    assert actual == sha and path.stat().st_size == size, uri
    verified.append({"uri": uri, "sha256": sha, "size_bytes": size})
files = []
for path in sorted(startup.glob("*.json")) + sorted(
    (control / "phases").glob("*.json")
):
    value = json.loads(path.read_text())
    row = {
        "path": str(path),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "size_bytes": path.stat().st_size,
    }
    if isinstance(value, dict) and "stdout" in value:
        row.update(
            {
                "exitCode": value.get("exitCode"),
                "ok": value.get("ok"),
                "timedOut": value.get("timedOut"),
                "canceled": value.get("canceled"),
            }
        )
        try:
            row["native"] = json.loads(value["stdout"])
        except (ValueError, TypeError):
            if any(
                name in path.name
                for name in [
                    "canonical",
                    "create-ack",
                    "asset",
                    "native-urdf",
                    "strict-stepper",
                ]
            ):
                row["stdout"] = value["stdout"][-20000:]
                row["stderr"] = value.get("stderr", "")[-1000:]
    elif path.name in [
        "joint-result.json",
        "readiness-snapshot.json",
        "completion-retention-audit.json",
    ]:
        row["value"] = value
    files.append(row)
provider = {}
for path in sorted((payload / "provider").glob("*.json")):
    provider[path.name] = {
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "size_bytes": path.stat().st_size,
        "value": json.loads(path.read_text()),
    }
assert completion["status"] == "passed" and not completion["errors"]
assert all(
    row["attempted"] and row["released"] and not row.get("cleanupError")
    for row in completion["resourceOutcomes"]
)
mounts = Path("/proc/self/mountinfo").read_text().splitlines()
source_mount = any(line.split()[4] == "/run/robotics" for line in mounts)
assert not source_mount
print(
    json.dumps(
        {
            "runId": run,
            "completionStatus": completion["status"],
            "errors": completion["errors"],
            "resourceOutcomes": completion["resourceOutcomes"],
            "phases": completion["phases"],
            "verifiedRefCount": len(verified),
            "verifiedRefs": verified,
            "sourceMountPresent": source_mount,
            "files": files,
            "provider": provider,
        },
        indent=2,
    )
)
