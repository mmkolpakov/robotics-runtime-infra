"""Offline chart and identity-fixture checks; never installs a release or calls a cluster."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import yaml
import jsonschema

ROOT = Path("/src/helm")
CHARTS = ["robotics-storage-class", "robotics-retained-spool", "robotics-run"]
NAMESPACE = "robotics"
BINDING = {
    "runId": "run-configuration-only",
    "domainId": "simulation",
    "profileId": "kubernetes-candidate",
    "profileSha256": "a" * 64,
}
IMAGE = "configuration-only.invalid/runtime@sha256:" + "b" * 64
VALUES = {
    "enabled": True,
    "name": "run-configuration-only",
    "mode": "simulation",
    "binding": BINDING,
    "spool": {
        "name": "spool-configuration-only",
        "uid": "11111111-1111-4111-8111-111111111111",
        "release": "spool-configuration-only",
        "storageClassName": "retained-gp3",
    },
    "identity": {
        "serviceAccount": "evidence-sink",
        "namespace": NAMESPACE,
        "region": "eu-west-1",
        "bucket": "configuration-only-evidence",
        "prefix": "retained",
    },
    "preflightImage": IMAGE,
    "deadlineSeconds": 1800,
    "terminationGracePeriodSeconds": 30,
    "ttlSecondsAfterFinished": 86400,
    "host": {
        "image": IMAGE,
        "command": ["/opt/robotics/candidate-host"],
        "args": [],
        "env": {},
        "uid": 1000,
        "resources": {
            "requests": {"cpu": "250m", "memory": "256Mi"},
            "limits": {"cpu": "1", "memory": "1Gi"},
        },
    },
    "workers": [
        {
            "name": "native-worker",
            "image": IMAGE,
            "command": ["/opt/robotics/stock-worker"],
            "args": ["--endpoint", "127.0.0.1:50051"],
            "env": {},
            "uid": 10001,
            "resources": {
                "requests": {"cpu": "250m", "memory": "256Mi"},
                "limits": {"cpu": "1", "memory": "1Gi"},
            },
            "ports": [{"name": "grpc", "containerPort": 50051}],
            "terminationCommand": [
                "/opt/robotics/stock-stop-client",
                "127.0.0.1:50051",
            ],
        }
    ],
}
SWAGGER = json.loads(Path("/opt/kubernetes/swagger.json").read_text())
DEFINITIONS = SWAGGER["definitions"]
KINDS = {}
for name, definition in DEFINITIONS.items():
    for gvk in definition.get("x-kubernetes-group-version-kind", []):
        api = (
            gvk["version"] if not gvk["group"] else gvk["group"] + "/" + gvk["version"]
        )
        KINDS[(api, gvk["kind"])] = name


def command(args, expect_success=True):
    result = subprocess.run(args, text=True, capture_output=True, timeout=60)
    if expect_success:
        assert result.returncode == 0, result.stdout + result.stderr
    else:
        assert result.returncode != 0, result.stdout + result.stderr
    return result.stdout


def render(chart, values=None, success=True):
    with tempfile.TemporaryDirectory(prefix="helm-values-") as directory:
        arguments = [
            "helm",
            "template",
            "configuration-only",
            str(ROOT / chart),
            "--namespace",
            NAMESPACE,
            "--kube-version",
            "1.34.0",
        ]
        if values is not None:
            path = Path(directory) / "values.json"
            path.write_text(json.dumps(values))
            arguments += ["--values", str(path)]
        if success:
            lint_arguments = [
                "helm",
                "lint",
                "--strict",
                str(ROOT / chart),
                "--kube-version",
                "1.34.0",
            ]
            if values is not None:
                lint_arguments += ["--values", str(path)]
            command(lint_arguments)
        output = command(arguments, success)
        return [obj for obj in yaml.safe_load_all(output) if obj] if success else []


for chart in CHARTS:
    assert render(chart) == [], "disabled default emitted a resource"

storage = render(
    "robotics-storage-class",
    {
        "enabled": True,
        "name": "retained-gp3",
        "identity": {"namespace": NAMESPACE, "serviceAccount": "evidence-sink"},
    },
)
spool = render(
    "robotics-retained-spool",
    {
        "enabled": True,
        "name": VALUES["spool"]["name"],
        "storageClassName": "retained-gp3",
        "capacity": "20Gi",
        "binding": BINDING,
    },
)
run = render("robotics-run", VALUES)
recovery_values = copy.deepcopy(VALUES)
recovery_values.update({"mode": "export-recovery", "workers": []})
recovery = render("robotics-run", recovery_values)
recovery_job = next(obj for obj in recovery if obj["kind"] == "Job")
assert [c["name"] for c in recovery_job["spec"]["template"]["spec"]["containers"]] == [
    "lifecycle-host"
]
for obj in storage + spool + run + recovery:
    key = (obj["apiVersion"], obj["kind"])
    assert key in KINDS, key
    jsonschema.Draft4Validator(
        {"$ref": "#/definitions/" + KINDS[key], "definitions": DEFINITIONS}
    ).validate(obj)

sc = next(obj for obj in storage if obj["kind"] == "StorageClass")
sa = next(obj for obj in storage if obj["kind"] == "ServiceAccount")
for obj in (sc, sa):
    assert obj["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep"
    assert not obj["metadata"].get("ownerReferences")
assert sa["automountServiceAccountToken"] is False
invalid_job = copy.deepcopy(next(obj for obj in run if obj["kind"] == "Job"))
invalid_job["spec"]["template"]["spec"]["restartPolicy"] = 123
try:
    jsonschema.Draft4Validator(
        {
            "$ref": "#/definitions/" + KINDS[("batch/v1", "Job")],
            "definitions": DEFINITIONS,
        }
    ).validate(invalid_job)
except jsonschema.ValidationError:
    pass
else:
    raise AssertionError("nested official API schema constraint was not enforced")
assert (sc["provisioner"], sc["reclaimPolicy"], sc["parameters"]) == (
    "ebs.csi.aws.com",
    "Retain",
    {"type": "gp3", "encrypted": "true"},
)
pvc = spool[0]
assert pvc["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep"
assert not pvc["metadata"].get("ownerReferences")
assert pvc["spec"]["accessModes"] == ["ReadWriteOncePod"]
job = next(obj for obj in run if obj["kind"] == "Job")
assert (
    job["spec"]["backoffLimit"] == 0 and job["spec"]["podReplacementPolicy"] == "Failed"
)
pod = job["spec"]["template"]
assert pod["spec"]["restartPolicy"] == "Never"
assert pod["spec"]["shareProcessNamespace"] is False
assert not any(
    obj["kind"] in ["PersistentVolumeClaim", "StorageClass", "ServiceAccount"]
    for obj in run
)
volumes = {v["name"]: v for v in pod["spec"]["volumes"]}
assert (
    volumes["retained"]["persistentVolumeClaim"]["claimName"] == VALUES["spool"]["name"]
)
assert "emptyDir" not in volumes["retained"]
for container in pod["spec"]["containers"]:
    mounts = {m["mountPath"]: m["name"] for m in container["volumeMounts"]}
    assert (
        mounts["/run/robotics"] == "retained" and mounts["/run/robotics/ipc"] == "ipc"
    )
    assert isinstance(container["command"], list) and isinstance(
        container["args"], list
    )
    assert container["securityContext"]["capabilities"]["drop"] == ["ALL"]
    assert container["securityContext"]["readOnlyRootFilesystem"]
    bindings = {e["name"]: e.get("value") for e in container["env"]}
    assert (
        bindings["EVIDENCE_PREFIX"] == "retained"
        and bindings["RCLONE_CONFIG_EVIDENCE_ENV_AUTH"] == "true"
    )
    assert bindings["RCLONE_S3_NO_CHECK_BUCKET"] == "true"
worker = next(c for c in pod["spec"]["containers"] if c["name"] == "native-worker")
assert not any(m["name"] == "api-token" for m in worker["volumeMounts"])
assert (
    worker["lifecycle"]["preStop"]["exec"]["command"]
    == VALUES["workers"][0]["terminationCommand"]
)
for obj in run:
    if obj["kind"] in ["Role", "ClusterRole"]:
        for rule in obj["rules"]:
            assert rule["verbs"] == ["get"] and "secrets" not in rule["resources"]
            assert "*" not in rule["resources"] and "*" not in rule["apiGroups"]

negatives = [
    {"host": {"image": "configuration-only:latest"}},
    {"host": {"command": "echo unsupported"}},
    {"mode": "physical-control"},
    {"spool": {"uid": ""}},
    {"binding": {"profileSha256": "incorrect"}},
    {"identity": {"namespace": "foreign"}},
    {"identity": {"prefix": "retained/"}},
    {"host": {"env": {"ROBOTICS_RUN_ID": "foreign"}}},
    {"mode": "export-recovery"},  # workers are prohibited in recovery
    {"workers": [{**VALUES["workers"][0], "name": "lifecycle-host"}]},
    {"workers": [{**VALUES["workers"][0], "terminationCommand": []}]},
    {"host": {"env": {"AWS_SECRET_ACCESS_KEY": "not-a-credential"}}},
]
for patch in negatives:
    values = copy.deepcopy(VALUES)
    for key, value in patch.items():
        if isinstance(value, dict):
            values[key].update(value)
        else:
            values[key] = value
    render("robotics-run", values, False)

spec = importlib.util.spec_from_file_location(
    "binding", ROOT / "verify-kubernetes-binding.py"
)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
expected = {
    "namespace": NAMESPACE,
    "pod": "pod-only",
    "pod_uid": "pod-uid-only",
    "job": VALUES["name"],
    "job_uid": "job-uid-only",
    "claim": VALUES["spool"]["name"],
    "claim_uid": VALUES["spool"]["uid"],
    "spool_release": VALUES["spool"]["release"],
    "storage_class": "retained-gp3",
    "bindings": {
        "run-id": BINDING["runId"],
        "domain-id": BINDING["domainId"],
        "profile-id": BINDING["profileId"],
        "profile-sha256": BINDING["profileSha256"],
    },
}
annotations = {guard.PREFIX + key: value for key, value in expected["bindings"].items()}
p = {
    "metadata": {
        "namespace": NAMESPACE,
        "name": expected["pod"],
        "uid": expected["pod_uid"],
        "annotations": annotations,
        "ownerReferences": [
            {
                "kind": "Job",
                "name": expected["job"],
                "uid": expected["job_uid"],
                "controller": True,
            }
        ],
    },
    "spec": {"volumes": [{"persistentVolumeClaim": {"claimName": expected["claim"]}}]},
}
j = {
    "metadata": {
        "namespace": NAMESPACE,
        "name": expected["job"],
        "uid": expected["job_uid"],
        "annotations": annotations,
    }
}
v = {
    "metadata": {
        "namespace": NAMESPACE,
        "name": expected["claim"],
        "uid": expected["claim_uid"],
        "annotations": {
            **annotations,
            "meta.helm.sh/release-name": expected["spool_release"],
            "meta.helm.sh/release-namespace": NAMESPACE,
        },
    },
    "status": {"phase": "Bound"},
    "spec": {"storageClassName": "retained-gp3", "accessModes": ["ReadWriteOncePod"]},
}
objects = [p, j, v, sc]
guard.validate(expected, *objects)
mutations = [
    (0, ("metadata", "uid"), "foreign"),
    (0, ("metadata", "ownerReferences"), []),
    (1, ("metadata", "uid"), "foreign"),
    (2, ("metadata", "uid"), "foreign"),
    (2, ("metadata", "namespace"), "foreign"),
    (2, ("metadata", "ownerReferences"), [{"kind": "Job", "uid": expected["job_uid"]}]),
    (2, ("metadata", "annotations", "robotics-runtime.dev/profile-sha256"), "foreign"),
    (2, ("metadata", "annotations", "meta.helm.sh/release-name"), "foreign"),
    (2, ("spec", "accessModes"), ["ReadWriteOnce"]),
    (2, ("status", "phase"), "Pending"),
    (3, ("reclaimPolicy",), "Delete"),
    (3, ("parameters", "encrypted"), "false"),
]
for index, keys, value in mutations:
    changed = copy.deepcopy(objects)
    target = changed[index]
    for key in keys[:-1]:
        target = target[key]
    target[keys[-1]] = value
    try:
        guard.validate(expected, *changed)
    except ValueError:
        continue
    raise AssertionError("foreign/unsafe identity fixture was accepted")
print(
    json.dumps(
        {
            "helm_lint": "passed",
            "official_api_schema_objects": len(storage + spool + run + recovery),
            "official_api_nested_negative": "passed",
            "export_recovery_render": "passed",
            "render_negatives": len(negatives),
            "identity_fixture_negatives": len(mutations),
            "cluster_operations": "none",
            "runtime_qualification": "not_performed",
        }
    )
)
