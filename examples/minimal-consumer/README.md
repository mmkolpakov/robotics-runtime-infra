# Minimal Runtime Consumer

This Compose model demonstrates the supported inclusion boundary without
copying runtime services into a product repository.

```bash
docker compose -f examples/minimal-consumer/compose.yaml \
  up --detach --wait simulation
docker compose -f examples/minimal-consumer/compose.yaml \
  -f compose.simulation-conformance.yaml \
  --profile simulation-conformance run --rm simulation-conformance
docker compose -f examples/minimal-consumer/compose.yaml \
  down --volumes --remove-orphans
```

A product repository adds one local Compose file after these includes. It owns
worlds, robot descriptions, model adapters, drivers, and behavior. Pin released
images through `release.env`; do not copy this repository's service definitions.
