"""PX4 v1.17 sampled valid-home comparisons; no native control or file opening."""

from __future__ import annotations

import math
import re
from io import BytesIO
from itertools import pairwise
from pathlib import PurePosixPath

from robotics_runtime_contracts import loads_mapping

from ._px4_listener import Refused, parse_listener

LIMIT = 1024 * 1024
ULOG_LIMIT = 64 * 1024 * 1024
PX4_SOURCE = "d6f12ad1c4f70ad3230afd7d86e971421e02fef4"
FIELDS = ("uri", "sha256", "size_bytes", "media_type")


class Unavailable(ValueError):
    """Required original evidence cannot establish this sampled measurement."""


def need(condition, reason):
    if not condition:
        raise Unavailable(reason)


def integer(value):
    need(
        isinstance(value, str) and value.isdecimal() and len(value) <= 20,
        "source timestamp is not a bounded decimal string",
    )
    return int(value)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def snapshot(record, expected_system, expected_component, *, landed=False):
    value = record["value"]
    argv = value.get("argv")
    topic = "vehicle_land_detected" if landed else "vehicle_status"
    need(
        isinstance(argv, list)
        and argv
        == [
            "/opt/px4/build/px4_sitl_default/bin/px4-listener",
            "--instance",
            "0",
            topic,
            "-n",
            "1",
        ],
        "listener invocation differs from the pinned instance/topic",
    )
    need(
        value.get("returncode") == 0 and type(value.get("returncode")) is int,
        "listener did not complete successfully",
    )
    try:
        parsed = parse_listener(value.get("stdout"), topic)
    except Refused as error:
        raise Unavailable(str(error)) from error
    start, end = (
        value.get("host_started_monotonic_ms"),
        value.get("host_finished_monotonic_ms"),
    )
    need(
        finite(start) and finite(end) and 0 <= end - start <= 3000,
        "listener invocation has no bounded host duration",
    )
    if landed:
        need(parsed["landed"] is True, "initial listener did not observe landed")
    else:
        need(
            parsed["system_id"] == expected_system
            and parsed["component_id"] == expected_component,
            "listener actor differs from the SDK identity",
        )
        if value.get("slot", "").startswith("initial-"):
            need(
                parsed["arming_state"] == 1, "initial listener did not observe disarmed"
            )
    retained = value.get("parsed", {})
    need(
        isinstance(retained, dict)
        and integer(retained.get("timestamp_us")) == integer(parsed["timestamp_us"]),
        "listener parsed timestamp differs from original stdout",
    )
    return parsed


def phase(records):
    by_kind = {}
    for record, ref in records:
        by_kind.setdefault(record["kind"], []).append((record, ref))
    identities = by_kind.get("sdk-identity", [])
    need(len(identities) == 1, "one original SDK identity is required")
    identity = identities[0][0]["value"]
    keys = (
        "source_system_id",
        "source_component_id",
        "target_system_id",
        "target_component_id",
    )
    need(
        all(type(identity.get(k)) is int and 0 < identity[k] <= 255 for k in keys),
        "SDK sender/actor identity is unavailable",
    )
    need(
        identity.get("discovered_system_ids") == [identity["target_system_id"]],
        "SDK discovery is not the sole admitted system",
    )
    slots = {}
    for record, ref in by_kind.get("listener-observation", []):
        slot = record["value"].get("slot")
        need(slot not in slots, "duplicate listener phase observation")
        slots[slot] = (record, ref)
    required = ("initial-status-a", "initial-land", "initial-status-b", "final-status")
    need(all(k in slots for k in required), "source phase boundary was not captured")
    a, ground, b, end = (slots[k][0] for k in required)
    need(
        identities[0][0]["sequence"]
        < a["sequence"]
        < ground["sequence"]
        < b["sequence"]
        < end["sequence"],
        "listener observations are not ordered",
    )
    system, component = identity["target_system_id"], identity["target_component_id"]
    snapshots = {
        slot: snapshot(slots[slot][0], system, component, landed=slot == "initial-land")
        for slot in required
    }
    ta, tb, te = (
        integer(snapshots[slot]["timestamp_us"])
        for slot in ("initial-status-a", "initial-status-b", "final-status")
    )
    clock_slots = list(required[:-1])
    if "pre-land-status" in slots:
        snapshots["pre-land-status"] = snapshot(
            slots["pre-land-status"][0], system, component
        )
        clock_slots.append("pre-land-status")
    clock_slots.append("final-status")
    intervals = [snapshots[slot]["native_print_clock_us"] for slot in clock_slots]
    need(
        all(integer(a["upper"]) < integer(b["lower"]) for a, b in pairwise(intervals)),
        "PX4 native print clock intervals do not prove progress",
    )
    need(0 < ta <= tb <= te, "PX4 publication timestamp moved backwards")
    need(tb < te, "PX4 publication window is empty")
    return by_kind, identity, slots, tb, te, snapshots


