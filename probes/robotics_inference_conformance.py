from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path


def profiled_providers(profile_path: Path) -> list[str]:
    events = json.loads(profile_path.read_text(encoding="utf-8"))
    return sorted(
        {
            str(event["args"]["provider"])
            for event in events
            if isinstance(event, dict)
            and isinstance(event.get("args"), dict)
            and event["args"].get("provider")
        }
    )


def provider_options() -> tuple[dict[str, str], str | None]:
    options_file = os.environ.get("ROBOTICS_PROVIDER_OPTIONS_FILE", "").strip()
    if options_file:
        raw = Path(options_file).read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
    else:
        raw = os.environ.get("ROBOTICS_PROVIDER_OPTIONS", "").encode()
        digest = hashlib.sha256(raw).hexdigest() if raw else None
    parsed = json.loads(raw or b"{}")
    if not isinstance(parsed, dict) or not all(
        isinstance(key, str) and isinstance(value, str) for key, value in parsed.items()
    ):
        raise TypeError("provider options must be a JSON object of string values")
    return parsed, digest
