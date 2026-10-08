"""Observe caller input bytes and public routing fields until normal termination."""

import hashlib
import json
import os
from pathlib import Path
import signal
import threading

PUBLIC_ROUTING_FIELDS = (
    "ROS_DOMAIN_ID",
    "RMW_IMPLEMENTATION",
    "ROBOTICS_RUN_ID",
    "ROBOTICS_DOMAIN_ID",
)


def main():
    stopped = threading.Event()
    received_signal = []

    def terminate(signum, _frame):
        received_signal.append(signal.Signals(signum).name)
        stopped.set()

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    payload = Path("/consumer/opaque.bin").read_bytes()
    routing = {key: os.environ[key] for key in PUBLIC_ROUTING_FIELDS}
    print(
        json.dumps(
            {
                "phase": "ready",
                "input_sha256": hashlib.sha256(payload).hexdigest(),
                "input_size": len(payload),
                "routing": routing,
            },
            sort_keys=True,
        ),
        flush=True,
    )
    Path("/tmp/consumer-ready").touch()
    stopped.wait()
    print(
        json.dumps(
            {"phase": "terminated", "signal": received_signal[0]}, sort_keys=True
        ),
        flush=True,
    )


if __name__ == "__main__":
    main()
