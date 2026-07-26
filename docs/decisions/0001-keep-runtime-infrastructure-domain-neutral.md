# Keep Runtime Infrastructure Domain-Neutral

- Status: accepted
- Date: 2026-07-26

## Context and Problem Statement

Simulation, observation, evidence capture, and accelerator qualification are
needed by unrelated robotics products. Product scenes, robot descriptions,
models, and behavior change on a different cadence and have different owners.

## Decision Drivers

- Reuse one qualified runtime across products.
- Keep product acceptance rules out of privileged infrastructure.
- Permit product repositories to upgrade independently.

## Considered Options

- Store product code and infrastructure in one repository.
- Maintain one infrastructure fork per product.
- Publish a domain-neutral runtime consumed by product repositories.

## Decision Outcome

The repository owns execution images, Compose profiles, ROS middleware
configuration, host attachment boundaries, and evidence production. A
consuming repository owns scenes, robots, models, drivers, behavior, and
product acceptance scenarios. Integration occurs through immutable image
digests and versioned runtime contracts.

## Consequences

- A new product must provide an overlay and its own acceptance scenario.
- Product-specific dependencies cannot be added to the common runtime merely
  to simplify one consumer.
- A reusable capability may move into this repository only after its interface
  and neutral qualification test are defined.