def rows(ulog, name, fields):
    matches = [d for d in ulog.data_list if d.name == name]
    need(
        len(matches) == 1 and matches[0].multi_id == 0,
        "required ULog topic/instance is missing or ambiguous: " + name,
    )
    data = matches[0].data
    need(
        all(k in data for k in fields),
        "required native ULog fields are absent: " + name,
    )
    lengths = {len(data[k]) for k in fields}
    need(
        len(lengths) == 1 and next(iter(lengths)) > 0,
        "native ULog field arrays are empty or inconsistent",
    )
    result = [
        {k: data[k][i].item() for k in fields} for i in range(next(iter(lengths)))
    ]
    boolean_fields = {
        "vehicle_global_position": {"alt_valid"},
        "home_position": {"valid_alt"},
        "vehicle_land_detected": {"landed"},
        "vehicle_command": {"from_external"},
        "vehicle_command_ack": {"from_external"},
    }.get(name, set())
    for row in result:
        for field in boolean_fields.intersection(fields):
            value = row[field]
            need(
                type(value) is int and value in (0, 1),
                "native boolean must be stock int8 zero or one: " + name + "." + field,
            )
            row[field] = value == 1
    times = [r["timestamp"] for r in result]
    event_topic = name in ("vehicle_command", "vehicle_command_ack")
    need(
        all(type(t) is int and t > 0 for t in times)
        and all(a <= b if event_topic else a < b for a, b in pairwise(times)),
        "native publication timestamps are not ordered: " + name,
    )
    return result


def altitude_samples(global_rows, home_rows, start, end):
    import numpy as np

    selected = [r for r in global_rows if start < r["timestamp"] <= end]
    need(selected, "no global estimates inside the selected source phase")
    need(
        len({r["timestamp_sample"] for r in selected}) == len(selected),
        "repeated estimator samples are not independent observations",
    )
    preceding_home = [h for h in home_rows if h["timestamp"] <= start]
    preceding_global = [g for g in global_rows if g["timestamp"] <= start]
    need(
        preceding_home and preceding_global, "phase baseline home/reset is unavailable"
    )
    home = preceding_home[-1]
    need(
        home["valid_alt"] is True and math.isfinite(home["alt"]),
        "phase baseline home is invalid",
    )
    baseline_reset = preceding_global[-1]["alt_reset_counter"]
    need(
        all(
            a["timestamp_sample"] < b["timestamp_sample"] for a, b in pairwise(selected)
        ),
        "estimator source timestamps are not strictly ordered",
    )
    need(
        all(
            h["valid_alt"] is True and math.isfinite(h["alt"])
            for h in home_rows
            if start < h["timestamp"] <= end
        ),
        "valid finite home altitude was not captured inside the measurement phase",
    )
    home_times = np.asarray([h["timestamp"] for h in home_rows], dtype=np.uint64)
    publication_times = np.asarray([r["timestamp"] for r in selected], dtype=np.uint64)
    home_indices = np.searchsorted(home_times, publication_times, side="right") - 1
    origin_index = int(home_indices[0])
    if (
        origin_index >= 0
        and home_rows[origin_index]["timestamp"] == selected[0]["timestamp"]
    ):
        origin_index -= 1
    need(origin_index >= 0, "no preceding home candidate")
    origin = home_rows[origin_index]["timestamp"]
    predecessors = [g for g in global_rows if g["timestamp"] < origin]
    need(predecessors, "home origin has no preceding global reset observation")
    predecessor = predecessors[-1]
    need(
        all(
            g["alt_reset_counter"] == predecessor["alt_reset_counter"]
            for g in global_rows
            if predecessor["timestamp"] <= g["timestamp"] <= end
        ),
        "altitude reset changed since the applied home origin",
    )
    samples = []
    for row, home_index in zip(selected, home_indices):
        sample = row["timestamp_sample"]
        need(
            type(sample) is int and start < sample <= row["timestamp"],
            "fresh publication contains a stale or invalid source sample",
        )
        need(
            row["alt_valid"] is True and math.isfinite(row["alt"]),
            "valid finite estimated altitude was not captured",
        )
        need(home_index >= 0, "no preceding home altitude")
        home = home_rows[home_index]
        need(
            home["valid_alt"] is True and math.isfinite(home["alt"]),
            "valid home altitude is unavailable",
        )
        candidates = [home]
        if home["timestamp"] == row["timestamp"]:
            need(home_index > 0, "same-tick home has no prior candidate")
            previous = home_rows[home_index - 1]
            need(
                previous["valid_alt"] is True and math.isfinite(previous["alt"]),
                "same-tick prior home candidate is invalid",
            )
            candidates.insert(0, previous)
        need(
            row["alt_reset_counter"] == baseline_reset,
            "altitude reset changed inside the measurement phase",
        )
        heights = []
        for candidate in candidates:
            millimetres = np.float32(
                np.float32(row["alt"]) - np.float32(candidate["alt"])
            ) * np.float32(1000)
            need(
                bool(np.isfinite(millimetres))
                and -2147483648 <= millimetres < 2147483648,
                "relative altitude is outside the PX4 int32 millimetre range",
            )
            height = int(millimetres)
            if height not in heights:
                heights.append(height)
        samples.append((sample, tuple(heights)))
    return samples


