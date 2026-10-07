"""Export exact public producer/config inputs for an ordinary worker install."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--producer-revision", required=True)
    args = parser.parse_args()
    root = args.repo.resolve(strict=True)
    fixture_revision = subprocess.check_output(
        ["git", "rev-parse", "--verify", "HEAD^{commit}"], cwd=root, text=True
    ).strip()
    producer_revision = subprocess.check_output(
        ["git", "rev-parse", "--verify", args.producer_revision + "^{commit}"],
        cwd=root,
        text=True,
    ).strip()
    exports = {
        "Dockerfile": (
            fixture_revision,
            "host/test/fixtures/installed-webots/worker/Dockerfile",
        ),
        "document-checks.py": (
            fixture_revision,
            "host/test/fixtures/installed-webots/worker/document-checks.py",
        ),
        "portable-checks.py": (
            fixture_revision,
            "host/test/fixtures/installed-webots/worker/portable-checks.py",
        ),
        "assets/provider_qualification.py": (
            producer_revision,
            "host/producers/provider_qualification.py",
        ),
        "assets/native-provider-source.v1.schema.json": (
            producer_revision,
            "config/qualification/native-provider-source.v1.schema.json",
        ),
        "assets/dependencies.lock": (
            fixture_revision,
            "docker/python/acceptance-observer.lock",
        ),
        "assets/foundation-lock.json": (
            fixture_revision,
            "config/foundation-lock.json",
        ),
    }
    # Resolve every Git asset before writing the build context.
    contents = {
        target: subprocess.check_output(
            ["git", "show", revision + ":" + source], cwd=root
        )
        for target, (revision, source) in exports.items()
    }
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "assets").mkdir(exist_ok=True)
    identity = {
        "fixtureSource": fixture_revision,
        "producerSource": producer_revision,
        "exports": {},
    }
    for target, raw in contents.items():
        (args.output / target).write_bytes(raw)
        source_revision, source = exports[target]
        identity["exports"][target] = {
            "revision": source_revision,
            "path": source,
            "sha256": hashlib.sha256(raw).hexdigest(),
        }
    (args.output / "source-identity.json").write_text(
        json.dumps(identity, indent=2) + "\n"
    )


if __name__ == "__main__":
    main()
