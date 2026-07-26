# Separate Source Builds from Release Locks

- Status: accepted
- Date: 2026-07-26

## Context and Problem Statement

Docker Compose services need build definitions for the local development loop,
while qualification and deployment must resolve immutable registry content.
Using a mutable registry tag as the default silently mixes those modes.

## Decision Drivers

- Preserve the standard Compose development workflow.
- Make released execution reproducible without a private wrapper CLI.
- Prevent an updated registry tag from changing a qualified run.

## Considered Options

- Keep mutable release tags in `compose.yaml`.
- Duplicate the full project into a production Compose file.
- Use local image defaults and an immutable Compose environment lock.

## Decision Outcome

Compose build definitions use `local/robotics-runtime-infra/*:dev` defaults.
`release.env` maps released services to `tag@sha256` references. Release
execution uses `docker compose --env-file release.env ... --no-build`.
BuildKit Bake remains the release-image build graph.

This follows Docker's separation of Compose development definitions from
production overrides and Bake-based release builds:
<https://docs.docker.com/guides/compose-bake/> and
<https://docs.docker.com/compose/how-tos/production/>.

## Consequences

- Source checkouts build explicitly before starting local images.
- A release workflow must publish a new lock after image digests are known.
- Qualification records include the resolved OCI digest, never only the tag.
