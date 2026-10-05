# Keep Product Deployment Separate from Application Composition

- Status: accepted
- Date: 2026-10-05

## Context and Problem Statement

A workstation prototype needs the same document and developer interfaces as a
laboratory deployment or cloud run. Host-specific installation and local Engine
details must not become requirements of every product.

The deployment and lifecycle code already uses native libraries. Replacing it
because of file length, or adding a second policy or scheduler implementation,
does not establish lower ownership cost.

## Decision Outcome

Keep application composition, public contracts and evaluation in robotics-runtime.
Keep product images, execution providers and deployment in robotics-runtime-infra.
Consumer repositories own their models, control and vision behavior.

Use product-owned Ansible roles for declared VM and edge-node configuration.
Reuse the existing samplers, systemd units and configuration through standard
modules. The private home-infra project is outside this architecture: no role
imports, configuration dependencies or changes to its managed systems.

Keep Compose and Dockerode as the local execution provider. The cloud target
uses Terraform for AWS resources, Helm for workloads and the official Kubernetes
client for observed Job/Pod identities. Its implementation and AWS qualification
are separate deliverables; local Engine facts do not stand in for Kubernetes facts.

Cordis owns composition within an application process. A run owns its native
SDK clients and resources; frame and control payloads use native connections.
The initial cloud run has one lifecycle owner inside its admitted Job/Pod scope.
Do not introduce a custom scheduler, operator or distributed state service.

Retain public CLI/API/extras, original-byte admission, existing source/released
identity boundaries and export-before-cleanup behavior during migration.
Existing Bash, Compose, OPA and release helpers remain authoritative until their
replacement has passed the complete compatibility matrix.

## Consequences

Ansible installation, Terraform state and workload execution have different
owners and tests. Ansible check mode, rendered Helm or mocked AWS resources
cannot establish device behavior or actual cloud qualification.

Unexported results must survive execution cleanup. Cloud storage policy binds
attempt and resource UIDs, immutable object versions and retention lifetime.
A lost execution is not silently resumed or relabelled successful.

Measure setup, update and recovery effort plus cost per qualified workload.
Include failed attempts, idle capacity, storage and network cost. Source line
count, diagram output and completed checklist items are not TCO measurements.

[Component responsibilities](../component-responsibilities.md) records the
language, existing tool and validation boundary for each functional path.
