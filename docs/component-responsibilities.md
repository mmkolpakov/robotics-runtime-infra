# Component responsibilities

`robotics-runtime` owns document contracts, evaluation and local application
composition. `robotics-runtime-infra` owns worker environments, execution
providers and product deployment. Consumers own models, control and vision.

## Implemented paths

- **Documents and evidence — Python contracts/harness.** Reuse jsonschema,
  referencing, MCAP, native codecs and evaluator entry points. Preserve exact
  bytes, CLI/API/extras, JSON/JUnit and attach-only observation. Infra producers
  collect native facts; they do not implement another validator or evaluator.
- **Application lifecycle — TypeScript/Cordis.** Reuse Context, Service, Fiber,
  Loader and managed effects for immutable admission, owned bindings and export
  recovery. This is process-local composition, not a cloud scheduler.
- **Finite processes — TypeScript/Execa.** Use literal argv, explicit environment,
  deadlines, bounded output and native descendant termination. Workers run in
  their SDK environment without an added RPC intermediary.
- **Local deployment — Compose and Dockerode.** Compose resolves and launches
  services; Dockerode observes the selected Engine. Unix sockets, namespace
  mappings and host paths belong to this provider, not public document contracts.
- **Simulation and control — native SDK workers/generated clients.** ROS, Webots
  and Isaac use their upstream interfaces; MAVSDK uses official protobuf/gRPC.
  SDF, WBT/PROTO and USD assets remain provider-specific. Common lifecycle APIs
  do not translate physics, frames or flight-controller commands.
- **Media — GStreamer, rosbag2/MCAP and native telemetry.** Frames stay on the
  native pipeline. The host owns lifetime and references; recording drain,
  original capture identity and playback remain distinct evidence.
- **Policy and CLI glue — OPA, Compose, public SDK and Bash.** Reuse the existing
  resolver and admission policy. Consumer extensions must use the same registry
  and bytes across validation, observation, evaluation and retained packaging.
- **Retention — rclone, AWS CLI, Cosign and public byte writers.** Bind S3 VersionId,
  SHA-256 and size, and verify receipts. Materialize remote bytes in an isolated
  POSIX root for the harness. ETag or nonempty references do not prove integrity.
- **Build/release — uv, npm, native image builders and CI.** Python packages,
  host assets and provider images keep independent immutable identities.
  Consumers verify installed wheels, sdists, TGZs and images outside source trees.

[Qualification baseline](qualification-baseline.md) records accepted environments
and operations. Dependency installation or an upstream feature declaration does
not qualify the corresponding operation.

## Deployment design

Product Ansible uses builtin file, copy, template and systemd modules on explicitly
enrolled VM/edge nodes. It installs existing time/CAN assets with site-specific
hardware parameters. Workstation administration is outside this product.

Terraform owns AWS networking, EKS/EC2 capacity, IAM, ECR, storage and state.
Helm owns shared identity, retained per-run storage and finite attempt workloads.
The native execution design uses the official Kubernetes JavaScript client and
actual Job/Pod/PVC UIDs. Labels locate resources; exact ownership governs effects.
Cloud execution and recovery require their own implementation and runtime checks;
rendered manifests and mocked plans do not establish those capabilities.

See [deployment ownership](decisions/0009-product-deployment-boundaries.md).

## Compatibility and ownership cost

Refactoring preserves public behavior, budgets, error IDs and exit codes.
Consolidating byte capture must not add a mandatory bound where none existed.

Compare setup, update and recovery effort, CI/build time and compute/storage/network
cost for the same qualified workload. Include failed attempts and idle capacity.
Source line count and checklist completion do not measure ownership cost.