def altitude_condition(samples, *, refusal):
    if not refusal:
        if max(min(heights) for _time, heights in samples) >= 1200:
            return True
        if max(max(heights) for _time, heights in samples) < 1200:
            return False
        return None
    best, worst = [], []
    for first in samples[0][1]:
        best.append(
            max(
                (
                    min(abs(mm - first) for mm in heights)
                    for _time, heights in samples[1:]
                ),
                default=0,
            )
        )
        worst.append(
            max(
                (
                    max(abs(mm - first) for mm in heights)
                    for _time, heights in samples[1:]
                ),
                default=0,
            )
        )
    if min(best) > 200:
        return False
    if max(worst) <= 200 and len(samples) >= 4:
        return True
    return None


def command_phase(command_rows, ack_rows, identity, code, window):
    start, end = window
    need(code in (21, 22), "unselected native NAV command")
    relevant = [
        r
        for r in command_rows
        if start < r["timestamp"] <= end and r["command"] == code
    ]
    need(relevant, "matching PX4 received command is absent")
    expected = (
        identity["target_system_id"],
        identity["target_component_id"],
        identity["source_system_id"],
        identity["source_component_id"],
    )

    def parameters(row):
        return tuple(
            "NaN" if math.isnan(row["param" + str(i)]) else row["param" + str(i)]
            for i in range(1, 8)
        )

    first = parameters(relevant[0])
    for row in relevant:
        need(
            (math.isnan(row["param5"]) or -90 <= row["param5"] <= 90)
            and (math.isnan(row["param6"]) or -180 <= row["param6"] <= 180),
            "NAV command coordinates are outside their published ranges",
        )
        need(
            tuple(
                row[k]
                for k in (
                    "target_system",
                    "target_component",
                    "source_system",
                    "source_component",
                )
            )
            == expected
            and row["from_external"] is True,
            "received command attribution is ambiguous",
        )
        need(
            parameters(row) == first
            and all(not math.isinf(row["param" + str(i)]) for i in range(1, 8)),
            "repeated command parameters differ or are invalid",
        )
    # NaN defaults are allowed by these NAV command semantics; they are not malformed scalars.
    acknowledgements = [
        r
        for r in ack_rows
        if relevant[0]["timestamp"] <= r["timestamp"] <= end
        and r["command"] == code
        and (r["target_system"], r["target_component"]) == expected[2:]
    ]
    need(
        all(
            type(r["result"]) is int and r["result"] in range(7)
            for r in acknowledgements
        ),
        "native command acknowledgement result is unknown",
    )
    terminal = [r for r in acknowledgements if r["result"] != 5]
    need(
        terminal and len({r["result"] for r in terminal}) == 1,
        "PX4 acknowledgement is missing or ambiguous",
    )
    return relevant[0]["timestamp"], terminal[-1]["result"] == 0


def original(ref, evidence, *, maximum=LIMIT):
    need(
        isinstance(ref, dict) and all(k in ref for k in FIELDS),
        "original ArtifactRef is absent",
    )
    need(
        type(ref["size_bytes"]) is int and 0 <= ref["size_bytes"] <= maximum,
        "original artifact exceeds its policy byte bound",
    )
    matches = [
        p
        for p, link in evidence.local_files.items()
        if all(link.get(k) == ref[k] for k in FIELDS)
    ]
    need(
        len(matches) == 1,
        "original ArtifactRef is not uniquely registered at its exact URI",
    )
    return evidence.read_local(matches[0], max_raw_evidence_bytes=maximum)


def document(ref, evidence):
    return loads_mapping(original(ref, evidence), source_name="original.json")


def job(wrapper, command, owner, cid, *, status=False):
    need(
        wrapper.get("owner_id") == owner and wrapper.get("container_id") == cid,
        "logger operation belongs to another owner/actor",
    )
    invocation = wrapper.get("invocation", {})
    need(
        invocation.get("executable") == "/opt/px4/build/px4_sitl_default/bin/px4-logger"
        and invocation.get("argv") == ["--instance", "0", command],
        "unselected logger invocation",
    )
    result = wrapper.get("result", {})
    need(
        result.get("timedOut") is False
        and result.get("canceled") is False
        and type(result.get("exitCode")) is int
        and isinstance(result.get("stdout"), str)
        and isinstance(result.get("stderr"), str),
        "logger result did not settle with original bounded output",
    )
    text = result["stdout"] + result["stderr"]
    need(
        len(text.encode()) <= LIMIT
        and "timeout, forcing stop" not in text
        and not re.search(
            r"(?i)connection refused|socket|daemon|transport|timed out", text
        ),
        "logger process/transport settlement is unknown",
    )
    if status:
        need(
            result["exitCode"] != 0
            and re.fullmatch(
                r"(?:INFO\s+\[logger\]\s+)?not running\s*", result["stdout"]
            )
            is not None
            and not result["stderr"].strip(),
            "logger absence was not observed",
        )
    else:
        need(
            result.get("ok") is True and result["exitCode"] == 0,
            "logger operation did not complete successfully",
        )
    return result


