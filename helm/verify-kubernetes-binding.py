"""Finite, read-only Kubernetes identity preflight. This is not effect fencing."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

PREFIX = "robotics-runtime.dev/"
BINDINGS = {
    "run-id": "ROBOTICS_RUN_ID",
    "domain-id": "ROBOTICS_DOMAIN_ID",
    "profile-id": "ROBOTICS_PROFILE_ID",
    "profile-sha256": "ROBOTICS_PROFILE_SHA256",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(expected, pod, job, claim, storage):
    namespace = expected["namespace"]
    for obj in (pod, job, claim):
        require(obj["metadata"]["namespace"] == namespace, "foreign namespace")
    require(pod["metadata"]["uid"] == expected["pod_uid"], "foreign Pod UID")
    require(job["metadata"]["uid"] == expected["job_uid"], "foreign Job UID")
    require(
        claim["metadata"]["uid"] == expected["claim_uid"], "foreign retained PVC UID"
    )
    require(pod["metadata"]["name"] == expected["pod"], "foreign Pod name")
    require(job["metadata"]["name"] == expected["job"], "foreign Job name")
    require(claim["metadata"]["name"] == expected["claim"], "foreign PVC name")
    owners = pod["metadata"].get("ownerReferences", [])
    require(
        any(
            o.get("kind") == "Job"
            and o.get("name") == expected["job"]
            and o.get("uid") == expected["job_uid"]
            and o.get("controller") is True
            for o in owners
        ),
        "Pod is not owned by the observed Job",
    )
    require(
        not claim["metadata"].get("ownerReferences"),
        "retained PVC has a garbage-collection owner",
    )
    for obj in (pod, job, claim):
        annotations = obj["metadata"].get("annotations", {})
        for key, value in expected["bindings"].items():
            require(
                annotations.get(PREFIX + key) == value,
                "foreign run/domain/profile binding",
            )
    annotations = claim["metadata"].get("annotations", {})
    require(
        annotations.get("meta.helm.sh/release-name") == expected["spool_release"],
        "foreign spool release",
    )
    require(
        annotations.get("meta.helm.sh/release-namespace") == namespace,
        "foreign spool release namespace",
    )
    require(claim["status"]["phase"] == "Bound", "PVC is not bound")
    require(
        claim["spec"]["storageClassName"] == expected["storage_class"],
        "foreign storage class",
    )
    require(
        claim["spec"]["accessModes"] == ["ReadWriteOncePod"],
        "PVC is not single-Pod CSI storage",
    )
    require(
        storage["metadata"]["name"] == expected["storage_class"],
        "foreign storage-class name",
    )
    require(storage["provisioner"] == "ebs.csi.aws.com", "unsupported CSI provisioner")
    require(storage["reclaimPolicy"] == "Retain", "backing bytes may be reclaimed")
    require(
        storage["volumeBindingMode"] == "WaitForFirstConsumer",
        "unsupported volume binding",
    )
    require(
        storage["parameters"].get("type") == "gp3"
        and storage["parameters"].get("encrypted") == "true",
        "unencrypted or unsupported EBS profile",
    )
    claims = [
        v.get("persistentVolumeClaim", {}).get("claimName")
        for v in pod["spec"].get("volumes", [])
    ]
    require(expected["claim"] in claims, "Pod does not mount the bound retained claim")
    return {
        "job_uid": expected["job_uid"],
        "pod_uid": expected["pod_uid"],
        "claim_uid": expected["claim_uid"],
        "identity_preflight": "passed",
    }


def main():
    parser = argparse.ArgumentParser()
    for argument in ("job", "claim", "spool-release", "storage-class"):
        parser.add_argument("--" + argument, required=True)
    args = parser.parse_args()
    expected = {
        "namespace": os.environ["ROBOTICS_K8S_NAMESPACE"],
        "pod": os.environ["ROBOTICS_K8S_POD_NAME"],
        "pod_uid": os.environ["ROBOTICS_K8S_POD_UID"],
        "job_uid": os.environ["ROBOTICS_K8S_JOB_UID"],
        "claim_uid": os.environ["ROBOTICS_K8S_PVC_UID"],
        "job": args.job,
        "claim": args.claim,
        "spool_release": args.spool_release,
        "storage_class": args.storage_class,
        "bindings": {key: os.environ[variable] for key, variable in BINDINGS.items()},
    }
    require(
        all(expected[k] for k in ("pod_uid", "job_uid", "claim_uid")),
        "missing actual UID",
    )
    secrets = Path("/var/run/secrets/kubernetes.io/serviceaccount")
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    if ":" in host:
        host = "[" + host + "]"
    server = "https://" + host + ":" + os.environ["KUBERNETES_SERVICE_PORT"]
    config = {
        "apiVersion": "v1",
        "kind": "Config",
        "clusters": [
            {
                "name": "cluster",
                "cluster": {
                    "server": server,
                    "certificate-authority": str(secrets / "ca.crt"),
                },
            }
        ],
        "users": [{"name": "pod", "user": {"tokenFile": str(secrets / "token")}}],
        "contexts": [{"name": "pod", "context": {"cluster": "cluster", "user": "pod"}}],
        "current-context": "pod",
    }
    with tempfile.TemporaryDirectory(prefix="kubernetes-binding-") as directory:
        path = Path(directory) / "config.json"
        path.write_text(json.dumps(config))
        path.chmod(0o600)

        def read(kind, name, namespace=None):
            command = [
                "kubectl",
                "--kubeconfig",
                str(path),
                "--request-timeout=10s",
                "get",
                kind,
                name,
                "-o",
                "json",
            ]
            if namespace is not None:
                command += ["--namespace", namespace]
            result = subprocess.run(
                command, capture_output=True, timeout=15, check=True
            )
            require(
                len(result.stdout) <= 1048576,
                "metadata response exceeds the finite limit",
            )
            return json.loads(result.stdout)

        objects = [
            read("pod", expected["pod"], expected["namespace"]),
            read("job", args.job, expected["namespace"]),
            read("pvc", args.claim, expected["namespace"]),
            read("storageclass", args.storage_class),
        ]
        print(json.dumps(validate(expected, *objects)))


if __name__ == "__main__":
    main()
