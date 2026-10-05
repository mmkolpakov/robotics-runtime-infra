"""Finite product-file validation; never run production roles or service modules."""

from pathlib import Path
import json
import os
import pwd
import re
import stat
import subprocess

ROOT = Path("/src")
STAGED = Path("/tmp/robotics-product-node-fixture")
os.environ["ANSIBLE_INVENTORY"] = "/src/ansible/tests/inventory.yml"
BASE = ["ansible-playbook", "-i", "tests/inventory.yml"]


def run(args, expected=0):
    result = subprocess.run(args, text=True, capture_output=True, timeout=120)
    if result.returncode != expected:
        raise AssertionError(result.stdout + result.stderr)
    return result.stdout + result.stderr


run(BASE + ["product-nodes.yml", "--syntax-check"])
run(
    [
        "ansible-lint",
        "--offline",
        "product-nodes.yml",
        "roles",
        "tests/files.yml",
        "tests/validate.yml",
        "tests/permissions.yml",
    ]
)
run(BASE + ["tests/validate.yml"])
guard = run(BASE + ["product-nodes.yml", "-e", "@tests/site.yml"], expected=2)
assert "Enroll Ubuntu 24.04 product nodes over SSH" in guard, guard
negative_cases = [
    {"robotics_node_enrolled": False},
    {"robotics_node_features": []},
    {"robotics_node_features": {"time_chrony": False}},
    {"robotics_node_features": ["control_can"]},
    {"robotics_node_features": ["time_chrony", "time_chrony"]},
    {"robotics_node_time_evidence_dir": "/var/lib/robotics/../outside"},
    {"robotics_node_chrony_existing_config_reviewed": False},
    {"robotics_node_chrony_sources": ["server clock.example.invalid\ncmdport 323"]},
    {"robotics_node_ptp_domain": 128},
    {"robotics_node_ptp_interface": "eth0;touch"},
    {"robotics_node_ptp_time_source": "local-grandmaster"},
    {"robotics_node_can_network_ready": False},
    {
        "robotics_node_can_interfaces": [
            {"name": "can0", "bitrate": 0, "device_identity": "/sys/devices/pci"}
        ]
    },
    {"robotics_node_nonce_dir": "/var/lib/robotics/authorization-output/nonces"},
    {"robotics_node_nonce_dir": "/var/lib/robotics/time-evidence"},
    {"robotics_node_physical_device_identities": ["/dev/ttyUSB0"]},
]
for values in negative_cases:
    output = run(BASE + ["tests/validate.yml", "-e", json.dumps(values)], expected=2)
    assert "Assertion failed" in output or "assertion" in output.lower(), output

first = run(BASE + ["tests/files.yml"])
second = run(BASE + ["tests/files.yml"])
assert re.search(r"changed=0\s+unreachable=0\s+failed=0", second), second
dry_run = run(BASE + ["tests/files.yml", "--check", "--diff"])
assert re.search(r"changed=0\s+unreachable=0\s+failed=0", dry_run), dry_run
canonical = {
    "scripts/time/sample.sh": "usr/local/libexec/robotics-time/sample.sh",
    "scripts/time/normalize-sample.jq": "usr/local/libexec/robotics-time/normalize-sample.jq",
    "tmpfiles.d/robotics-time.conf": "etc/tmpfiles.d/robotics-time.conf",
    "config/time/chrony-command-socket.conf": "etc/chrony/conf.d/robotics-command-socket.conf",
    "systemd/robotics-can-observation@.service": "etc/systemd/system/robotics-can-observation@.service",
}
for protocol in ["chrony", "ptp"]:
    for kind in ["service", "timer"]:
        name = f"robotics-{protocol}-sample.{kind}"
        canonical["systemd/" + name] = "etc/systemd/system/" + name
for original, installed in canonical.items():
    assert (ROOT / original).read_bytes() == (STAGED / installed).read_bytes()
    mode = 0o755 if installed.endswith("sample.sh") else 0o644
    assert stat.S_IMODE((STAGED / installed).stat().st_mode) == mode
ptp = (STAGED / "etc/linuxptp/robotics-ptp4l.conf").read_text()
assert "domainNumber 24\n" in ptp and "domainNumber 0\n" not in ptp
for line in (ROOT / "config/time/ptp4l.conf").read_text().splitlines():
    if not line.startswith("domainNumber "):
        assert line in ptp
assert "clientOnly 1\n" in ptp and "[enp1s0]" in ptp
assert (
    (STAGED / "etc/chrony/conf.d/robotics-sources.conf")
    .read_text()
    .endswith("server clock.example.invalid iburst\n")
)
for directory, uid, gid, mode in [
    ("var/lib/robotics/nonces", 10002, 10002, 0o700),
    ("var/lib/robotics/authorization-output", 10002, 10002, 0o755),
    (
        "var/lib/robotics/time-evidence",
        pwd.getpwnam("_chrony").pw_uid,
        pwd.getpwnam("_chrony").pw_gid,
        0o770,
    ),
]:
    facts = (STAGED / directory).stat()
    assert (facts.st_uid, facts.st_gid, stat.S_IMODE(facts.st_mode)) == (uid, gid, mode)

parent_alias = STAGED / "var/lib/robotics/alias-parent"
parent_target = Path("/tmp/robotics-parent-symlink-target")
parent_target.mkdir(mode=0o755)
parent_before = parent_target.stat()
parent_alias.symlink_to(parent_target, target_is_directory=True)
rejected_parent = run(
    BASE
    + [
        "tests/permissions.yml",
        "-e",
        json.dumps(
            {
                "robotics_node_nonce_dir": "/var/lib/robotics/alias-parent/nonces",
            }
        ),
    ],
    expected=2,
)
assert "Reject physical stores reached through ancestor symlinks" in rejected_parent
assert not (parent_target / "nonces").exists()
parent_after = parent_target.stat()
assert (parent_before.st_uid, parent_before.st_gid, parent_before.st_mode) == (
    parent_after.st_uid,
    parent_after.st_gid,
    parent_after.st_mode,
)
parent_alias.unlink()

nonce = STAGED / "var/lib/robotics/nonces"
target = Path("/tmp/robotics-nonce-symlink-target")
target.mkdir(mode=0o755)
before_target = target.stat()
nonce.rmdir()
nonce.symlink_to(target, target_is_directory=True)
rejected = run(BASE + ["tests/permissions.yml"], expected=2)
assert "Reject physical stores reached through ancestor symlinks" in rejected, rejected
after_target = target.stat()
assert (before_target.st_uid, before_target.st_gid, before_target.st_mode) == (
    after_target.st_uid,
    after_target.st_gid,
    after_target.st_mode,
)

print(
    json.dumps(
        {
            "syntax": "passed",
            "lint": "passed",
            "negative_cases": len(negative_cases),
            "canonical_assets": len(canonical),
            "file_modules_second_apply": "changed=0",
            "check_diff": "changed=0",
            "nonce_symlink": "rejected_without_target_change",
            "ancestor_symlink": "rejected_before_creation",
            "services_and_hardware": "not_applied",
        }
    )
)
