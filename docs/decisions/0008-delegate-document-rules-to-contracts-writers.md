# Delegate Document Rules to Contracts Writers

- Status: accepted
- Date: 2026-10-02

## Context and Problem Statement

Runtime producers collect facts from ROS packages, host inputs and image identity.
Repeating schema defaults, validation or serialization in these producers gives
the same document two owners.

## Decision Outcome

Keep `emit-runtime-manifest` as a Bash/jq producer of observed facts. Pass its
template to the installed `robotics-contracts runtime-manifest init` command.
The public writer supplies the schema default, validates the document and writes
the project's deterministic JSON bytes atomically. The producer retains its
existing same-directory publication and read-only output mode.

Do not introduce a second builder or facts schema. jq remains appropriate for
assembling facts; it does not own the final document contract. Explicit unsupported
schema versions supplied to a writer continue to fail validation.

## Consequences

The producer omits the duplicated `schema_version` default. Existing producer
tests exercise the real installed CLI and require the same validated v1 fields,
preservation of previous output on failure, and removal of temporary files.
The declared zero clock relation in the simulation profile is not a measurement
of physical host clock synchronization; hardware timing uses its separate evidence.
