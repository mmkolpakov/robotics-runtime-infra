"""Export a recorded Nav2 assessment under an external operator's signing key."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import unquote, urlparse

import regression_driver as driver
from robotics_acceptance_harness.evaluator_trust import (
    CosignKeyVerifierProfile,
    read_once,
)

ROOT = driver.DEMO.parents[1]
QUALIFICATION = ROOT / "scripts" / "qualification"
CASES = (
    "baseline",
    "criterion-sensitivity",
    "insufficient-observation",
    "missing-coverage",
)


def run(command, *, cwd=ROOT, env=None, success_codes=(0,)):
    completed = subprocess.run(
        [str(value) for value in command],
        cwd=cwd,
        env=env,
        check=False,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=180,
    )
    if completed.returncode not in success_codes:
        completed.check_returncode()
    return completed.stdout


def load_profile(path):
    if path.stat().st_mode & 0o022:
        raise ValueError("operator trust profile must not be group/other writable")
    values = json.loads(read_once(path, 1024 * 1024))
    verifier = dict(values["verifier"])
    if verifier.pop("kind") != "cosign_key_no_tlog":
        raise ValueError("an explicit Cosign key-only operator profile is required")
    for name in ("executable", "public_key", "trusted_root"):
        verifier[name] = Path(verifier[name])
    profile = CosignKeyVerifierProfile(**verifier)
    for name in ("executable", "public_key", "trusted_root"):
        if driver._sha256(getattr(profile, name)) != getattr(profile, name + "_sha256"):
            raise ValueError(f"operator {name} differs from its approved SHA-256 pin")
    if len(values["evaluators"]) != 1:
        raise ValueError("one exact Nav2 evaluator policy is required")
    policy = values["evaluators"][0]["publisher"]
    if policy["public_key_sha256"] != profile.public_key_sha256:
        raise ValueError("publisher policy key differs from operator profile key")
    return profile


def external(path, roots):
    path = path.absolute()
    if any(item.is_symlink() for item in (path, *path.parents)):
        raise ValueError(f"symlink trust input is not supported: {path}")
    resolved = path.resolve()
    if any(resolved.is_relative_to(root.resolve()) for root in roots):
        raise ValueError(
            f"operator trust and private key must be outside evidence/output: {path}"
        )
    return resolved


def reference_path(reference):
    uri = urlparse(reference["uri"])
    if uri.scheme != "file" or uri.netloc:
        raise ValueError("this recorded demo requires local evidence files")
    path = Path(unquote(uri.path)).resolve(strict=True)
    raw = path.read_bytes()
    if (
        hashlib.sha256(raw).hexdigest() != reference["sha256"]
        or len(raw) != reference["size_bytes"]
    ):
        raise ValueError(f"referenced bytes changed: {path}")
    return path


def inventory(work, case, qualification):
    selected = work / "run" / case
    prepared = selected / "archive" / "inputs"
    assessment = selected / "assessment"
    result = json.loads((assessment / "acceptance-result.json").read_bytes())
    aggregate = assessment / "acceptance-aggregate.json"
    arguments = [
        "--scenario",
        str(prepared / "scenario.json"),
        "--runtime-manifest",
        f"nav2={prepared / 'runtime.json'}",
        "--acceptance-run",
        str(prepared / "run.json"),
        "--result",
        f"nav2={assessment / 'acceptance-result.json'}",
        "--aggregate",
        str(aggregate),
        "--evidence-index",
        f"nav2={selected / 'archive' / 'evidence-index.json'}",
        "--extension-schema",
        f"{driver.SCHEMA_URI}={prepared / 'nav2.schema.json'}",
    ]
    index = json.loads((selected / "archive" / "evidence-index.json").read_bytes())
    for item in index["artifacts"]:
        path = reference_path(item)
        subject = (
            "observations/nav2.json"
            if item["kind"] == "acceptance_observation"
            else "evidence/" + item["artifact_id"] + path.suffix
        )
        arguments += ["--artifact", f"{item['kind']}:{subject}={path}"]
        if "recording_summary" in item:
            summary = reference_path(item["recording_summary"])
            arguments += ["--recording-summary", f"{item['artifact_id']}={summary}"]
    for name, reference in (
        ("method", result["evaluation"]["method"]["configuration"]),
        ("environment", result["evaluation"]["environment"]),
    ):
        arguments += [
            "--artifact",
            f"other_evidence:assessment/{name}.json={reference_path(reference)}",
        ]
    for kind, name in (
        ("artifact_receipt", "receipt.json"),
        ("artifact_verification", "verification.json"),
        ("attestation", "statement.json"),
        ("policy", "publisher.json"),
        ("verification", "verified-report.txt"),
        ("package", "nav2_turtlebot3_evaluator-0.3.0-py3-none-any.whl"),
    ):
        arguments += ["--artifact", f"{kind}:evaluator/{name}={qualification / name}"]
    arguments += [
        "--artifact",
        f"junit:assessment/junit.xml={assessment / 'junit.xml'}",
    ]
    return arguments, prepared, assessment, aggregate


def export(args):
    work = args.work_dir.resolve()
    output = args.output.resolve()
    if output.exists():
        raise ValueError("export output must be a new directory")
    if not output.is_relative_to(ROOT) or not work.is_relative_to(ROOT):
        raise ValueError("work and export output must be inside this checkout")
    if output.is_relative_to(work) or work.is_relative_to(output):
        raise ValueError("work and export output directories must be separate")
    profile_path = external(args.operator_profile, [work, output])
    key = external(args.publisher_key, [work, output])
    if args.bootstrap:
        if profile_path.exists() or profile_path.name != "operator-profile.json":
            raise ValueError(
                "bootstrap requires a new operator-profile.json in a new directory"
            )
        if args.public_key is None:
            raise ValueError("--bootstrap requires --public-key")
        public_key = external(args.public_key, [work, output])
        tool = driver._cosign_tool(args.cosign_profile)
        wheel = next(
            (driver.DEMO / "dist").glob("nav2_turtlebot3_evaluator-*-py3-none-any.whl")
        )
        driver.admit_evaluator(
            wheel, profile_path.parent, tool, publisher_key=key, public_key=public_key
        )
    elif args.public_key or args.cosign_profile:
        raise ValueError(
            "--public-key and --cosign-profile apply only with --bootstrap"
        )

    profile = load_profile(profile_path)
    external(profile.public_key, [work, output])
    external(profile.trusted_root, [work, output])
    derived_key = run([profile.executable, "public-key", "--key", key])
    if hashlib.sha256(derived_key).hexdigest() != profile.public_key_sha256:
        raise ValueError(
            "publisher private key does not match the operator profile key"
        )

    with contextlib.redirect_stdout(io.StringIO()):
        status = driver.main(
            [
                "--operator-profile",
                str(profile_path),
                "--work-dir",
                str(work),
                "--output",
                str(work / "results.json"),
                "--report",
                str(work / "report.txt"),
            ]
        )
    if status:
        raise ValueError("the five-case demo did not produce its expected verdicts")
    qualification = work / "admission" / "qualification"
    arguments, prepared, assessment, aggregate = inventory(
        work, args.case, qualification
    )
    cli = Path(sys.executable).parent
    aggregate_report = json.loads(
        run(
            [
                cli / "robotics-acceptance",
                "aggregate",
                "--scenario",
                prepared / "scenario.json",
                "--run-context",
                prepared / "run.json",
                "--result",
                assessment / "acceptance-result.json",
                "--extension-schema",
                f"{driver.SCHEMA_URI}={prepared / 'nav2.schema.json'}",
                "--output",
                aggregate,
            ],
            success_codes=(0, 1),
        )
    )
    if (
        aggregate_report.get("aggregate") != str(aggregate)
        or aggregate_report.get("status")
        not in {"passed", "failed", "incomplete", "error"}
        or not aggregate.is_file()
    ):
        raise ValueError("aggregate did not produce its declared verdict document")
    environment = {
        **os.environ,
        "ROBOTICS_CONTRACTS_CLI": str(cli / "robotics-contracts"),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".export-", dir=output.parent) as temporary:
        staging = Path(temporary)
        statement = staging / "qualification-statement.json"
        bundle = staging / "qualification.sigstore.json"
        public_snapshot = staging / "operator.pub"
        public_snapshot.write_bytes(read_once(profile.public_key, 1024 * 1024))
        if driver._sha256(public_snapshot) != profile.public_key_sha256:
            raise ValueError("operator key changed before signing")
        signing = staging / "signing.json"
        run([profile.executable, "signing-config", "create", "--out", signing])
        run(
            [QUALIFICATION / "create-statement", *arguments, "--output", statement],
            env=environment,
        )
        run(
            [
                profile.executable,
                "attest-blob",
                "--yes",
                "--key",
                key,
                "--signing-config",
                signing,
                "--trusted-root",
                profile.trusted_root,
                "--statement",
                statement,
                "--bundle",
                bundle,
            ]
        )
        package = staging / "package"
        run(
            [QUALIFICATION / "package-artifacts", *arguments, "--output", package],
            env=environment,
        )
        shutil.copyfile(statement, package / statement.name)
        shutil.copyfile(bundle, package / bundle.name)
        (staging / "bin").mkdir()
        (staging / "bin" / "cosign").symlink_to(profile.executable)
        environment["PATH"] = (
            str(staging / "bin") + os.pathsep + os.environ.get("PATH", "")
        )
        portable = (package / "qualification-arguments.txt").read_text().splitlines()
        verified = run(
            [
                QUALIFICATION / "verify-bundle",
                *portable,
                "--bundle",
                "qualification.sigstore.json",
                "--key",
                public_snapshot,
            ],
            cwd=package,
            env=environment,
        )
        package.rename(output)
    print(verified.decode().strip())
    print(f"Exported {args.case}: {output}")
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--operator-profile", type=Path, required=True)
    parser.add_argument("--publisher-key", type=Path, required=True)
    parser.add_argument(
        "--bootstrap",
        action="store_true",
        help="create a new external profile with the supplied keypair",
    )
    parser.add_argument("--public-key", type=Path)
    parser.add_argument("--cosign-profile", type=Path)
    parser.add_argument(
        "--work-dir", type=Path, default=driver.DEMO / "work" / "export-run"
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case", choices=CASES, default="baseline")
    args = parser.parse_args(argv)
    try:
        export(args)
    except (
        OSError,
        ValueError,
        KeyError,
        StopIteration,
        subprocess.CalledProcessError,
    ) as error:
        print(f"export: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr.decode(), file=sys.stderr, end="")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