def actor_facts(native, evidence, configuration, records):
    need(
        isinstance(native, dict)
        and (native.get("run_id"), native.get("domain_id"), native.get("kind"))
        == (configuration["run_id"], "px4", "native-evidence"),
        "native binding is missing or foreign",
    )
    value = native.get("value", {})
    refs = value.get("custody", {})
    need(
        isinstance(refs, dict)
        and all(
            k in refs
            for k in (
                "actor_before",
                "actor_after",
            )
        ),
        "original native custody chain is incomplete",
    )
    actors = [document(refs[k], evidence) for k in ("actor_before", "actor_after")]
    identities, engine = [], []
    first = min(integer(record["receiver_unix_ns"]) for record, _ref in records)
    last = max(integer(record["receiver_unix_ns"]) for record, _ref in records)
    for number, actor in enumerate(actors):
        need(
            actor.get("owner_id") == configuration["run_id"],
            "actor observation has another owner",
        )
        container, image = actor.get("container", {}), actor.get("image", {})
        labels = container.get("Config", {}).get("Labels", {})
        need(
            labels.get("org.robotics.runtime.run-id") == configuration["run_id"]
            and re.fullmatch(
                r"rr-px4-[a-f0-9]{24}", labels.get("com.docker.compose.project", "")
            )
            is not None
            and container.get("State", {}).get("Running") is True
            and re.fullmatch(r"[a-f0-9]{64}", container.get("Id", "")) is not None
            and re.fullmatch(r"sha256:[a-f0-9]{64}", image.get("Id", "")) is not None
            and container.get("Image") == image["Id"]
            and type(container.get("RestartCount")) is int
            and isinstance(container.get("State", {}).get("StartedAt"), str)
            and bool(container["State"]["StartedAt"]),
            "native Engine actor identity is incomplete",
        )
        engine.append(
            (
                container["Id"],
                container["Image"],
                container["RestartCount"],
                container["State"]["StartedAt"],
                labels["com.docker.compose.project"],
            )
        )
        process = document(actor.get("process_record"), evidence)
        need(
            process.get("owner_id") == configuration["run_id"]
            and process.get("container_id") == container["Id"],
            "original parent PX4 process probe belongs to another actor",
        )
        pid = process.get("px4_process", {})
        need(
            type(pid.get("pid")) is int
            and pid["pid"] > 1
            and integer(pid.get("start_ticks")) > 0
            and pid.get("instance") == 0
            and type(pid.get("instance")) is int
            and pid.get("executable") == "/opt/px4/build/px4_sitl_default/bin/px4"
            and re.fullmatch(r"[a-f0-9]{64}", pid.get("executable_sha256", ""))
            is not None,
            "PX4 process/start/executable/instance identity is unavailable",
        )
        probe_time = integer(process.get("captured_unix_ns"))
        need(
            probe_time <= first if number == 0 else probe_time >= last,
            "original parent PX4 probes do not enclose the worker journal",
        )
        identities.append(pid)
    need(
        engine[0] == engine[1] and identities[0] == identities[1],
        "PX4 actor restarted during measurement",
    )
    need(
        integer(actors[0].get("captured_unix_ns")) <= first
        and integer(actors[1].get("captured_unix_ns")) >= last,
        "actor observations do not enclose the worker journal",
    )
    return actors, engine, identities[0], records


def worker_processes(actor_data, configuration):
    _actors, _engine, identity, records = actor_data
    observed = []
    for suffix in ("before", "after"):
        matches = [
            record
            for record, _ref in records
            if record["kind"] == "actor-identity-" + suffix
        ]
        need(
            len(matches) == 1, "original worker PX4 process observation is unavailable"
        )
        value = matches[0]
        need(
            value.get("run_id") == configuration["run_id"]
            and value.get("domain_id") == "px4"
            and value.get("value") == identity,
            "parent and worker PX4 process identities differ",
        )
        observed.append(value)
    need(
        observed[0]["sequence"] < observed[1]["sequence"],
        "worker process observations are not ordered",
    )
    return observed


