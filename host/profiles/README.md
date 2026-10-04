# Profile admission boundary

The host's native Cordis profile is an immutable trusted YAML root array. It
loads public `@robotics-runtime/host/plugins/jobs` before an infra provider.
Admission verifies the full profile/module closure; runtime operator DTOs are
not forwarded to Loader/Include. This directory does not yet contain an
admitted production provider profile: C09 adds its actual startup stages.

A host's Compose project and lifetime differ from the acquired run's worker
project. Plugin import, required Fiber ACTIVE, binding, backend readiness,
time ownership and measurement admission remain separate gates. Compose `up`
or service discovery alone establishes none of the later gates. The Node
storage fixture is finite diagnostic code, not a synthetic ROS or simulator
provider.
