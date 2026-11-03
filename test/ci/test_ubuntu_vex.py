"""Identity projection tests; supplier data here is a synthetic test fixture."""

import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
PURL = "pkg:deb/ubuntu/linux-libc-dev@6.8.0-147.147?arch=amd64&distro=ubuntu-24.04"
COMMIT = "f904483357e84d1836895448ed579c7aa1bede4f"


class UbuntuVexIdentityTest(unittest.TestCase):
    def setUp(self):
        (REPO / "artifacts").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=REPO / "artifacts")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.script = self.root / "scripts/ci/security/prepare-ubuntu-vex.py"
        self.script.parent.mkdir(parents=True)
        shutil.copyfile(REPO / "scripts/ci/security/prepare-ubuntu-vex.py", self.script)
        self.raw = self.root / "vendor"
        self.raw.mkdir()
        self.statement = {
            "vulnerability": {"name": "CVE-2026-63825"},
            "products": [{"@id": PURL.replace("ubuntu-24.04", "noble")}],
            "status": "not_affected",
            "justification": "vulnerable_code_not_present",
            "timestamp": "2026-10-30T00:00:00Z",
            "impact_statement": "Synthetic test fixture; no applicability claim.",
        }
        self.vendor = {
            "@context": "https://openvex.dev/ns/v0.2.0",
            "@id": "urn:uuid:fixture",
            "author": "Canonical Ltd.",
            "timestamp": "2026-10-30T00:00:00Z",
            "version": 1,
            "statements": [self.statement],
        }
        self.report = {
            "SchemaVersion": 2,
            "ArtifactName": "synthetic-fixture",
            "Metadata": {"OS": {"Family": "ubuntu", "Name": "24.04"}},
            "Results": [
                {"Packages": [{"Arch": "amd64", "Identifier": {"PURL": PURL}}]}
            ],
        }
        self.os = "ID=ubuntu\nVERSION_ID=24.04\nVERSION_CODENAME=noble\n"
        self.purl, self.commit = PURL, COMMIT
        self.write_inputs()

    def write_inputs(self):
        raw = (json.dumps(self.vendor) + "\n").encode()
        (self.raw / "CVE-2026-63825.json").write_bytes(raw)
        pin = {
            "source_commit": COMMIT,
            "files": [
                {
                    "name": "CVE-2026-63825.json",
                    "sha256": hashlib.sha256(raw).hexdigest(),
                }
            ],
        }
        (self.root / "security/vex").mkdir(parents=True, exist_ok=True)
        (self.root / "security/vex/canonical-source.json").write_text(json.dumps(pin))
        (self.root / "report.json").write_text(json.dumps(self.report))
        (self.root / "os-release").write_text(self.os)

    def prepare(self, output_name="out"):
        return subprocess.run(
            [
                sys.executable,
                str(self.script),
                "--vendor-dir",
                str(self.raw),
                "--source-commit",
                self.commit,
                "--scan-report",
                str(self.root / "report.json"),
                "--os-release",
                str(self.root / "os-release"),
                "--package-purl",
                self.purl,
                "--output-dir",
                str(self.root / output_name),
            ],
            capture_output=True,
            text=True,
        )

    def test_preserves_supplier_bytes_and_statement_with_own_authorship(self):
        self.assertEqual(self.prepare().returncode, 0)
        output = self.root / "out"
        derived = json.loads((output / "canonical-ubuntu.openvex.json").read_text())
        expected = copy.deepcopy(self.statement)
        expected["products"] = [{"@id": PURL}]
        self.assertEqual(derived["statements"], [expected])
        self.assertEqual(derived["author"], "mmkolpakov")
        self.assertNotEqual(derived["@id"], self.vendor["@id"])
        self.assertEqual(self.prepare("second").returncode, 0)
        second = json.loads(
            (self.root / "second/canonical-ubuntu.openvex.json").read_text()
        )
        self.assertNotEqual(derived["@id"], second["@id"])
        self.assertEqual(
            (output / "raw/CVE-2026-63825.json").read_bytes(),
            (self.raw / "CVE-2026-63825.json").read_bytes(),
        )
        self.assertEqual(
            subprocess.run(
                ["sha256sum", "--strict", "--check", "SHA256SUMS"],
                cwd=output,
                capture_output=True,
            ).returncode,
            0,
        )

    def test_rejects_inexact_and_unobserved_identities(self):
        for value in (
            PURL.replace("147.147", "142.142"),
            PURL.replace("amd64", "ppc64el"),
            PURL.replace("/ubuntu/", "/debian/"),
            PURL.replace("24.04", "22.04"),
            PURL + "&extra=value",
            PURL.replace("&distro=ubuntu-24.04", ""),
            "not-a-purl",
        ):
            with self.subTest(value=value):
                self.purl = value
                self.report["Results"][0]["Packages"][0]["Identifier"]["PURL"] = value
                self.write_inputs()
                self.assertNotEqual(self.prepare().returncode, 0)
                self.assertFalse((self.root / "out").exists())

    def test_rejects_os_arch_revision_tamper_and_ambiguity(self):
        for case in ("os", "report_os", "arch", "revision", "tamper", "ambiguous"):
            with self.subTest(case=case):
                self.setUp()
                if case == "os":
                    self.os = self.os.replace("noble", "unknown")
                if case == "report_os":
                    self.report["Metadata"]["OS"]["Family"] = "debian"
                if case == "arch":
                    self.report["Results"][0]["Packages"][0]["Arch"] = "arm64"
                if case == "revision":
                    self.commit = "0" * 40
                if case == "ambiguous":
                    self.vendor["statements"] *= 2
                self.write_inputs()
                if case == "tamper":
                    (self.raw / "CVE-2026-63825.json").write_text("{}")
                self.assertNotEqual(self.prepare().returncode, 0)
                self.assertFalse((self.root / "out").exists())

    def test_preserves_affected_and_under_investigation_for_stock_decision(self):
        for status in ("affected", "under_investigation"):
            with self.subTest(status=status):
                self.setUp()
                self.vendor["statements"][0]["status"] = status
                self.write_inputs()
                self.assertEqual(self.prepare().returncode, 0)
                derived = json.loads(
                    (self.root / "out/canonical-ubuntu.openvex.json").read_text()
                )
                self.assertEqual(derived["statements"][0]["status"], status)


if __name__ == "__main__":
    unittest.main()
