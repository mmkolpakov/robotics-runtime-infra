"""Bind the stock one-message playback probe to retained recording bytes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from robotics_runtime_contracts import load_mapping, loads_mapping, validate_document
from robotics_runtime_contracts.serialization import read_document_bytes
from robotics_runtime_contracts.writers import protect_inputs, write_document

CAPABILITY = "playback_probe_delivery"
FACT_FILES = (
    "configuration/provider.json",
    "configuration/rosbag2-version.txt",
    "observation.json",
    "logs/playback-gate.log",
    "logs/playback-probe.log",
    "playback-image.json",
    "probe-image.json",
    "compose-original.json",
    "compose.json",
)


def reference(root: Path, relative: str, host_root: Path) -> dict[str, Any]:
    path = root / relative
    path.resolve(strict=True).relative_to(root.resolve())
    with path.open("rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("playback evidence must be a regular file")
        sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
        after = os.fstat(stream.fileno())
    if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    ):
        raise ValueError("playback evidence changed while hashing")
    return {
        "uri": (host_root / relative).as_uri(),
        "sha256": sha256,
        "size_bytes": after.st_size,
    }


def checked_observation(root: Path, configuration: dict[str, Any]) -> None:
    observation = load_mapping(root / "observation.json")
    if any(
        type(observation.get(key)) is not int or observation[key] != 0
        for key in (
            "gate_exit_code",
            "probe_exit_code",
            "gate_logs_exit_code",
            "probe_logs_exit_code",
        )
    ):
        raise ValueError("playback gate and probe must both succeed")
    for role in ("playback", "probe"):
        expected = configuration.get(f"expected_{role}_image_id")
        if not isinstance(expected, str) or not re.fullmatch(
            r"sha256:[a-f0-9]{64}", expected
        ):
            raise ValueError(
                "selected playback and probe images must have native local IDs"
            )
        if observation.get(f"{role}_image_id") != configuration.get(
            f"expected_{role}_image_id"
        ):
            raise ValueError(f"observed {role} image differs from the selected image")
    if observation.get("gate_image_id") != configuration["expected_playback_image_id"]:
        raise ValueError("observed gate image differs from the selected playback image")
    raw = read_document_bytes(root / "logs/playback-probe.log")
    if hashlib.sha256(raw).hexdigest() != observation.get("probe_log_sha256"):
        raise ValueError("retained probe log differs from the observed bytes")
    checked_probe_message(raw, configuration.get("message_type", "std_msgs/msg/Int32"))
    version = (
        read_document_bytes(root / "configuration/rosbag2-version.txt").decode().strip()
    )
    if not version or any(character.isspace() for character in version):
        raise ValueError("rosbag2_transport must report exactly one version")
    if configuration.get("version") != version:
        raise ValueError(
            "provider configuration differs from the observed package version"
        )


def checked_probe_message(raw: bytes, message_type: str) -> None:
    if message_type == "std_msgs/msg/Int32":
        minimum, maximum = -(2**31), 2**31
    elif message_type == "std_msgs/msg/UInt64":
        minimum, maximum = 0, 2**64
    else:
        raise ValueError("this playback probe supports only native Int32 or UInt64")
    values = re.findall(rb"^data:\s*(-?[0-9]+)\s*$", raw, re.MULTILINE)
    if not values or not minimum <= int(values[0]) < maximum:
        raise ValueError(f"the playback probe did not receive a {message_type} message")


def retained_sources(
    root: Path, configuration: dict[str, Any], host_root: Path
) -> list[dict[str, Any]]:
    sources = configuration["sources"]
    if not sources or len({item["path"] for item in sources}) != len(sources):
        raise ValueError("playback source inventory must be nonempty and unique")
    if not {"source/bag/metadata.yaml", "source/qos/qos-overrides.yaml"}.issubset(
        {item["path"] for item in sources}
    ):
        raise ValueError(
            "playback inventory must retain bag metadata and the executed QoS"
        )
    references = []
    for item in sources:
        ref = reference(root, item["path"], host_root)
        if ref["sha256"] != item["sha256"] or ref["size_bytes"] != item["size_bytes"]:
            raise ValueError(
                "retained playback source differs from the executed snapshot"
            )
        references.append(ref)
    metadata = load_mapping(root / "source/bag/metadata.yaml")[
        "rosbag2_bagfile_information"
    ]
    expected_mcap = {"source/bag/" + name for name in metadata["relative_file_paths"]}
    actual_mcap = {item["path"] for item in sources if item["path"].endswith(".mcap")}
    if (
        metadata["storage_identifier"] != "mcap"
        or not expected_mcap
        or expected_mcap != actual_mcap
    ):
        raise ValueError("retained MCAP files differ from the selected bag metadata")
    topics = metadata["topics_with_message_count"]
    if not any(
        item["topic_metadata"]["name"] == configuration.get("topic", "/playback_probe")
        and item["topic_metadata"]["type"]
        == configuration.get("message_type", "std_msgs/msg/Int32")
        for item in topics
    ):
        raise ValueError(
            "the selected recording does not declare the configured native probe"
        )
    return references


def create_result(
    arguments: argparse.Namespace,
) -> tuple[dict[str, Any], dict[str, Any]]:
    root = arguments.run_dir
    profile_raw = read_document_bytes(root / "profile.json")
    profile = loads_mapping(profile_raw, source_name="profile.json")
    validate_document(profile, schema="qualification-profile.v1")
    if profile["provider_kind"] != "recording_source" or profile["requirements"] != [
        {"capability": CAPABILITY, "required": True}
    ]:
        raise ValueError("this probe only qualifies recorded playback of one message")
    configuration_raw = read_document_bytes(root / "configuration/provider.json")
    configuration = dict(
        loads_mapping(configuration_raw, source_name="configuration/provider.json")
    )
    checked_observation(root, configuration)
    evidence = retained_sources(root, configuration, arguments.host_run_dir)
    evidence.extend(
        reference(root, name, arguments.host_run_dir) for name in FACT_FILES
    )
    result = {
        "schema_version": "conformance-result.v1",
        "result_id": "recorded-playback-probe",
        "run_id": arguments.run_id,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "qualification_profile_sha256": hashlib.sha256(profile_raw).hexdigest(),
        "execution_subject_digest": arguments.subject_digest,
        "provider": {
            "kind": "recording_source",
            "implementation_id": "rosbag2_player",
            "version": configuration["version"],
            "configuration_sha256": hashlib.sha256(configuration_raw).hexdigest(),
        },
        "target_id": "simulation-primary",
        "status": "passed",
        "capabilities": [CAPABILITY],
        "checks": [
            {
                "check_id": "recorded-playback-one-message",
                "capability": CAPABILITY,
                "status": "passed",
                "observed_value": 1,
                "unit": "message",
                "message": "The native readiness/resume gate and configured one-message probe passed.",
            }
        ],
        "evidence": evidence,
    }
    validate_document(result)
    binding = {
        key: result[key]
        for key in (
            "provider",
            "target_id",
            "capabilities",
            "qualification_profile_sha256",
        )
    }
    return result, binding


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("run-dir", "host-run-dir", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--subject-digest", required=True)
    args = parser.parse_args()
    try:
        sources = load_mapping(args.run_dir / "configuration/provider.json")["sources"]
        protect_inputs(
            args.output,
            [
                args.run_dir / name
                for name in (
                    "profile.json",
                    *FACT_FILES,
                    *(item["path"] for item in sources),
                )
            ],
        )
        result, binding = create_result(args)
        output = write_document(result, args.output)
        binding["conformance_result_sha256"] = hashlib.sha256(
            read_document_bytes(output)
        ).hexdigest()
        print(json.dumps([binding], allow_nan=False, sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"playback provider: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
