from __future__ import annotations

import importlib.util
import re
import shlex
import subprocess
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "px4_source_factory", ROOT / "host/tools/prepare-px4-image.py"
)
assert SPEC is not None and SPEC.loader is not None
FACTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FACTORY)


def apt_input_stages():
    for name, stage in (
        ("px4-sitl-deps.Dockerfile", "dependency-inputs"),
        ("px4-sitl-native-source.Dockerfile", "native-source-inputs"),
        ("px4-sitl-native-source.Dockerfile", "native-source-runtime-inputs"),
    ):
        recipe = (ROOT / "docker" / name).read_text()
        body = recipe.split(" AS " + stage + "\n", 1)[1].split("\nFROM ", 1)[0]
        runs = []
        lines = iter(body.splitlines(keepends=True))
        for line in lines:
            if not line.startswith("RUN "):
                continue
            command = line[4:]
            while command.rstrip().endswith("\\"):
                command += next(lines)
            runs.append(re.sub(r"^(?:--(?:mount|network)=\S+\s+)+", "", command))
        yield stage, runs


def apt_selection(commands):
    selection = re.search(
        r"mapfile -t apt_packages.*?\n\s*&& test .*?-gt 0", commands, re.S
    )
    assert selection is not None
    return selection[0]


class SourceInputs(unittest.TestCase):
    def test_real_source_lock_and_legacy_wheel_are_distinct(self):
        lock, _ = FACTORY.source_sdk_lock()
        self.assertEqual(
            lock["sdk"]["commit"], "2da0f3f85f0cd1ed12f981dcac17b647030186f0"
        )
        self.assertEqual(lock["origin"], "project-source-build")
        self.assertIn(
            "mavsdk==4.1.0", (ROOT / "docker/python/px4-native-sdk.lock").read_text()
        )
        self.assertEqual(len(lock["archives"]), 5)
        self.assertEqual(
            lock["archives"]["pymavlink"]["commit"], lock["mavlink_pymavlink_commit"]
        )

    def test_missing_apt_evidence_never_reaches_backend(self):
        lock, _ = FACTORY.source_sdk_lock()
        lock.pop("apt_closure", None)
        with patch.object(FACTORY.subprocess, "run") as backend:
            for target in ("worker", "native-sdk-source"):
                with (
                    self.subTest(target=target),
                    self.assertRaisesRegex(ValueError, "closed APT inputs"),
                ):
                    FACTORY.require_apt_closure(lock, target)
            backend.assert_not_called()
        for target in ("native-source-inputs", "native-source-runtime-inputs"):
            FACTORY.require_apt_closure(lock, target)

    def test_corrupt_cached_source_is_refused_without_download(self):
        lock, _ = FACTORY.source_sdk_lock()
        item = lock["archives"]["MAVLink"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "host/.tools/mavsdk-source-cache"
            cache.mkdir(parents=True)
            retained = cache / (item["sha256"] + ".tar.gz")
            retained.write_bytes(b"corrupt")
            with (
                patch.object(FACTORY, "ROOT", root),
                patch.object(FACTORY.subprocess, "run") as download,
            ):
                with self.assertRaisesRegex(
                    ValueError, "retained source archive differs"
                ):
                    FACTORY.source_archive(item)
                download.assert_not_called()

    def test_tag_and_clean_tree_are_checked_with_stock_git(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "host/.tools/sdk"
            repo.mkdir(parents=True)

            def git(*args):
                return subprocess.check_output(
                    ["git", "-C", str(repo), *args], text=True
                ).strip()

            git("init", "--quiet")
            source = repo / "source.txt"
            source.write_text("source")
            git("add", "source.txt")
            git(
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.test",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "--quiet",
                "-m",
                "fixture",
            )
            commit = git("rev-parse", "HEAD")
            git("tag", "v4.2.0")
            lock = {
                "sdk": {
                    "commit": commit,
                    "tree": git("rev-parse", "HEAD^{tree}"),
                    "tag": "v4.2.0",
                }
            }
            with patch.object(FACTORY, "ROOT", root):
                self.assertEqual(FACTORY.validate_sdk_source(repo, lock), repo)
                source.write_text("changed")
                with self.assertRaisesRegex(ValueError, "clean tagged"):
                    FACTORY.validate_sdk_source(repo, lock)
                with self.assertRaisesRegex(ValueError, "project tool directory"):
                    FACTORY.validate_sdk_source(root / "outside", lock)

    def test_source_build_uses_bounded_graceful_backend_and_closed_inputs(self):
        args = Namespace(
            deps_image="sha256:" + "a" * 64,
            build_target="native-sdk-source",
            tag="localhost/test:source",
        )
        closure = {"inventory_sha256": "b" * 64, "deb_manifest_sha256": "c" * 64}
        lock = {
            "platform": "linux/amd64",
            "ubuntu_snapshot": "20261113T000000Z",
            "apt_closure": {"build": closure},
        }
        with patch.object(FACTORY.subprocess, "run") as backend:
            FACTORY.build_image(
                args, Path("/owned/context"), Path("/owned/Dockerfile"), lock
            )
        argv = backend.call_args.args[0]
        self.assertEqual(
            argv[:4],
            ["/usr/bin/timeout", "--signal=TERM", "--kill-after=120s", "6600s"],
        )
        self.assertNotIn("timeout", backend.call_args.kwargs)
        self.assertIn("APT_BUILD_CLOSURE_SHA256=" + "b" * 64, argv)
        self.assertIn("--force-rm", argv)
        self.assertEqual(argv[argv.index("--target") + 1], "native-sdk-source")

    def test_apt_bootstrap_selects_only_installed_source_family(self):
        rows = [
            "apt\tapt\tinstalled",
            "libapt-pkg6.0t64:amd64\tapt\tinstalled",
            "apt-utils\tapt\tinstalled",
            "apt-transport-https\tapt\tconfig-files",
            "unrelated\tother\tinstalled",
        ]
        for stage, runs in apt_input_stages():
            with self.subTest(stage=stage):
                commands = next(run for run in runs if "mapfile -t apt_packages" in run)
                script = (
                    "dpkg-query() { printf '%s\\n' "
                    + shlex.quote("\n".join(rows))
                    + "; }\n"
                    + apt_selection(commands)
                    + "\nprintf '%s\\n' \"\x24{apt_packages[@]}\""
                )
                result = subprocess.run(
                    ["bash", "-eu", "-c", script],
                    capture_output=True,
                    text=True,
                    check=True,
                )
                self.assertEqual(
                    result.stdout.splitlines(),
                    ["apt", "libapt-pkg6.0t64:amd64", "apt-utils"],
                )

    def test_empty_installed_apt_family_fails_before_bootstrap(self):
        for stage, runs in apt_input_stages():
            with self.subTest(stage=stage):
                commands = next(run for run in runs if "mapfile -t apt_packages" in run)
                script = (
                    "dpkg-query() { printf '%s\\n' "
                    "'apt\tapt\tconfig-files' 'unrelated\tother\tinstalled'; }\n"
                    + apt_selection(commands)
                    + "\nprintf 'bootstrap-reached\\n'"
                )
                result = subprocess.run(
                    ["bash", "-eu", "-c", script],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("bootstrap-reached", result.stdout)

    def test_security_floor_checks_every_selected_source_version_with_stock_dpkg(self):
        fixed = "2.8.4ubuntu0.1"
        packages = ["apt", "libapt-pkg6.0t64:amd64", "apt-utils"]
        versions = [
            ([fixed] * 3, True),
            (["2.8.4ubuntu0.2"] * 3, True),
            (["2.8.3", fixed, fixed], False),
            ([fixed, "2.8.3", fixed], False),
            ([fixed, fixed, "2.8.3"], False),
            ([fixed, fixed, "2.8.4ubuntu0.1~pre1"], False),
        ]
        for stage, runs in apt_input_stages():
            commands = next(run for run in runs if "mapfile -t apt_packages" in run)
            guard = re.search(r"for package in .*?\bdone\b", commands, re.S)
            assert guard is not None
            self.assertIn("-f='\x24{source:Version}'", guard[0])
            for values, accepted in versions:
                with self.subTest(stage=stage, versions=values):
                    cases = " ".join(
                        f"{shlex.quote(name)}) printf '%s' {shlex.quote(version)} ;;"
                        for name, version in zip(packages, values, strict=True)
                    )
                    script = (
                        "apt_packages=(apt libapt-pkg6.0t64:amd64 apt-utils)\n"
                        'dpkg-query() { case "\x24{@: -1}" in '
                        + cases
                        + " esac; }\n"
                        + guard[0]
                        + "\nprintf 'floor-passed\\n'"
                    )
                    result = subprocess.run(
                        ["bash", "-eu", "-c", script],
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)
                    self.assertEqual("floor-passed" in result.stdout, accepted)

    def test_dependency_bootstrap_precedes_ordinary_installs_and_capture(self):
        stage, runs = next(apt_input_stages())
        self.assertEqual(stage, "dependency-inputs")
        commands = next(run for run in runs if "mapfile -t apt_packages" in run)
        calls = re.findall(r"&& apt-get .*", commands)
        self.assertTrue(calls[0].endswith("update \\"))
        self.assertIn("-o Acquire::Retries=0", calls[0])
        self.assertIn("-o Acquire::Retries=0", calls[1])
        self.assertIn("--only-upgrade --no-remove", calls[1])
        self.assertIn('"\x24{apt_packages[@]}"', calls[1])
        self.assertIn("ca-certificates=", calls[2])
        floor = commands.index("dpkg --compare-versions")
        self.assertLess(commands.index(calls[0]), commands.index(calls[1]))
        self.assertLess(commands.index(calls[1]), floor)
        self.assertLess(floor, commands.index(calls[2]))
        self.assertLess(commands.index(calls[2]), commands.index("apt-closure.txt"))

    def test_source_apt_bootstrap_preserves_measured_two_stage_inputs(self):
        for stage, runs in apt_input_stages():
            for command in runs:
                subprocess.run(["bash", "-n"], input=command, text=True, check=True)
            if stage == "dependency-inputs":
                continue
            kind = "build" if stage == "native-source-inputs" else "runtime"
            with self.subTest(stage=stage):
                commands = next(run for run in runs if "mapfile -t apt_packages" in run)
                calls = [
                    line for line in commands.splitlines() if "&& apt-get " in line
                ]
                self.assertEqual(len(calls), 4)
                self.assertTrue(all("-o Acquire::Retries=0" in line for line in calls))
                self.assertIn("--download-only --only-upgrade --no-remove", calls[1])
                self.assertIn('"\x24{apt_packages[@]}"', calls[1])
                self.assertIn("--no-download --no-remove", calls[-1])
                self.assertIn('"\x24{apt_packages[@]}"', calls[-1])
                manifest = commands.index(
                    ": > /usr/share/robotics-px4/sdk-source/" + kind + "-debs.tsv"
                )
                self.assertLess(commands.index(calls[2].strip()), manifest)
                self.assertLess(manifest, commands.index(calls[-1].strip()))
                floor = commands.index("dpkg --compare-versions")
                self.assertLess(commands.index(calls[-1].strip()), floor)
                self.assertLess(floor, commands.index(kind + "-apt-closure.tsv"))

    def test_source_options_do_not_change_old_controller_defaults(self):
        tool = ROOT / "host/tools/prepare-px4-image.py"
        for controller in ("legacy", "native-python"):
            result = subprocess.run(
                [
                    "python3",
                    str(tool),
                    "--controller",
                    controller,
                    "--deps-image",
                    "sha256:" + "a" * 64,
                    "--build-target",
                    "native-sdk-source",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn(
                "source SDK inputs require native-python-source", result.stderr
            )


if __name__ == "__main__":
    unittest.main()
