"""Fixed PX4 v1.17 listener text; no process or evidence ownership."""

import math
import re

MAX_SOURCE_TIME = (1 << 64) - 1
MAX_LISTENER_BYTES = 32768


class Refused(RuntimeError):
    pass


def _finite(value):
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def parse_listener(stdout, topic, *, maximum_age_s=1.0):
    if not isinstance(stdout, str) or len(stdout.encode()) > MAX_LISTENER_BYTES:
        raise Refused("listener output exceeds bound")
    if not _finite(maximum_age_s) or not 0.000001 < maximum_age_s <= 5:
        raise Refused("invalid source age bound")
    if len(re.findall(r"^TOPIC:", stdout, re.M)) != 1 or not re.search(
        rf"^TOPIC: {re.escape(topic)}\s*$", stdout, re.M
    ):
        raise Refused("exactly one stock topic snapshot required")
    if re.search(r"(?m)^Instance |never published|ERROR|WARN", stdout):
        raise Refused("ambiguous or unavailable topic")
    fields = {}
    for line in stdout.splitlines():
        match = re.fullmatch(r"\s+([a-z][a-z0-9_]*):\s*(.*?)\s*", line)
        if match:
            key, value = match.groups()
            if key in fields:
                raise Refused("duplicate listener field: " + key)
            fields[key] = value
    stamp = re.fullmatch(
        r"([0-9]{1,20}) \(([0-9]+\.[0-9]{6}) seconds ago\)", fields.get("timestamp", "")
    )
    if not stamp:
        raise Refused("missing source timestamp and age")
    timestamp, age = int(stamp[1]), float(stamp[2])
    if (
        not 0 < timestamp <= MAX_SOURCE_TIME
        or not _finite(age)
        or age + 0.0000005 >= maximum_age_s
    ):
        raise Refused("invalid or stale source snapshot")
    parsed = {"timestamp_us": str(timestamp), "age_s": age}
    if topic == "vehicle_status":
        for key in ("arming_state", "system_id", "component_id"):
            value = fields.get(key, "")
            if not re.fullmatch(r"[0-9]{1,3}", value):
                raise Refused("missing or invalid " + key)
            parsed[key] = int(value)
        if parsed["arming_state"] not in (1, 2):
            raise Refused("unknown arming state")
    elif topic == "vehicle_land_detected":
        if fields.get("landed") not in ("True", "False"):
            raise Refused("missing native landed boolean")
        parsed["landed"] = fields["landed"] == "True"
    else:
        raise Refused("unselected listener topic")
    return parsed