def exec_pair(actor_data, evidence):
    actors, engine, _identity, _records = actor_data
    after = actors[1]
    created_ref, result_ref = after.get("exec_record"), after.get("exec_result")
    need(
        isinstance(created_ref, dict) and isinstance(result_ref, dict),
        "original native exec pair is missing",
    )
    created, result = document(created_ref, evidence), document(result_ref, evidence)
    owner, cid = actors[0]["owner_id"], engine[0][0]
    execution = created.get("exec_id")
    need(
        isinstance(execution, str)
        and re.fullmatch(r"[a-f0-9]{64}", execution) is not None,
        "native exec identifier is unavailable",
    )
    need(
        all(
            item.get("owner_id") == owner
            and item.get("container_id") == cid
            and item.get("exec_id") == execution
            for item in (created, result)
        ),
        "native exec pair belongs to another owner, actor or invocation",
    )
    inspected = result.get("inspect", {})
    need(
        result.get("started") is True and result.get("stream_complete") is True,
        "created-only or partial exec is not observed settlement",
    )
    need(
        isinstance(inspected, dict)
        and inspected.get("ID") == execution
        and inspected.get("ContainerID") == cid
        and inspected.get("Running") is False
        and type(inspected.get("ExitCode")) is int,
        "native exec inspection does not establish one settled process",
    )
    return inspected["ExitCode"], result_ref


def custody(native, evidence, configuration, slots, actor_data):
    need(actor_data is not None, "original native actor custody is unavailable")
    actors, engine, _identity, _records = actor_data
    observed = worker_processes(actor_data, configuration)
    need(
        observed[0]["sequence"] < slots["initial-status-a"][0]["sequence"]
        and observed[1]["sequence"] > slots["final-status"][0]["sequence"],
        "PX4 process observations do not enclose the source phase",
    )
    value = native["value"]
    refs = value["custody"]
    need(
        all(k in refs for k in ("logger_start", "logger_stop", "export_manifest")),
        "original native custody chain is incomplete",
    )
    b, end = slots["initial-status-b"][0], slots["final-status"][0]
    start, stop = (document(refs[k], evidence) for k in ("logger_start", "logger_stop"))
    need(
        start.get("role") == "before-case" and stop.get("role") == "after-case",
        "logger operation phase is unavailable",
    )
    active = job(start, "status", configuration["run_id"], engine[0][0])
    need(
        "Full File Logging Running:" in active["stdout"]
        and re.search(r"Log file:\s*\S+", active["stdout"]) is not None,
        "active full-file logger was not observed before measurement",
    )
    job(stop, "stop", configuration["run_id"], engine[0][0])
    after = stop.get("status_after")
    need(isinstance(after, dict), "logger post-stop status is absent")
    job(after, "status", configuration["run_id"], engine[0][0], status=True)
    need(
        integer(start.get("started_unix_ns"))
        <= integer(start.get("finished_unix_ns"))
        <= integer(b["receiver_unix_ns"])
        and integer(end["receiver_unix_ns"])
        <= integer(stop.get("started_unix_ns"))
        <= integer(stop.get("finished_unix_ns"))
        <= integer(after.get("started_unix_ns"))
        <= integer(after.get("finished_unix_ns")),
        "logger operations do not enclose the case in the declared controller clock",
    )
    exported = document(refs["export_manifest"], evidence)
    uref = value.get("ulog")
    need(
        isinstance(uref, dict)
        and exported.get("version") == 1
        and exported.get("runId") == configuration["run_id"]
        and exported.get("status") == "complete",
        "closed export is unavailable or foreign",
    )
    entries = exported.get("entries", [])
    need(
        isinstance(entries, list) and 0 < len(entries) <= 2048,
        "export manifest entries are unavailable",
    )
    selected = []
    from urllib.parse import quote

    prefix = refs["export_manifest"]["uri"].rsplit("/", 1)[0] + "/"
    for entry in entries:
        relative = entry.get("relativePath")
        need(
            isinstance(relative, str)
            and relative
            and "\\" not in relative
            and not PurePosixPath(relative).is_absolute()
            and ".." not in PurePosixPath(relative).parts
            and str(PurePosixPath(relative)) == relative,
            "export path is not confined",
        )
        if prefix + quote(relative, safe="/") == uref.get("uri"):
            selected.append(entry)
    need(
        len(selected) == 1
        and (selected[0].get("sha256"), selected[0].get("size_bytes"))
        == (uref.get("sha256"), uref.get("size_bytes")),
        "original ULog differs from the retained export",
    )
    need(
        integer(stop.get("finished_unix_ns"))
        <= integer(exported.get("startedUnixNs"))
        <= integer(exported.get("completedUnixNs")),
        "ULog was exported before logger settlement",
    )
    active_path = re.search(r"Log file:\s*(\S+)", active["stdout"])[1]
    need(
        active_path.endswith("/" + selected[0].get("name", "")),
        "active logger path does not identify the retained ULog",
    )
    return uref


