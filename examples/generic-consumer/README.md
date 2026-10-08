# Generic caller service

This caller declares a stepped UInt64 scenario, an offline extension schema and
an opaque binary artifact. Its Compose service observes the original input bytes
and four public routing fields, becomes healthy, and waits for normal termination.

Use the existing reusable qualification workflow with an exact tooling commit.
Set these caller inputs:

```yaml
scenario: examples/generic-consumer/scenario.yaml
compose_project: examples/generic-consumer/compose.yaml
services: caller-probe
settle_services: caller-probe
artifact_arguments_file: examples/generic-consumer/artifact-arguments.txt
```

The artifact argument file registers the exact schema bytes by URI and binds the
opaque input as `other_evidence`. The installed contracts validator checks its
digest and payload constraints; the installed observer and aggregate receive the
same registry. No extension code or evaluator is loaded.

The optional `settle_services` list must be a unique subset of admitted caller
services. After measurement and aggregation, the runner verifies every selected
container's project, service and image identity before stopping its exact ID.
It retains public routing fields, native state, bounded logs and wait statuses
as qualification evidence. Other caller services keep the normal cleanup order.

The probe logs the input SHA-256 and size, and only `ROS_DOMAIN_ID`,
`RMW_IMPLEMENTATION`, `ROBOTICS_RUN_ID` and `ROBOTICS_DOMAIN_ID`. Do not place
secrets in these public fields or service logs. A failed native stop, wait,
inspection or nonzero process exit refuses settlement. The default empty list
adds no settlement operation.

Source mode builds the pinned foundation images. Released mode requires a
separately selected canonical release tag and its verified lock; it does not
build caller images. The probe reuses the selected observer image. This example
does not add robot hardware support, extension execution or a new acceptance
verdict.
