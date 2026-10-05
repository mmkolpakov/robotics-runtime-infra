# Component Responsibilities

This inventory records the existing implementation and planned deployment
boundaries. Planned infrastructure is not supported deployment evidence.

## Existing paths

- **Document contracts and byte validation — Python / contracts package.**
  Use jsonschema, referencing, MCAP and native streaming codecs. Keep domain
  rules and exact-byte writers in the public SDK; infra producers collect facts.
  Gate: published schema compatibility, CLI/API/extras and tampered input rejection.

- **Evidence evaluation — Python / acceptance harness.**
  Keep evaluator entry points, installed-package verification, JSON/JUnit and
  explicit skipped/incomplete live coverage. Observation remains attach-only.
  Gate: public command/exit semantics, evaluator receipts and offline evaluation.

- **Application composition — TypeScript / runtime host.**
  Use Cordis Context, Service, Fiber, Loader and managed effects. This is local
  application composition, not a cloud scheduler. Preserve immutable admission,
  backend readiness and retained recovery through the public lifecycle API.
  Gate: native loading, cancellation, export retry and observed cleanup.

- **Finite subprocesses — TypeScript / Execa Jobs.**
  Use closed argv/environment, deadlines, cancellation and descendant termination.
  Keep workers in their native SDK environment; do not add an RPC intermediary.
  Gate: output bounds, real exit/signal propagation and process cleanup.

- **Local deployment — TypeScript / infra Compose and Engine providers.**
  Compose owns resolution and process deployment; Dockerode observes the selected
  endpoint. Unix socket and host-path assumptions belong to this provider.
  Gate: actual required metadata, owner isolation and Docker/Podman execution.

- **Native simulators and control — native SDK workers and generated clients.**
  Python is used for ROS interfaces, Webots and Isaac Python APIs. MAVSDK uses
  official protobuf/gRPC. SDF, WBT/PROTO and USD assets remain provider-specific.
  Gate: native operations, time/frame units and exact environment/capability scope.
  Simulator support does not establish autopilot or product dynamics support.

- **Media and recording — native GStreamer, rosbag2/MCAP and telemetry tools.**
  Frames remain on the native media path; the host owns lifetime and references.
  Preserve recording drain, original capture identity and separate playback evidence.
  Gate: actual frames/stream decoding, Clock/EOF behavior and retained bytes.

- **Policy and compatibility planning — OPA/Compose/public SDK plus finite wrappers.**
  Bash remains appropriate for build and CLI glue. Reuse the current resolver and
  admission rules instead of writing a second merge, parser or evaluator.
  Gate: consumer extensions/extras, attach/playback and source/released equivalence.

- **Retention and signing — rclone, AWS CLI, Cosign and public byte writers.**
  Preserve exact S3 VersionId, SHA-256/size and verified receipts. Materialize
  selected remote bytes in an isolated POSIX root before calling the harness.
  Gate: export failure, retry isolation, immutable versions and offline re-verification.
  ETag and a nonempty reference list do not prove complete byte verification.

- **Build and release — uv/npm, native image builders and existing CI workflows.**
  Python packages, host assets and provider images have separate immutable identities.
  Preserve ordinary dependency installation and public reusable workflow contracts.
  Gate: wheel/sdist/TGZ/image consumer checks outside the producer source checkout.

## Product deployment work

- **Declared product VM/edge nodes — Ansible/YAML.**
  Install existing time/CAN assets with builtin file, copy, template and systemd
  modules. Hardware/time parameters are explicit site inputs. Do not target the
  shared development host by default or import private home-infra roles.
  Gate: syntax/lint, convergent application and actual permissions/service behavior.

- **AWS foundation — Terraform/HCL.**
  Own network, EKS/EC2 capacity, IAM, ECR, storage and Terraform state.
  Keep state separate from evidence. Plans and mocks precede actual AWS acceptance.
  Gate: state locking, convergence, IAM denial, real capacity and cost accounting.

- **Cluster workloads — Helm and the official Kubernetes JavaScript client.**
  Use native Job/Pod UIDs, workloads and observed state; retain the local provider.
  Attempt outputs and durable spool are separate from disposable IPC and Job cleanup.
  Gate: duplicate attempts, cancellation, Pod/node loss and verified recovery.
  Public contracts are shared; provider-specific deployment facts stay native.

## Compatibility and TCO

For each change, name the affected public path and its unchanged behavior.
Retain existing default budgets, error IDs and exit codes. Consolidated byte
capture must not impose a mandatory limit on an API that previously had none.

Compare the same qualified workload before and after a change. Record developer
setup/update/recovery effort, CI/build time and compute/storage/network cost.
The [deployment decision](decisions/0009-product-deployment-boundaries.md) defines
ownership; [qualification baseline](qualification-baseline.md) defines current
acceptance scope.
