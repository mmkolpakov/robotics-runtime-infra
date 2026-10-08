"""Regression: registered groups may outlive their root; unrelated groups stay alive."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import time
from pathlib import Path

from launcher import INIT_SHA256, group_exists, reap

actual_init = {
    "pid": 1,
    "comm": Path("/proc/1/comm").read_text().strip(),
    "executable": os.readlink("/proc/1/exe"),
    "sha256": hashlib.sha256(Path("/proc/1/exe").read_bytes()).hexdigest(),
}
assert actual_init["sha256"] == INIT_SHA256
foreign = subprocess.Popen(["sleep", "20"], start_new_session=True)
results = []
try:
    for name, command in [
        ("exited-root-live-group", ["/bin/sh", "-c", "sleep 20 &"]),
        (
            "exited-root-term-resistant-child",
            [
                "python3",
                "-c",
                (
                    "import os,signal,time; p=os.fork(); "
                    "os._exit(0) if p else None; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(20)"
                ),
            ],
        ),
    ]:
        process = subprocess.Popen(command, start_new_session=True)
        process.wait(timeout=2)
        time.sleep(0.1)
        assert group_exists(process.pid), (
            "negative precondition needs a live descendant"
        )
        fact = reap(process)
        assert fact["reaped"] and fact["group_absent"], fact
        assert group_exists(foreign.pid), (
            "cleanup signaled an unrelated registered group"
        )
        if name.endswith("resistant-child"):
            assert fact["signals"] == ["SIGTERM", "SIGKILL"], fact
        results.append({"case": name, **fact})
finally:
    fact = reap(foreign)
    assert fact["reaped"] and fact["group_absent"], fact
print(json.dumps({"passed": True, "ociInit": actual_init, "cases": results}))
