# Candidate Kubernetes packaging

These three standard Helm charts deliberately have separate release lifetimes:

- `robotics-storage-class`: long-lived product prerequisites, including the
  encrypted gp3 CSI StorageClass with Retain and the product service account.
  Its namespace/service account must match the Terraform Pod Identity association.
- `robotics-retained-spool`: one namespaced retained PVC per admitted run,
  ReadWriteOncePod, with exact run/domain/profile annotations. It has no Job
  ownerReference and a Helm keep policy.
- `robotics-run`: one finite attempt Job referencing an existing claim by its
  observed UID and separate spool release. Job TTL/uninstall owns no PVC or
  StorageClass. Attempt cleanup must not uninstall the spool release.

All charts default to disabled and require explicit enablement and values.
Rendered values and profile hashes are source admission inputs; they do not
establish a qualified runtime. Image references require digests, and commands/
args stay arrays. Stock Compose/EngineMetadata profiles remain local adapters;
they cannot be called Kubernetes-native because this chart mounts a PVC.

The lifecycle host and finite native workers share one Pod and absolute
`/run/robotics` retained storage. Only `/run/robotics/ipc` and `/tmp` use
ephemeral emptyDir volumes. Native SDK/control/data commands and ports remain
explicit separate worker configuration, with loopback endpoints inside the Pod.
The chart supplies no shell-eval launcher, scheduler, operator, cross-run state
service or new physics API.

The Job sets Never/zero backoff/one completion and delays replacement until the
old Pod is Failed. Kubernetes can still start a program twice. ReadWriteOncePod
and these settings do not prove exactly-once effects, fencing, sealed bytes or
recovery. The T10 provider must bind actual Job/Pod/PVC UIDs, enforce the existing
admitted lifecycle, and leave ambiguous/unsealed attempts incomplete. Export
recovery preserves the original measurement and accepts no native worker list.
Physical/control profiles are unsupported by this initial chart. Native workers
are regular Never containers with explicit termination argv. The lifecycle host
must perform normal SDK drain/stop and observe worker exit; its own exit alone
does not complete the Job. A preStop hook is best-effort cancellation, not drain
or export evidence. Shared process namespaces are disabled.

The preflight image runs a finite read-only kubectl query sequence. It checks
actual Pod/Job owner UID, namespace, retained PVC UID, profile/run/domain and
Helm spool ownership, then the bound claim's RWOP/Retain/encrypted gp3 CSI
configuration. Missing/foreign metadata fails before main containers start.
It creates no ledger or retained journal and does not prove that a former
writer has been fenced. The runtime provider remains responsible for those
separate guarantees.

RBAC grants only get: the named Job/PVC, Pods in the product namespace (their
generated names are unknown while rendering), and the named StorageClass.
No secrets, exec, writes, deletion or wildcard permissions are granted.
Only the preflight/lifecycle host mounts the projected API token; native workers
do not. AWS Pod Identity binds the whole Pod's service account; native workers
can receive the same AWS role. The API token mount does not isolate AWS credentials.
Each container runs without extra capabilities, escalation, hostPath or
host devices. Approved product images must contain their regular, immutable
profile closure; ConfigMap symlinks do not satisfy existing source admission.

Carry `terraform output evidence_environment` values into the existing sink
configuration: explicit region/bucket/prefix and rclone no-check-bucket. The
Job uses a prefix without a trailing slash and preserves the named remote,
VersionId/SHA-256/size/Cosign protocol and independent signing trust. Image,
entrypoint, namespace, claim UID and signer inputs require separate deployment
review; this chart does not fabricate them.

The retained StorageClass/PVC keep annotations are not a recovery certificate
or permission to delete bytes. Explicit retained-storage reclamation requires
verified exact-version export, complete recovery and owner-bound observation.
Manual administration can still remove data. Helm keep behavior, CSI encryption,
RWOP scheduling, UID reads, node/Pod loss, image admission, journal consistency,
drain/export/cancel and real cleanup require actual Kubernetes/EKS acceptance.

## Offline checks and tools

`scripts/ci/check-product-helm.sh` defaults to Docker for CI; for rootless Podman use
`ROBOTICS_IMAGE_ENGINE=podman scripts/ci/check-product-helm.sh`.
Only those engines are accepted. The project container uses pinned Ubuntu/uv/
certificate bootstrap images, official Helm 4.3.0 and kubectl 1.35.9 binaries
with verified SHA-256, and the official Kubernetes v1.34.0 OpenAPI snapshot.
The supported chart range is 1.34 through 1.36, matching this client skew.
Python validation dependencies are hash locked. Validation dependencies remain inside the project container.

Checks cover default-disabled charts, strict Helm lint/render, official API
schema validation, lifetime/mount/RBAC/argv constraints, invalid inputs and
foreign UID/ownership/storage fixtures. Fixture image/account/UID values are
configuration examples and are never deployed. The check container has no
network, cluster credentials, host socket or writable repository. Passing these
checks is not live profile, node, IAM, storage, physics or AWS qualification.

A separately published preflight image is built from the
`docker/product-kubernetes-tools.Dockerfile` `preflight` target. Its
published digest must be supplied; building the local checks does not publish
or install it. No Helm install/upgrade/uninstall, kubectl resource operation,
AWS API or deployment is performed by this check path.
