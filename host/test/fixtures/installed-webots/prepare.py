"""Prepare an ordinary independent consumer from exact Git assets and coordinated TGZs."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

COMPOSE_SHA256 = "f9ebc6ebdb19d769b793c245a736caaeb198c62587f13b25c660c13b4987f959"
COMPOSE_FILES = ["compose.worker.yaml", "compose.podman.yaml", "compose.fixture.yaml"]
NODE = "docker.io/library/node@sha256:b64fccfbcd1ae10d11b969a868b50e1c2530a7054813d5cdea04ac3bce551697"


def probe_worker(image, foundation, lock_sha256):
    if not re.fullmatch(r".+@sha256:[a-f0-9]{64}", image):
        raise ValueError("worker image requires an immutable RepoDigest")
    inspected = json.loads(
        subprocess.check_output(
            ["podman", "image", "inspect", image], stderr=subprocess.PIPE, timeout=30
        )
    )
    if not isinstance(inspected, list) or len(inspected) != 1:
        raise ValueError("worker inspect must identify one installed image")
    metadata = inspected[0]
    if not isinstance(metadata, dict):
        raise ValueError("worker inspect metadata must be an object")
    image_id, digests = metadata.get("Id"), metadata.get("RepoDigests")
    if not isinstance(image_id, str) or not re.fullmatch(
        r"(?:sha256:)?[a-f0-9]{64}", image_id
    ):
        raise ValueError("worker inspect did not return an exact image ID")
    if not isinstance(digests, list) or image not in digests:
        raise ValueError("worker image must be an observed immutable RepoDigest")
    probe = (
        "import hashlib,json;from pathlib import Path;from importlib.metadata import version;"
        "raw=Path('/usr/share/robotics-runtime/foundation-lock.json').read_bytes();"
        "lock=json.loads(raw);"
        "print(json.dumps({'installed':{p['distribution']:version(p['distribution']) "
        "for p in lock['packages'].values()},'foundationLock':lock,"
        "'foundationLockSha256':hashlib.sha256(raw).hexdigest()}))"
    )
    public_python = json.loads(
        subprocess.check_output(
            [
                "podman",
                "run",
                "--rm",
                "--pull",
                "never",
                "--network",
                "none",
                "--read-only",
                "--cap-drop",
                "ALL",
                "--security-opt",
                "no-new-privileges",
                "--pids-limit",
                "32",
                "--memory",
                "128m",
                "--userns",
                "keep-id:uid=1000,gid=1000",
                "--user",
                "10001:1000",
                "--entrypoint",
                "/opt/contracts/bin/python",
                image_id,
                "-B",
                "-c",
                probe,
            ],
            stderr=subprocess.PIPE,
            timeout=45,
        )
    )
    expected = {
        package["distribution"]: package["version"]
        for package in foundation["packages"].values()
    }
    if public_python.get("foundationLock") != foundation:
        raise ValueError(
            "worker embedded foundation lock differs from exact source lock"
        )
    if public_python.get("foundationLockSha256") != lock_sha256:
        raise ValueError(
            "worker embedded foundation lock bytes differ from exact source lock"
        )
    if public_python.get("installed") != expected:
        raise ValueError(
            "worker installed public Python pair differs from exact source lock"
        )
    return image_id, digests, public_python


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--consumer", type=Path, required=True)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--infra", type=Path, required=True)
    parser.add_argument("--source-identity", type=Path, required=True)
    parser.add_argument("--compose", type=Path, required=True)
    parser.add_argument("--worker-image", required=True)
    parser.add_argument("--source-volume", required=True)
    parser.add_argument("--retained-volume", required=True)
    args = parser.parse_args()
    root = args.repo.resolve(strict=True)
    consumer = args.consumer.resolve()
    assert root not in [consumer, *consumer.parents], (
        "consumer must be outside the source repo"
    )
    if consumer.exists() or args.consumer.is_symlink():
        raise FileExistsError("consumer directory must be fresh and nonexistent")
    for name in (args.source_volume, args.retained_volume):
        if not re.fullmatch(r"rr-[a-z0-9][a-z0-9-]{0,59}", name):
            raise ValueError(
                "qualification volume requires an explicit rr- owner prefix"
            )
    if args.source_volume == args.retained_volume:
        raise ValueError("source and retained volumes must be distinct")
    asset_identity = json.loads(args.source_identity.read_bytes())
    if not isinstance(asset_identity, dict):
        raise TypeError("coordinated asset identity must be an object")
    for component, asset in (("core", args.core), ("infra", args.infra)):
        entry = asset_identity.get(component)
        if not isinstance(entry, dict):
            raise TypeError(f"coordinated {component} identity must be an object")
        revision, expected = entry.get("revision"), entry.get("sha256")
        if not isinstance(revision, str) or not isinstance(expected, str):
            raise TypeError(
                f"coordinated {component} revision and SHA-256 must be strings"
            )
        if not re.fullmatch(r"[a-f0-9]{40}", revision):
            raise ValueError(f"coordinated {component} revision is invalid")
        if not re.fullmatch(r"[a-f0-9]{64}", expected):
            raise ValueError(f"coordinated {component} SHA-256 is invalid")
        with asset.open("rb") as stream:
            observed = hashlib.file_digest(stream, "sha256").hexdigest()
        if observed != expected:
            raise ValueError(f"coordinated {component} TGZ checksum mismatch")
    host_owner = (
        "rr-webots-host-"
        + hashlib.sha256(
            (args.source_volume + "\0" + args.retained_volume).encode()
        ).hexdigest()[:24]
    )
    source_revision = subprocess.check_output(
        ["git", "rev-parse", "--verify", "HEAD^{commit}"], cwd=root, text=True
    ).strip()
    fixture = root / "host/test/fixtures/installed-webots"
    fixture_contents = {}
    for name in [
        "prepare.py",
        "consumer.mjs",
        "init-storage.mjs",
        "launch.mjs",
        "compose.host.yaml",
        "compose.retained.yaml",
        "Node.Dockerfile",
    ]:
        raw = subprocess.check_output(
            [
                "git",
                "show",
                source_revision + ":host/test/fixtures/installed-webots/" + name,
            ],
            cwd=root,
        )
        if (fixture / name).read_bytes() != raw:
            raise ValueError(f"fixture file differs from committed HEAD: {name}")
        fixture_contents[name] = raw
    lock_bytes = subprocess.check_output(
        ["git", "show", source_revision + ":config/foundation-lock.json"], cwd=root
    )
    foundation = json.loads(lock_bytes)
    lock_sha256 = hashlib.sha256(lock_bytes).hexdigest()
    observed_image_id, repo_digests, public_python = probe_worker(
        args.worker_image, foundation, lock_sha256
    )
    if hashlib.sha256(args.compose.read_bytes()).hexdigest() != COMPOSE_SHA256:
        raise ValueError("Compose executable checksum mismatch")
    consumer.mkdir(parents=True, exist_ok=False)
    for part in ["assets", "app", "profiles", "tools"]:
        (consumer / part).mkdir(exist_ok=True)
    for path, name in [(args.core, "core.tgz"), (args.infra, "infra.tgz")]:
        shutil.copyfile(path, consumer / "assets" / name)
    for component in ("core", "infra"):
        with (consumer / "assets" / f"{component}.tgz").open("rb") as stream:
            observed = hashlib.file_digest(stream, "sha256").hexdigest()
        if observed != asset_identity[component]["sha256"]:
            raise ValueError(f"copied {component} TGZ checksum mismatch")
    shutil.copyfile(args.compose, consumer / "tools/docker-compose")
    assert (
        hashlib.sha256((consumer / "tools/docker-compose").read_bytes()).hexdigest()
        == COMPOSE_SHA256
    )
    (consumer / "tools/docker-compose").chmod(0o555)
    for name in ["consumer.mjs", "init-storage.mjs"]:
        (consumer / "app" / name).write_bytes(fixture_contents[name])
    for name in ["launch.mjs", "compose.host.yaml", "compose.retained.yaml"]:
        (consumer / name).write_bytes(fixture_contents[name])
    (consumer / "Dockerfile").write_bytes(fixture_contents["Node.Dockerfile"])
    deployment_assets = {}
    for source, target in [
        ("compose.webots.yaml", "compose.worker.yaml"),
        ("compose.webots.podman.yaml", "compose.podman.yaml"),
    ]:
        raw = subprocess.check_output(
            ["git", "show", source_revision + ":" + source], cwd=root
        )
        (consumer / target).write_bytes(raw)
        deployment_assets[source] = hashlib.sha256(raw).hexdigest()

    # Extend public deployment with declarative fixture roles, preserving source bytes.
    def env(name):
        return chr(36) + "{" + name + "}"

    fixture_compose = {
        "services": {
            "webots-native": {
                "command": [
                    "run",
                    "--output",
                    "/run/robotics/output/webots/"
                    + env("ROBOTICS_WEBOTS_SCOPE:?owned output scope required"),
                    "--owner-id",
                    env("ROBOTICS_RUN_ID:?run owner required"),
                    "--mode",
                    env("ROBOTICS_WEBOTS_MODE:-physics-only"),
                    "--deadline-seconds",
                    "90",
                    "--probe-reset",
                ],
            },
            "webots-documents": {
                "image": env("ROBOTICS_WEBOTS_IMAGE:?"),
                "pull_policy": "never",
                "init": True,
                "user": "10001:1000",
                "userns_mode": "keep-id:uid=1000,gid=1000",
                "network_mode": "none",
                "read_only": True,
                "cap_drop": ["ALL"],
                "security_opt": ["no-new-privileges:true"],
                "tmpfs": ["/tmp:rw,mode=1777,size=64m"],
                "volumes": ["run-data:/run/robotics:ro", "retained:/retained"],
                "labels": {"org.robotics.runtime.run-id": env("ROBOTICS_RUN_ID:?")},
            },
            "foreign-fixture": {
                "image": NODE,
                "pull_policy": "never",
                "init": True,
                "user": "1000:1000",
                "userns_mode": "keep-id:uid=1000,gid=1000",
                "network_mode": "none",
                "read_only": True,
                "cap_drop": ["ALL"],
                "security_opt": ["no-new-privileges:true"],
                "command": ["node", "-e", "setTimeout(() => {}, 30000)"],
                "labels": {"org.robotics.runtime.run-id": host_owner + "-foreign"},
            },
        },
        "volumes": {"retained": {"external": True, "name": args.retained_volume}},
    }
    (consumer / "compose.fixture.yaml").write_text(
        json.dumps(fixture_compose, indent=2) + "\n"
    )
    config = {
        "composeExecutable": "/usr/local/bin/docker-compose",
        "socketPath": "/engine.sock",
        "composeFiles": ["/app/" + name for name in COMPOSE_FILES],
        "cwd": "/app",
        "workerImage": args.worker_image,
        "runVolume": args.source_volume,
        "outputRoot": "/run/robotics/output/webots",
        "artifactDirectory": "/retained/native",
        "mode": "physics-only",
        "deadlineMs": 120000,
    }
    # The root bootstrap owns Jobs through native teardown; the run owns Webots.
    # JSON is an ordinary YAML subset consumed by the native Include loader.
    (consumer / "profiles/webots.yml").write_text(
        json.dumps(
            [
                {
                    "id": "webots",
                    "name": "@robotics-runtime/infra-host/plugins/webots",
                    "config": config,
                },
            ],
            indent=2,
        )
        + "\n"
    )
    (consumer / "profiles/missing-provider.yml").write_text(
        json.dumps([], indent=2) + "\n"
    )
    identity = {
        "fixture": {
            "revision": source_revision,
            "files": {
                name: hashlib.sha256(raw).hexdigest()
                for name, raw in fixture_contents.items()
            },
        },
        "deployment": {
            "revision": source_revision,
            "assets": deployment_assets,
            "composeFiles": COMPOSE_FILES,
        },
        "coreSource": asset_identity["core"]["revision"],
        "infraSource": asset_identity["infra"]["revision"],
        "assetSourceIdentity": asset_identity,
        "workerImage": args.worker_image,
        "observedImageId": observed_image_id,
        "RepoDigests": repo_digests,
        "publicPythonProbe": public_python,
        "foundationLock": {
            "revision": source_revision,
            "path": "config/foundation-lock.json",
            "sha256": lock_sha256,
            "document": foundation,
        },
        "nodeImage": NODE,
        "sourceVolume": args.source_volume,
        "retainedVolume": args.retained_volume,
        "hostOwner": host_owner,
        "hostProject": host_owner,
        "assets": {
            name: hashlib.sha256((consumer / "assets" / name).read_bytes()).hexdigest()
            for name in ["core.tgz", "infra.tgz"]
        },
    }
    (consumer / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
    (consumer / "package.json").write_text(
        json.dumps(
            {
                "name": "installed-webots-consumer",
                "version": "0.0.0",
                "private": True,
                "type": "module",
                "engines": {"node": "24.21.0", "npm": "11.19.0"},
                "dependencies": {
                    "@robotics-runtime/host": "file:assets/core.tgz",
                    "@robotics-runtime/infra-host": "file:assets/infra.tgz",
                },
            },
            indent=2,
        )
        + "\n"
    )
    print(json.dumps(identity))


if __name__ == "__main__":
    main()