def serial_actions(kinds):
    issued = {}
    pending = None
    events = sorted(
        [
            (r, ref)
            for name, rows_ in kinds.items()
            if name == "action-issued"
            or name == "action-error"
            or name in {"action-arm", "action-takeoff", "action-land", "action-disarm"}
            for r, ref in rows_
        ],
        key=lambda pair: pair[0]["sequence"],
    )
    for record, ref in events:
        value, kind = record["value"], record["kind"]
        name, invocation = value.get("method"), value.get("invocation_id")
        need(
            name in {"arm", "takeoff", "land", "disarm"}
            and isinstance(invocation, str)
            and re.fullmatch(r"action-[0-9]{4}", invocation) is not None,
            "serial action identity is unavailable",
        )
        if kind == "action-issued":
            need(
                pending is None and name not in issued,
                "overlapping or repeated application invocation",
            )
            issued[name] = {"issued": record, "reference": ref, "result": None}
            pending = invocation
        else:
            need(
                name in issued
                and pending == invocation
                and issued[name]["issued"]["value"]["invocation_id"] == invocation,
                "action result has no matching serial issuance",
            )
            issued[name]["result"] = (
                value.get("sdk_result") if kind != "action-error" else None
            )
            issued[name]["settlement"] = record
            pending = None
    return issued


