"""Example-local native PX4 control; ULog supplies qualification measurements."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import selectors
import signal
import stat
import subprocess
import time
from pathlib import Path

from _px4_listener import MAX_LISTENER_BYTES, Refused, parse_listener

PX4 = "/opt/px4/build/px4_sitl_default/bin/px4"
LISTENER = PX4 + "-listener"
CASES = ("land", "unarmed-refusal", "application-deadline")


def finite(value):
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


class Journal:
    def __init__(self, output, run_id, *, monotonic=None, unix_ms=None):
        if not re.fullmatch(
            r"run-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
            run_id,
        ):
            raise ValueError("issued run ID required")
        self.output = Path(output)
        self.output.mkdir(mode=0o700, parents=False, exist_ok=False)
        self.run_id = run_id
        self.monotonic = monotonic or (lambda: time.monotonic() * 1000)
        self.unix_ms = unix_ms or (lambda: time.time_ns() // 1000000)
        self.started = str(self.unix_ms() * 1000000)
        self.records = []
        self.total = 0
        self.closed = False

    def _write(self, name, value):
        raw = (
            json.dumps(value, allow_nan=False, separators=(",", ":")) + "\n"
        ).encode()
        if len(raw) > 1048576 or self.total + len(raw) > 8388608:
            raise Refused("controller journal byte budget exceeded")
        path = self.output / name
        with path.open("xb") as stream:
            os.chmod(path, 0o600)
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        descriptor = os.open(self.output, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        self.total += len(raw)
        return raw

    def retain(self, kind, value):
        if (
            self.closed
            or len(self.records) >= 2048
            or not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", kind)
        ):
            raise Refused("controller journal closed, full or invalid kind")
        sequence = len(self.records)
        name = f"{sequence:04d}-{kind}.json"
        raw = self._write(
            name,
            {
                "run_id": self.run_id,
                "domain_id": "px4",
                "sequence": sequence,
                "kind": kind,
                "receiver_unix_ns": str(self.unix_ms() * 1000000),
                "receiver_monotonic_ms": self.monotonic(),
                "value": value,
            },
        )
        self.records.append(
            {
                "path": name,
                "kind": kind,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "size_bytes": len(raw),
            }
        )
        return sequence

    def close(self):
        if self.closed:
            raise Refused("controller journal already closed")
        self._write(
            "controller-manifest.json",
            {
                "run_id": self.run_id,
                "domain_id": "px4",
                "clock_source": "controller-utc-ms",
                "started_unix_ns": self.started,
                "finished_unix_ns": str(self.unix_ms() * 1000000),
                "complete": True,
                "records": self.records,
                "total_bytes": self.total,
            },
        )
        self.closed = True


def check_initial_freshness(observations, checked_at_ms):
    # Bound current data age; the listener clock interval is not a host/PX4 mapping.
    required = {"initial-status-a", "initial-land", "initial-status-b"}
    if set(observations) != required or not finite(checked_at_ms):
        raise Refused("initial source observations or dispatch clock unavailable")
    for slot in sorted(required):
        observation = observations[slot]
        started = observation["host_started_monotonic_ms"]
        finished = observation["host_finished_monotonic_ms"]
        parsed = observation["parsed"]
        age = parsed["age_s"]
        age_upper_us = int(parsed["native_print_clock_us"]["upper"]) - int(
            parsed["timestamp_us"]
        )
        if (
            not all(finite(value) for value in (started, finished, age))
            or not 0 <= started <= finished <= checked_at_ms
            or age < 0
            or age_upper_us < 0
        ):
            raise Refused("initial observation clocks are unordered or unavailable")
        budget_ms = (
            age_upper_us / 1000 + (finished - started) + (checked_at_ms - finished)
        )
        if budget_ms >= 1000:
            raise Refused("initial snapshot freshness budget exceeded: " + slot)


def process_identity(config, *, proc_root=Path("/proc")):
    pid = config.get("px4_pid")
    ticks = config.get("px4_start_ticks")
    instance = config.get("instance")
    digest = config.get("px4_executable_sha256")
    if (
        type(pid) is not int
        or pid <= 1
        or not isinstance(ticks, str)
        or not re.fullmatch(r"[1-9][0-9]{0,19}", ticks)
    ):
        raise Refused("admitted PX4 PID/start identity unavailable")
    if (
        type(instance) is not int
        or not 0 <= instance <= 255
        or not isinstance(digest, str)
        or not re.fullmatch(r"[a-f0-9]{64}", digest)
    ):
        raise Refused("admitted PX4 executable/instance unavailable")
    root = proc_root / str(pid)
    raw = (root / "stat").read_text()
    start = raw[raw.rfind(")") + 2 :].split()[19]
    executable = os.readlink(root / "exe")
    argv = (root / "cmdline").read_bytes().split(b"\0")
    decoded = [arg.decode("utf-8", "strict") for arg in argv if arg]
    options = [i for i, value in enumerate(decoded) if value in ("-i", "--instance")]
    if not options:
        raise Refused("explicit PX4 process instance unavailable")
    actual_instance = None
    if options:
        if (
            len(options) != 1
            or options[0] + 1 >= len(decoded)
            or not decoded[options[0] + 1].isdigit()
        ):
            raise Refused("ambiguous PX4 process instance")
        actual_instance = int(decoded[options[0] + 1])
    hasher = hashlib.sha256()
    with (root / "exe").open("rb") as stream:
        size = 0
        while chunk := stream.read(1048576):
            size += len(chunk)
            if size > 134217728:
                raise Refused("PX4 executable exceeds bound")
            hasher.update(chunk)
    final_stat = (root / "stat").read_text()
    if final_stat[final_stat.rfind(")") + 2 :].split()[19] != start:
        raise Refused("PX4 process changed while collecting identity")
    observed = {
        "pid": pid,
        "start_ticks": start,
        "executable": executable,
        "executable_sha256": hasher.hexdigest(),
        "instance": actual_instance,
    }
    if (
        start != ticks
        or executable != PX4
        or actual_instance != instance
        or hasher.hexdigest() != digest
    ):
        raise Refused("PX4 process identity changed or differs from admission")
    return observed


def stock_listener(topic, instance, budget_ms):
    if (
        topic not in ("vehicle_status", "vehicle_land_detected")
        or type(instance) is not int
        or not 0 <= instance <= 255
    ):
        raise Refused("unselected listener request")
    if not finite(budget_ms) or not 0 < budget_ms <= 45000:
        raise Refused("invalid finite listener budget")
    argv = [LISTENER, "--instance", str(instance), topic, "-n", "1"]
    started = time.monotonic() * 1000
    captured = {"stdout": bytearray(), "stderr": bytearray()}
    error = None
    with subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        close_fds=True,
    ) as child:
        try:
            with selectors.DefaultSelector() as selector:
                for name, stream in (
                    ("stdout", child.stdout),
                    ("stderr", child.stderr),
                ):
                    os.set_blocking(stream.fileno(), False)
                    selector.register(stream, selectors.EVENT_READ, name)
                while selector.get_map():
                    left = (budget_ms - (time.monotonic() * 1000 - started)) / 1000
                    if left <= 0:
                        raise Refused(
                            "stock listener did not finish within readiness budget"
                        )
                    for key, _ in selector.select(min(left, 0.1)):
                        chunk = os.read(key.fd, 4096)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        remaining = MAX_LISTENER_BYTES - sum(
                            map(len, captured.values())
                        )
                        captured[key.data].extend(chunk[:remaining])
                        if len(chunk) > remaining:
                            raise Refused(
                                "stock listener output exceeds bound; retained prefix is truncated"
                            )
            left = max(0.001, (budget_ms - (time.monotonic() * 1000 - started)) / 1000)
            child.wait(timeout=left)
        except Exception as failure:
            error = str(failure)
            child.kill()
            child.wait()
        result = {
            "argv": argv,
            "returncode": child.returncode,
            "error": error,
            "host_started_monotonic_ms": started,
            "host_finished_monotonic_ms": time.monotonic() * 1000,
        }
        for key, value in captured.items():
            try:
                result[key] = bytes(value).decode("utf-8", "strict")
            except UnicodeDecodeError:
                result[key] = ""
                result[key + "_hex"] = bytes(value).hex()
                result["error"] = (
                    "listener output is not UTF-8; original bytes retained as hex"
                )
        return result


def enum_value(value):
    if not hasattr(value, "name") or type(value.value) is not int:
        raise Refused("native enum unavailable")
    return {"name": value.name, "value": value.value}


def run_case(
    name,
    config,
    journal,
    telemetry,
    action,
    sdk_identity,
    *,
    listener=stock_listener,
    actor_probe=process_identity,
    monotonic=None,
    sleep=time.sleep,
    stopped=lambda: False,
    action_error=(),
):
    if name not in CASES or config.get("owner_id") != journal.run_id:
        raise Refused("case/owner binding differs")
    now = monotonic or (lambda: time.monotonic() * 1000)
    serial = 0
    may_have_armed = False
    error = None
    observed = "unknown"
    before = None
    last_source = 0
    last_native_clock_upper = 0
    initial_observations = {}
    readiness_ms = 45000
    settlement_ms = 45000

    def check_stop():
        if stopped():
            raise Refused("parent requested stop; physical outcome unknown")

    def wait(predicate, budget, *, settling=False):
        end = now() + budget
        while True:
            if not settling:
                check_stop()
            value = predicate()
            if now() >= end:
                raise Refused("cached control readiness budget expired")
            if value:
                return value
            sleep(0.1)

    def observation(slot, topic, *, initial=False):
        nonlocal last_source, last_native_clock_upper
        if actor_probe(config) != before:
            raise Refused("PX4 process changed during listener observation")
        started = now()
        try:
            job = listener(topic, config["instance"], min(readiness_ms, 3000))
        except Exception as failure:
            journal.retain(
                "listener-observation",
                {
                    "slot": slot,
                    "error": str(failure),
                    "host_started_monotonic_ms": started,
                    "host_finished_monotonic_ms": now(),
                },
            )
            raise
        value = {"slot": slot, **job}
        try:
            started_at, finished_at = (
                job["host_started_monotonic_ms"],
                job["host_finished_monotonic_ms"],
            )
            if (
                not finite(started_at)
                or not finite(finished_at)
                or not 0 <= finished_at - started_at <= 3000
            ):
                raise Refused(
                    "listener host elapsed time is unavailable or exceeds bound"
                )
            if job.get("error") or job["returncode"] != 0:
                raise Refused("stock listener process failed")
            parsed = parse_listener(job["stdout"], topic)
            value["parsed"] = parsed
            if topic == "vehicle_status":
                if (parsed["system_id"], parsed["component_id"]) != (
                    config["target_system_id"],
                    config["target_component_id"],
                ):
                    raise Refused("listener actor differs from admitted SDK target")
                if initial and parsed["arming_state"] != 1:
                    raise Refused("initial PX4 state is not disarmed")
                timestamp = int(parsed["timestamp_us"])
                if timestamp < last_source:
                    raise Refused("PX4 publication timestamp moved backwards")
                last_source = timestamp
            elif initial and not parsed["landed"]:
                raise Refused("initial PX4 state is not landed")
            interval = parsed["native_print_clock_us"]
            if int(interval["lower"]) <= last_native_clock_upper:
                raise Refused("PX4 native print clock intervals do not prove progress")
            last_native_clock_upper = int(interval["upper"])
        except Exception as failure:
            value["error"] = str(failure)
            journal.retain("listener-observation", value)
            raise
        journal.retain("listener-observation", value)
        if initial:
            initial_observations[slot] = value
        return parsed

    def invoke(method):
        nonlocal serial, may_have_armed
        if actor_probe(config) != before:
            raise Refused("PX4 process changed before action dispatch")
        serial += 1
        invocation = f"action-{serial:04d}"
        journal.retain(
            "action-issued",
            {"invocation_id": invocation, "method": method, "monotonic_ms": now()},
        )
        if method != "land":
            check_stop()
        if actor_probe(config) != before:
            raise Refused("PX4 process changed during durable issuance")
        dispatch_ms = now()
        if method == "arm":
            check_initial_freshness(initial_observations, dispatch_ms)
            may_have_armed = True
        try:
            result = getattr(action, method)()
        except Exception as failure:
            native_result = (
                enum_value(failure.result)
                if action_error and isinstance(failure, action_error)
                else None
            )
            journal.retain(
                "action-error",
                {
                    "invocation_id": invocation,
                    "method": method,
                    "monotonic_ms": now(),
                    "dispatch_monotonic_ms": dispatch_ms,
                    "sdk_result": native_result,
                    "error_type": type(failure).__name__,
                    "message": str(failure),
                    "physical_outcome": "unknown",
                },
            )
            raise
        result = enum_value(result)
        journal.retain(
            "action-" + method,
            {
                "invocation_id": invocation,
                "method": method,
                "monotonic_ms": now(),
                "dispatch_monotonic_ms": dispatch_ms,
                "sdk_result": result,
            },
        )
        if result != {"name": "SUCCESS", "value": 1}:
            raise Refused("native action returned non-success")

    def healthy():
        health = telemetry.health()
        position_ready = all(
            getattr(health, key, None) is True
            for key in (
                "is_local_position_ok",
                "is_global_position_ok",
                "is_home_position_ok",
            )
        )
        return position_ready and (
            name == "unarmed-refusal" or getattr(health, "is_armable", None) is True
        )

    try:
        before = actor_probe(config)
        journal.retain("actor-identity-before", before)
        expected = {
            key: config[key]
            for key in (
                "source_system_id",
                "source_component_id",
                "target_system_id",
                "target_component_id",
            )
        }
        if any(
            type(value) is not int or not 1 <= value <= 255
            for value in expected.values()
        ):
            raise Refused("admitted sender/target IDs unavailable")
        if any(
            type(sdk_identity.get(key)) is not int or sdk_identity.get(key) != value
            for key, value in expected.items()
        ) or sdk_identity.get("discovered_system_ids") != [
            expected["target_system_id"]
        ]:
            raise Refused("SDK sender/target identity differs")
        journal.retain("sdk-identity", sdk_identity)
        wait(healthy, readiness_ms)
        observation("initial-status-a", "vehicle_status", initial=True)
        observation("initial-land", "vehicle_land_detected", initial=True)
        observation("initial-status-b", "vehicle_status", initial=True)
        if name == "unarmed-refusal":
            check_initial_freshness(initial_observations, now())
            journal.retain(
                "caller-refusal",
                {
                    "method": "takeoff",
                    "boundary": "caller-precondition",
                    "reason": "unarmed",
                    "dispatched": False,
                },
            )
            end = now() + 2000
            while now() < end:
                check_stop()
                sleep(0.1)
            observed = "caller-refused-unarmed"
        else:
            check_stop()
            invoke("arm")
            wait(lambda: telemetry.armed() is True, readiness_ms)
            check_stop()
            if telemetry.armed() is not True:
                raise Refused("cached armed control predicate unavailable")
            invoke("takeoff")
            wait(
                lambda: (
                    finite(value := telemetry.position().relative_altitude_m)
                    and value >= 1.2
                ),
                20000,
            )
            if name == "application-deadline":
                started = now()
                while now() - started < 2000:
                    check_stop()
                    telemetry.position()
                    sleep(0.1)
                journal.retain(
                    "application-deadline",
                    {
                        "started_monotonic_ms": started,
                        "observed_monotonic_ms": now(),
                        "budget_ms": 2000,
                    },
                )
            observed = "cached-ascent-control-observed"
    except Exception as failure:
        error = str(failure)
    finally:
        if may_have_armed:
            try:
                observation("pre-land-status", "vehicle_status")
            except Exception as failure:
                error = error or str(failure)
            try:
                invoke("land")
                wait(
                    lambda: (
                        getattr(telemetry.landed_state(), "name", None) == "ON_GROUND"
                    ),
                    settlement_ms,
                    settling=True,
                )
                wait(lambda: telemetry.armed() is False, settlement_ms, settling=True)
                if error is None:
                    observed = (
                        "application-deadline-then-cached-grounded-disarmed"
                        if name == "application-deadline"
                        else "cached-takeoff-then-grounded-disarmed"
                    )
            except Exception as failure:
                error = error or str(failure)
        try:
            if before is not None:
                observation("final-status", "vehicle_status")
                after = actor_probe(config)
                journal.retain("actor-identity-after", after)
                if after != before:
                    raise Refused("PX4 process identity changed")
        except Exception as failure:
            error = error or str(failure)
        journal.retain(
            "controller-result",
            {
                "complete": error is None,
                "outcome": {"case": name, "observed": observed},
                "error": error,
                "physical_outcome": "unknown",
                "scope": "cached controller policy and process observations only; ULog assessment is separate",
            },
        )
        journal.close()
    return error is None


def native_sdk(config):
    from mavsdk import Mavsdk, Configuration, ComponentType, ConnectionResult
    from mavsdk.plugins.action import Action, ActionError
    from mavsdk.plugins.telemetry import Telemetry

    configuration = Configuration.create_with_component_type(
        ComponentType.GROUND_STATION
    )
    sdk = None
    try:
        source = (configuration.system_id, configuration.component_id)
        sdk = Mavsdk(configuration)
        if (
            (configuration.system_id, configuration.component_id) != source
            or source != (config["source_system_id"], config["source_component_id"])
            or any(type(value) is not int or not 1 <= value <= 255 for value in source)
        ):
            raise Refused("effective SDK sender identity unavailable")
        if sdk.add_any_connection("udpin://0.0.0.0:14540") != ConnectionResult.SUCCESS:
            raise Refused("stock MAVSDK connection refused")
        system = sdk.first_autopilot(3.0)
        systems = [value for value in sdk.get_systems() if value.has_autopilot()]
        if system is None or len(systems) != 1 or not system.is_connected():
            raise Refused("unique connected autopilot unavailable")
        target = system.get_system_id()
        if (
            target != config["target_system_id"]
            or systems[0].get_system_id() != target
            or config["target_component_id"] not in system.component_ids()
        ):
            raise Refused("discovered autopilot identity differs")
        identity = {
            "source_system_id": source[0],
            "source_component_id": source[1],
            "target_system_id": target,
            "target_component_id": config["target_component_id"],
            "discovered_system_ids": [target],
        }
        return (
            sdk,
            configuration,
            Telemetry(system),
            Action(system),
            identity,
            ActionError,
        )
    except BaseException:
        if sdk is not None:
            sdk.destroy()
        configuration.destroy()
        raise


def read_actor_config(path, run_id):
    descriptor = os.open(
        path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    )
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > 32768:
            raise Refused("actor configuration must be a bounded regular file")
        raw = bytearray()
        while chunk := os.read(descriptor, min(4096, 32769 - len(raw))):
            raw.extend(chunk)
            if len(raw) > 32768:
                raise Refused("actor configuration exceeds byte bound")
        after = os.fstat(descriptor)
        named = os.stat(path, follow_symlinks=False)
        identity_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        identity = tuple(getattr(before, field) for field in identity_fields)
        if (
            not stat.S_ISREG(after.st_mode)
            or not stat.S_ISREG(named.st_mode)
            or any(
                tuple(getattr(value, field) for field in identity_fields) != identity
                for value in (after, named)
            )
            or len(raw) != before.st_size
        ):
            raise Refused("actor configuration changed during capture")
    finally:
        os.close(descriptor)
    config = json.loads(raw)
    if not isinstance(config, dict) or config.get("owner_id") != run_id:
        raise Refused("issued owner configuration required")
    return config


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case", choices=CASES)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    if not args.output.is_absolute() or not args.config.is_absolute():
        parser.error("absolute capture and actor configuration paths required")
    try:
        config = read_actor_config(args.config, args.run_id)
    except (OSError, ValueError, Refused) as failure:
        parser.error(str(failure))
    journal = Journal(args.output, args.run_id)
    stop = False

    def request_stop(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    sdk = configuration = None
    try:
        process_identity(config)
        sdk, configuration, telemetry, action, identity, action_error = native_sdk(
            config
        )
        return (
            0
            if run_case(
                args.case,
                config,
                journal,
                telemetry,
                action,
                identity,
                stopped=lambda: stop,
                action_error=action_error,
            )
            else 1
        )
    except Exception as failure:
        if not journal.closed:
            journal.retain(
                "controller-result",
                {
                    "complete": False,
                    "outcome": {"case": args.case, "observed": "unknown"},
                    "error": str(failure),
                    "physical_outcome": "unknown",
                    "scope": "controller startup",
                },
            )
            journal.close()
        return 1
    finally:
        if sdk is not None:
            sdk.destroy()
        if configuration is not None:
            configuration.destroy()


if __name__ == "__main__":
    raise SystemExit(main())
