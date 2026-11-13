# Source evidence worker

The source evidence worker extends an explicitly supplied finalizer image. It
packages the existing `evidence-sink`, `mcap-summary`, `retained-artifact` and
`receipt-inputs` programs for the source execution composition.

## Build inputs

Build [docker/evidence-source.Dockerfile](../docker/evidence-source.Dockerfile)
with `EVIDENCE_BASE_IMAGE` set to the immutable reference of the finalizer built
for the same source cohort; do not substitute an arbitrary simulation image or
infer compatibility from its tag.

The [foundation lock](../config/foundation-lock.json) selects the public
contracts and harness packages. The build checks their installed versions
against that lock and installs the hash-locked
[evidence dependencies](../docker/python/evidence-sink.lock). The Dockerfile
pins the rclone and AWS CLI image digests, the MCAP binary hash and license
checks, and verifies the Cosign version inherited from the finalizer. Consult
those inputs for the selected versions rather than a previous execution report.

For example, with the two image references supplied by the operator:

```bash
: "${EVIDENCE_BASE_IMAGE:?immutable finalizer image reference required}"
: "${EVIDENCE_WORKER_IMAGE:?output image reference required}"
docker buildx build --file docker/evidence-source.Dockerfile --load \
  --platform linux/amd64 \
  --build-arg "EVIDENCE_BASE_IMAGE=$EVIDENCE_BASE_IMAGE" \
  --tag "$EVIDENCE_WORKER_IMAGE" .
```

The [installed consumer runner](../scripts/ci/host/run-installed-legacy.sh)
builds this Dockerfile from its own immutable finalizer reference and records the
resulting image identity. The source worker currently builds for Linux/amd64.

## Execution and qualification

The image runs as its declared non-root evidence user. The caller supplies
owned evidence storage and checks the actual image, user, mounts, Engine
endpoint and resource ownership before launch. A Compose declaration or an
installed version report does not establish those runtime facts.

Retain the installed package inventory and original tool version output with
the run. Successful version probes establish tool availability; acceptance
requires the recording, observer, Collector, receipt, export, package/sign and
portable-verification flow on the selected composition. Exported bytes and
their references must remain verifiable after source cleanup. See
[evidence producers](evidence-producers.md) and
[qualification bundles](qualification.md).

## Published inputs

A source build is not a published or qualified worker release. Published OCI
execution uses the release's immutable `release.env` references through
[compose.released.yaml](../compose.released.yaml), with the scope recorded in
[compatibility](compatibility.md#package-and-release-generations). The released
profile does not supply an interchangeable source evidence worker image.

Use source-built finalizer and worker images for source qualification, and
the actual release inputs for released-profile qualification. Keep their
package, image and evidence identities separate; rebuilding from current
source cannot reproduce an older release claim by retaining its name.