def sampled_facts(records, configuration, cleanup, *, evidence=None, native=None):
    names = [
        "completion",
        "command",
        "grounded",
        "disarmed",
        "postcondition",
        "cleanup",
    ]
    if configuration["case"] == "application-deadline":
        names.append("deadline")
    assessed = {
        name: (None, None, "required original fact was not captured") for name in names
    }
    kinds = {}
    for record, ref in records:
        kinds.setdefault(record["kind"], []).append((record, ref))
    results = kinds.get("controller-result", [])
    if len(results) > 1:
        raise ValueError("duplicate terminal controller records")
    if results:
        terminal, reference = results[0]
        value = terminal["value"]
        if type(value.get("complete")) is not bool or not isinstance(
            value.get("outcome"), dict
        ):
            raise ValueError("malformed terminal controller completion")
        if value["outcome"].get("case") != configuration["case"]:
            raise ValueError("controller case differs from immutable configuration")
        assessed["completion"] = (
            True if value["complete"] else None,
            reference,
            None if value["complete"] else "controller did not complete",
        )
    if cleanup:
        value, reference = cleanup
        if value.get("owner_id") != configuration["run_id"]:
            raise ValueError("cleanup belongs to another owner")
        resources = value.get("observed", {})
        if (
            type(value.get("released")) is not bool
            or not isinstance(resources.get("containers"), list)
            or not isinstance(resources.get("networks"), list)
        ):
            raise ValueError("malformed Engine cleanup observation")
        assessed["cleanup"] = (
            value["released"]
            and not resources["containers"]
            and not resources["networks"],
            reference,
            None,
        )
    if "deadline" in assessed:
        duration = kinds.get("application-deadline", [])
        if len(duration) == 1:
            value, reference = duration[0][0]["value"], duration[0][1]
            start, end = (
                value.get("started_monotonic_ms"),
                value.get("observed_monotonic_ms"),
            )
            if (
                finite(start)
                and finite(end)
                and 0 <= start <= end
                and value.get("budget_ms") == configuration["application_deadline_ms"]
                and type(value.get("budget_ms")) is int
            ):
                assessed["deadline"] = (
                    end - start >= value["budget_ms"],
                    reference,
                    None,
                )
    actor_data = None
    try:
        need(evidence is not None, "registered native evidence is unavailable")
        actor_data = actor_facts(native, evidence, configuration, records)
        exit_code, execution_ref = exec_pair(actor_data, evidence)
        if exit_code != 0:
            assessed["completion"] = (
                False,
                execution_ref,
                "observed native worker exec exited "
                + str(exit_code)
                + "; physical outcome is unknown",
            )
        elif assessed["completion"][0] is True:
            worker_processes(actor_data, configuration)
            assessed["completion"] = (True, execution_ref, None)
    except (
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        IndexError,
        OSError,
    ) as error:
        assessed["completion"] = (None, assessed["completion"][1], str(error))
    try:
        kinds, identity, slots, start, end, snapshots = phase(records)
        actions = serial_actions(kinds)
        refusal = configuration["case"] == "unarmed-refusal"
        if refusal:
            anchors = kinds.get("caller-refusal", [])
            need(len(anchors) == 1, "caller refusal anchor is unavailable")
            anchor = anchors[0][0]["receiver_monotonic_ms"]
        else:
            need(
                "arm" in actions and "settlement" in actions["arm"],
                "first dispatch settlement anchor is unavailable",
            )
            anchor = actions["arm"]["settlement"]["value"].get("dispatch_monotonic_ms")
        need(finite(anchor), "actual first-dispatch controller anchor is unavailable")
        if not refusal:
            before_dispatch = actions["arm"]["issued"]["value"].get("monotonic_ms")
            settled = actions["arm"]["settlement"]
            finished = settled["value"].get("monotonic_ms")
            need(
                finite(before_dispatch)
                and finite(finished)
                and before_dispatch
                <= anchor
                <= finished
                <= settled["receiver_monotonic_ms"],
                "first dispatch and settlement controller times are not ordered",
            )
        for slot in ("initial-status-a", "initial-land", "initial-status-b"):
            observed = slots[slot][0]["value"]
            age = snapshots[slot]["age_s"]
            began, finished = (
                observed["host_started_monotonic_ms"],
                observed["host_finished_monotonic_ms"],
            )
            need(
                began <= finished <= anchor
                and age * 1000 + 0.0005 + (finished - began) + (anchor - finished)
                < 1000,
                "initial source-age/host-observation/dispatch budget exceeded",
            )
        if refusal:
            refused = kinds.get("caller-refusal", [])
            need(
                len(refused) == 1,
                "caller no-dispatch observation is absent or ambiguous",
            )
            record, reference = refused[0]
            need(
                slots["initial-status-b"][0]["sequence"]
                < record["sequence"]
                < slots["final-status"][0]["sequence"],
                "caller refusal is outside its source observation phase",
            )
            expected = {
                "method": "takeoff",
                "boundary": "caller-precondition",
                "reason": "unarmed",
                "dispatched": False,
            }
            intended = [actions[k] for k in ("arm", "takeoff") if k in actions]
            crossed = False
            for action in intended:
                settlement = action.get("settlement", {})
                value = settlement.get("value", {})
                started = action["issued"]["value"].get("monotonic_ms")
                dispatched = value.get("dispatch_monotonic_ms")
                finished = value.get("monotonic_ms")
                captured = settlement.get("receiver_monotonic_ms")
                if (
                    all(finite(t) for t in (started, dispatched, finished, captured))
                    and started <= dispatched <= finished <= captured
                ):
                    crossed = True
            if crossed:
                assessed["command"] = (
                    False,
                    reference,
                    "caller dispatch boundary was crossed for arm/takeoff",
                )
            elif intended:
                assessed["command"] = (
                    None,
                    reference,
                    "persisted application intent has no known dispatch outcome",
                )
            else:
                assessed["command"] = (record["value"] == expected, reference, None)
        need(evidence is not None, "registered native evidence is unavailable")
        uref = custody(native, evidence, configuration, slots, actor_data)
        from pyulog import ULog

        raw = original(uref, evidence, maximum=ULOG_LIMIT)
        try:
            ulog = ULog(BytesIO(raw), disable_str_exceptions=False)
        except Exception as error:
            raise Unavailable(
                "stock ULog decoding did not establish complete source evidence: "
                + str(error)
            ) from error
        need(
            not ulog.file_corruption
            and not ulog.dropouts
            and not ulog.has_data_appended,
            "ULog corruption, dropout or appended segments leave coverage incomplete",
        )
        need(
            ulog.msg_info_dict.get("ver_sw") == PX4_SOURCE
            and ulog.start_timestamp <= start < end <= ulog.last_timestamp,
            "ULog source revision or measurement coverage differs",
        )
        params = ulog.initial_parameters
        need(
            int(params.get("SDLOG_PROFILE", 0)) & 1
            and int(params.get("SDLOG_BACKEND", 0)) & 1,
            "effective full-topic file logging configuration is unavailable",
        )
        need(
            not any(
                start <= change[0] <= end
                and change[1] in {"SDLOG_MODE", "SDLOG_PROFILE", "SDLOG_BACKEND"}
                for change in ulog.changed_parameters
            ),
            "logger configuration changed during measurement",
        )
    except (
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        IndexError,
        OSError,
    ) as error:
        for name in ("command", "grounded", "disarmed", "postcondition"):
            if assessed[name][0] is None:
                assessed[name] = (None, None, str(error))
        return assessed
    bounds = None
    phase_error = "received command phase is unavailable"
    try:
        lower, upper = start, end
        commands = []
        if refusal and any(d.name == "vehicle_command" for d in ulog.data_list):
            commands = rows(
                ulog,
                "vehicle_command",
                (
                    "timestamp",
                    "command",
                    "param1",
                    "target_system",
                    "target_component",
                    "source_system",
                    "source_component",
                    "from_external",
                ),
            )
            for command in commands:
                if not start < command["timestamp"] <= end or command[
                    "command"
                ] not in (22, 400):
                    continue
                if command["command"] == 400 and command["param1"] == 0:
                    continue
                need(
                    command["command"] == 22 or command["param1"] == 1,
                    "received arm/disarm command parameters are ambiguous",
                )
                expected_actor = (
                    identity["target_system_id"],
                    identity["target_component_id"],
                    identity["source_system_id"],
                    identity["source_component_id"],
                )
                need(
                    tuple(
                        command[k]
                        for k in (
                            "target_system",
                            "target_component",
                            "source_system",
                            "source_component",
                        )
                    )
                    == expected_actor
                    and command["from_external"] is True,
                    "foreign received command makes refusal attribution ambiguous",
                )
                assessed["command"] = (
                    False,
                    uref,
                    "PX4 received an owned arm/takeoff command during caller refusal",
                )
        if not refusal:
            need(
                "takeoff" in actions,
                "required application takeoff action is absent",
            )
            fields = (
                "timestamp",
                "command",
                "target_system",
                "target_component",
                "source_system",
                "source_component",
                "from_external",
                "confirmation",
            ) + tuple("param" + str(i) for i in range(1, 8))
            commands = rows(ulog, "vehicle_command", fields)
            acks = rows(
                ulog,
                "vehicle_command_ack",
                (
                    "timestamp",
                    "command",
                    "result",
                    "target_system",
                    "target_component",
                    "from_external",
                ),
            )
            takeoff, accepted = command_phase(
                commands, acks, identity, 22, (start, end)
            )
            sdk = actions["takeoff"]["result"]
            if accepted is False:
                assessed["command"] = (
                    False,
                    uref,
                    "PX4 explicitly rejected the attributable takeoff command",
                )
            elif sdk == {"name": "SUCCESS", "value": 1}:
                assessed["command"] = (True, actions["takeoff"]["reference"], None)
            need("land" in actions, "required serial application land action is absent")
            land, _land_accepted = command_phase(
                commands, acks, identity, 21, (start, end)
            )
            need(
                takeoff < land and "pre-land-status" in slots,
                "received command phase is ambiguous",
            )
            preland = slots["pre-land-status"][0]
            need(
                actions["takeoff"]["issued"]["sequence"]
                < preland["sequence"]
                < actions["land"]["issued"]["sequence"],
                "land phase is not serially bracketed",
            )
            stamp = integer(
                snapshot(
                    preland,
                    identity["target_system_id"],
                    identity["target_component_id"],
                )["timestamp_us"]
            )
            need(
                start <= stamp < land <= end,
                "received land is outside the observed land phase",
            )
            lower, upper = takeoff, land - 1
            terminal_lower = land
        else:
            terminal_lower = start
        need(
            not any(
                start < r["timestamp"] <= end and r["command"] == 179 for r in commands
            ),
            "received DO_SET_HOME changes the measurement reference",
        )
        bounds = (lower, upper, terminal_lower)
    except (
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        IndexError,
        OSError,
    ) as error:
        phase_error = str(error)
        if assessed["command"][0] is None:
            assessed["command"] = (None, None, phase_error)
    if bounds is None:
        for name in ("grounded", "disarmed", "postcondition"):
            assessed[name] = (None, None, phase_error)
        return assessed
    lower, upper, terminal_lower = bounds
    try:
        status = rows(
            ulog,
            "vehicle_status",
            ("timestamp", "arming_state", "system_id", "component_id"),
        )
        need(
            all(
                (r["system_id"], r["component_id"])
                == (identity["target_system_id"], identity["target_component_id"])
                for r in status
                if start <= r["timestamp"] <= end
            ),
            "ULog actor identity changed inside measurement",
        )
        terminal_status = [r for r in status if terminal_lower < r["timestamp"] <= end]
        if terminal_status:
            need(
                terminal_status[-1]["arming_state"] in (1, 2),
                "terminal arming state is unknown",
            )
            assessed["disarmed"] = (
                terminal_status[-1]["arming_state"] == 1,
                uref,
                None,
            )
    except (
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        IndexError,
        OSError,
    ) as error:
        assessed["disarmed"] = (None, None, str(error))
    try:
        landed = rows(ulog, "vehicle_land_detected", ("timestamp", "landed"))
        terminal_land = [r for r in landed if terminal_lower < r["timestamp"] <= end]
        if terminal_land:
            need(
                type(terminal_land[-1]["landed"]) is bool,
                "terminal landed state is invalid",
            )
            assessed["grounded"] = (terminal_land[-1]["landed"], uref, None)
    except (
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        IndexError,
        OSError,
    ) as error:
        assessed["grounded"] = (None, None, str(error))
    try:
        global_rows = rows(
            ulog,
            "vehicle_global_position",
            ("timestamp", "timestamp_sample", "alt", "alt_valid", "alt_reset_counter"),
        )
        home_rows = rows(
            ulog, "home_position", ("timestamp", "alt", "valid_alt", "update_count")
        )
        samples = altitude_samples(global_rows, home_rows, lower, upper)
        condition = altitude_condition(samples, refusal=refusal)
        assessed["postcondition"] = (
            condition,
            uref,
            "home ordering or sample coverage does not determine the condition"
            if condition is None
            else None,
        )
    except (
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        IndexError,
        OSError,
    ) as error:
        assessed["postcondition"] = (None, None, str(error))
    return assessed
