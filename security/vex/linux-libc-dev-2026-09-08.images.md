# Completed image scan comparison — 2026-09-08

All five available completed image-scan artifacts from [CI run
34192891669](https://github.com/mmkolpakov/robotics-runtime-infra/actions/runs/34192891669) were
downloaded and inspected. Each contains **129 HIGH/CRITICAL findings: 124 HIGH and five CRITICAL**,
all attributed to `linux-libc-dev=6.8.0-139.139`. This is 645 finding occurrences and 129 unique
CVEs. Every set matches the existing per-CVE review, with no unexpected IDs, missing IDs, severity
differences or reported fixed versions. All six CVEs fixed by the package update are absent from
every report.

| Completed job / scanned image | Architecture | Artifact ID | Actual HIGH / CRITICAL | Failed step |
| --- | --- | --- | --- | --- |
| [nvidia-image](https://github.com/mmkolpakov/robotics-runtime-infra/actions/runs/34192891669/job/101954401272) / inference-nvidia | amd64 | 10043065827 | 124 / 5 | Scan NVIDIA runtime images |
| [rknn-arm64-image](https://github.com/mmkolpakov/robotics-runtime-infra/actions/runs/34192891669/job/101954401531) / inference-rknn-rk3588 | arm64 | 10043036855 | 124 / 5 | Scan RK3588 runtime images |
| [portable-arm64](https://github.com/mmkolpakov/robotics-runtime-infra/actions/runs/34192891669/job/101954401828) / acceptance-observer | arm64 | 10043130320 | 124 / 5 | Build and scan every portable target for ARM64 |
| [amd-supply-chain](https://github.com/mmkolpakov/robotics-runtime-infra/actions/runs/34192891669/job/101954401563) / inference-amd | amd64 | 10043256261 | 124 / 5 | Scan AMD runtime images |
| [intel-image](https://github.com/mmkolpakov/robotics-runtime-infra/actions/runs/34192891669/job/101954401616) / inference-intel-cpu | amd64 | 10043356144 | 124 / 5 | Scan Intel runtime images |

The [machine-readable evidence](linux-libc-dev-2026-09-08.images.json) records each report's SHA256,
image ID, full residual CVE list, package PURL, job steps and selected numbered log lines. Raw
reports, SARIF, other uploaded payloads and job logs are retained in parent workspace
`analysis/ci-artifacts/infra-34192891669-completed-scans-01/`. NVIDIA was copied from the already
downloaded artifact; four additional artifacts were fetched. Integration had no uploaded scan
artifact at collection time; no claim is made about its later result. Successful static analysis,
reproducibility, Compose and supply-chain checks are not substitute image scans.

The actual removed IDs in all five reports are CVE-2026-53357, CVE-2026-64015, CVE-2026-64018,
CVE-2026-64032, CVE-2026-64073 and CVE-2026-64115. They receive no VEX statement.

AMD failed at the vulnerability gate. Its signed ROCm channel check, locked-wheel check and
runtime/conformance build all passed. Its report is valid and contains the same 129 header findings;
the job log records exit code 1 at the scan step. The observed failure does not require a network or
package-pin workaround. Intel's build, OpenVINO CPU execution check and sensor-path check also
passed before scanning failed.

There is a separate metadata discrepancy: AMD and RKNN images retain OCI `revision=local` and
`created=1970-01-01T00:00:00Z`. Those jobs omit the reproducible-build-metadata step. Their checkout
logs identify PR merge `5336df557bf1cefe81cd543ee2925b879180cb6c`, containing head
`a2f62d356507d2fe842e59447f50eef538d0e011`; artifact API records agree. Each scanned image ID
exactly matches its exported config digest in the build log. The default OCI labels are therefore
recorded as a metadata gap, not treated as valid source revision attestations. Fixing those job
labels is outside this VEX change.

Both ARM64 logs show snapshot `20260908T000000Z` InRelease retrieval, download of `.139`, and
successful `Setting up linux-libc-dev:arm64 (6.8.0-139.139)`. The shared snapshot helper at the
checked-out revision uses Ubuntu's `Signed-By` keyring and strict APT update errors; its source/hash
was captured with the original NVIDIA review. RKNN's build step passed. Portable ARM64's combined
step produced the acceptance-observer image and failed later at its scan gate; this does not
establish that every portable target built or scanned.

OpenVEX **v5** extends the same 129 reviewed statements from amd64 to the now-observed arm64 PURL.
It adds no CVE, retains the original 55 statements and both architectures' package-content evidence,
and leaves the scanner, HIGH/CRITICAL gate, ignore file and Docker/Bake pins unchanged. AMD and
Intel already match the amd64 scope from v4. Other versions, distributions, architectures and
packages remain outside these new statements. Bats checks the policy version and exact PURLs
together and binds the decisions to every captured residual set.

The artifacts contain one scanned image per job. Scanning stops at the first failing gate, so
subsequent images in those groups may reveal other findings after this change. A real Trivy/CI rerun
remains required. This package review does not qualify the host kernel, hardware, GPU drivers, full
image groups or complete CI run.

Validation: **5/5 security-scanning Bats tests passed** with mocked Docker, and the actual
policy/residual jq predicates rejected **12/12 unsafe mutations**. Checks include an unobserved
architecture, missing observed arm64 scope, another distribution, an unreviewed CVE and a previously
fixed CVE. All 184 CVE IDs and the original 55 statement objects match v4; the source-content review
remains intact. `git diff --check` passed, and Dockerfile, Bake, scanner, ignore file, severity
configuration and CI workflow are unchanged.
