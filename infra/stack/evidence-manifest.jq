{
  schema_version: "0.1",
  run_id: $run_id,
  profile_id: "core_simulation",
  created_at: $created_at,
  result: "pass",
  runtime: {
    os: "ubuntu_24_04",
    container_runtime: "docker",
    image: $image,
    image_digest: (if $image_digest == "" then null else $image_digest end),
    source_ref: (if $source_ref == "" then null else $source_ref end)
  },
  checks: [
    {
      id: "compose_smoke",
      result: "pass",
      duration_s: null,
      log: "artifacts/reports/compose-smoke.txt"
    },
    {
      id: "sensor_smoke",
      result: "pass",
      duration_s: null,
      log: "artifacts/reports/compose-sensor-smoke.txt"
    },
    {
      id: "integration_smoke",
      result: "pass",
      duration_s: null,
      log: "artifacts/reports/integration-smoke.txt"
    },
    {
      id: "autopilot_smoke",
      result: "pass",
      duration_s: null,
      log: "artifacts/reports/compose-autopilot-smoke.txt"
    },
    {
      id: "security_scan",
      result: $sarif_result,
      duration_s: null,
      log: "artifacts/security/trivy-image.sarif"
    },
    {
      id: "security_gate",
      result: "pass",
      duration_s: null,
      log: "artifacts/security/trivy-gate.txt"
    }
  ],
  metrics: {},
  artifacts: [
    {
      kind: "log",
      path: "artifacts/reports/compose-smoke.txt",
      media_type: "text/plain",
      required: true
    },
    {
      kind: "log",
      path: "artifacts/reports/compose-sensor-smoke.txt",
      media_type: "text/plain",
      required: true
    },
    {
      kind: "log",
      path: "artifacts/reports/integration-smoke.txt",
      media_type: "text/plain",
      required: true
    },
    {
      kind: "docker_metadata",
      path: "artifacts/reports/docker-image-inspect.json",
      media_type: "application/json",
      required: true
    },
    {
      kind: "security_report",
      path: "artifacts/security/trivy-image.sarif",
      media_type: "application/sarif+json",
      required: false
    },
    {
      kind: "security_gate",
      path: "artifacts/security/trivy-gate.txt",
      media_type: "text/plain",
      required: true
    }
  ]
}
