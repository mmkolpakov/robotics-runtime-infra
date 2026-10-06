"""Prepare installed ROS APIs with a finite deployment asset closure from exact Git."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

NODE = "docker.io/library/node@sha256:b64fccfbcd1ae10d11b969a868b50e1c2530a7054813d5cdea04ac3bce551697"
DEPLOYMENT = [
    "examples/neutral-robot/scenario.yaml",
    "examples/neutral-robot/sim/robot-description.json",
    "examples/neutral-robot/check-entity.py",
    "docker/runtime/admit-robot-description",
    "docker/runtime/emit-runtime-manifest",
    "config/foundation-lock.json",
    "config/qualification/simulation-interfaces.json",
    "scripts/ci/foundation/create-simulation-provider.py",
    "config/fastdds/udp-only.xml",
    "config/recording/qos-overrides.yaml",
    "host/test/fixtures/legacy-live/mcap-writer-small-segment.yaml",
    "host/test/fixtures/legacy-live/compose.yaml",
    "host/test/fixtures/legacy-live/evidence.yaml",
    "host/test/fixtures/legacy-live/otel-collector.yaml",
    "host/workers/legacy/prepare-source.py",
    "host/workers/legacy/observe-clock-owner.py",
    "host/workers/legacy/observe-robot-ready.py",
    "host/workers/legacy/capture-last-state.py",
    "host/workers/legacy-live/prepare-live.py",
    "host/workers/legacy-live/capture-provider.py",
    "host/workers/legacy-live/prepare-runtime.py",
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", choices=("podman", "docker"), default="podman")
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--consumer", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--deployment-revision", required=True)
    parser.add_argument("--compose", type=Path, required=True)
    parser.add_argument("--simulation-image", required=True)
    parser.add_argument("--simulation-id", required=True)
    parser.add_argument("--finalizer-image", required=True)
    parser.add_argument("--evidence-image", required=True)
    parser.add_argument("--source-volume", required=True)
    parser.add_argument("--retained-volume", required=True)
    args = parser.parse_args()
    engine_profile = {
        "engine": args.engine,
        "expectedUsernsMode": "" if args.engine == "docker" else "private",
    }
    root = args.repo.resolve(strict=True)
    consumer = args.consumer.resolve()
    if root == consumer or root in consumer.parents or consumer.exists():
        raise ValueError(
            "installed ROS consumer must be a fresh directory outside source"
        )
    identities = json.loads((args.assets / "source-identity.json").read_bytes())
    for component in ("core", "infra"):
        with (args.assets / f"{component}.tgz").open("rb") as stream:
            observed = hashlib.file_digest(stream, "sha256").hexdigest()
        if observed != identities[component]["sha256"]:
            raise ValueError(f"coordinated {component} TGZ checksum mismatch")
    for component in ("core", "infra"):
        entry = identities[component]
        if not isinstance(entry.get("revision"), str) or not re.fullmatch(
            r"[a-f0-9]{40}", entry["revision"]
        ):
            raise ValueError(f"coordinated {component} revision is invalid")
    if not re.fullmatch(r"[a-f0-9]{40}", args.deployment_revision):
        raise ValueError("deployment revision must be an immutable full Git commit")
    revision = subprocess.check_output(
        ["git", "rev-parse", "--verify", args.deployment_revision + "^{commit}"],
        cwd=root,
        text=True,
    ).strip()
    if revision != args.deployment_revision:
        raise ValueError("deployment revision did not resolve to its exact Git commit")
    fixture_revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()
    expected_lock = json.loads(
        subprocess.check_output(
            ["git", "show", revision + ":config/foundation-lock.json"], cwd=root
        )
    )
    expected_versions = {
        package["distribution"]: package["version"]
        for package in expected_lock["packages"].values()
    }
    observed_images = {}
    for component, reference in (
        ("simulation", args.simulation_image),
        ("finalizer", args.finalizer_image),
        ("evidence", args.evidence_image),
    ):
        rows = json.loads(
            subprocess.check_output([args.engine, "image", "inspect", reference])
        )
        if len(rows) != 1 or reference not in rows[0].get("RepoDigests", []):
            raise ValueError(
                f"{component} reference is not an observed local RepoDigest"
            )
        observed_images[component] = {
            "imageId": rows[0]["Id"],
            "repoDigests": rows[0]["RepoDigests"],
            "reference": reference,
        }
        probe = json.loads(
            subprocess.check_output(
                [
                    args.engine,
                    "run",
                    "--rm",
                    "--network",
                    "none",
                    "--read-only",
                    "--env",
                    "PYTHONDONTWRITEBYTECODE=1",
                    "--entrypoint",
                    "/opt/contracts/bin/python",
                    rows[0]["Id"],
                    "-c",
                    'import json;from importlib.metadata import version;lock=json.load(open("/usr/share/robotics-runtime/foundation-lock.json"));print(json.dumps({"foundationLock":lock,"versions":{p["distribution"]:version(p["distribution"]) for p in lock["packages"].values()}}))',
                ]
            )
        )
        if (
            probe["foundationLock"] != expected_lock
            or probe["versions"] != expected_versions
        ):
            raise ValueError(
                f"{component} actual Python cohort differs from the exact deployment lock"
            )
        observed_images[component]["publicPython"] = probe
    if observed_images["simulation"]["imageId"].removeprefix(
        "sha256:"
    ) != args.simulation_id.removeprefix("sha256:"):
        raise ValueError(
            "simulation source image ID differs from the observed reference"
        )

    def source(path, rev=revision):
        return subprocess.check_output(["git", "show", f"{rev}:{path}"], cwd=root)

    consumer.mkdir()
    for name in ("assets", "app", "profiles", "tools", "deployment"):
        (consumer / name).mkdir()
    for component in ("core", "infra"):
        shutil.copyfile(
            args.assets / f"{component}.tgz", consumer / "assets" / f"{component}.tgz"
        )
    shutil.copyfile(args.compose, consumer / "tools/docker-compose")
    (consumer / "tools/docker-compose").chmod(0o555)
    if (
        hashlib.sha256((consumer / "tools/docker-compose").read_bytes()).hexdigest()
        != "f9ebc6ebdb19d769b793c245a736caaeb198c62587f13b25c660c13b4987f959"
    ):
        raise ValueError("Compose executable identity mismatch")
    manifest = json.loads(source("examples/neutral-robot/sim/robot-description.json"))
    paths = set(DEPLOYMENT)
    paths.update(
        row["path"]
        for row in (manifest["source"], manifest["description"], *manifest["meshes"])
    )
    paths.add(manifest["package"]["path"] + "/package.xml")
    exported = {}
    for name in sorted(paths):
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("deployment input escapes the consumer")
        raw = source(name)
        target = consumer / "deployment" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
        target.chmod(0o444)
        exported[name] = {
            "sha256": hashlib.sha256(raw).hexdigest(),
            "size_bytes": len(raw),
        }
    overlay = "host/test/fixtures/legacy-live/compose.podman.yaml"
    raw = source(overlay, fixture_revision)
    target = consumer / "deployment" / overlay
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(raw)
    target.chmod(0o444)
    exported[overlay] = {
        "revision": fixture_revision,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "size_bytes": len(raw),
    }
    for name in (
        "compose.legacy-retained.yaml",
        "compose.legacy-finalization.podman.yaml",
    ):
        (consumer / name).write_bytes(source(name))
    for name in (
        "postprocess.mjs",
        "launch.mjs",
        "compose.host.yaml",
        "compose.host.podman.yaml",
        "compose.post.yaml",
        "compose.post.podman.yaml",
        "Node.Dockerfile",
    ):
        destination = consumer / ("Dockerfile" if name == "Node.Dockerfile" else name)
        if name == "postprocess.mjs":
            destination = consumer / "app" / name
        destination.write_bytes(
            source("host/test/fixtures/installed-legacy/" + name, fixture_revision)
        )
    (consumer / "app/init-storage.mjs").write_bytes(
        source("host/test/fixtures/installed-webots/init-storage.mjs", fixture_revision)
    )
    (consumer / "app/qualify-legacy-live.mjs").write_bytes(
        source("host/tools/qualify-legacy-live.mjs", fixture_revision)
    )
    (consumer / "app/bootstrap.mjs").write_bytes(
        source("host/test/fixtures/installed-legacy/bootstrap.mjs", fixture_revision)
    )
    (consumer / "profiles/ros.yml").write_text(
        json.dumps(
            [
                {
                    "id": "gazebo",
                    "name": "@robotics-runtime/infra-host/plugins/gazebo-ros-v1",
                }
            ]
        )
        + "\n"
    )
    identity = {
        "fixtureSource": fixture_revision,
        "engineProfile": engine_profile,
        "assetSourceIdentity": identities,
        "deploymentRevision": revision,
        "deployment": exported,
        "observedImages": observed_images,
        "simulationImage": args.simulation_image,
        "simulationId": args.simulation_id,
        "finalizerImage": args.finalizer_image,
        "evidenceImage": args.evidence_image,
        "sourceVolume": args.source_volume,
        "retainedVolume": args.retained_volume,
        "nodeBase": NODE,
        "foundationLock": expected_lock,
        "publicPythonScope": {
            name: package["version"]
            for name, package in expected_lock["packages"].items()
        },
        "homeComposeQualification"
        if args.engine == "podman"
        else "composeQualification": {
            "version": "5.3.1",
            "environment": {"COMPOSE_PARALLEL_LIMIT": "1"},
            "scope": "HOME source qualification only"
            if args.engine == "podman"
            else "Docker CI source qualification only",
        },
    }
    (consumer / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
    (consumer / "package.json").write_text(
        json.dumps(
            {
                "name": "installed-ros-host-consumer",
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
