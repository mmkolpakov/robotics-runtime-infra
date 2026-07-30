# SORA 2.5 Technical Evidence Mapping

## Purpose and Limits

This document maps technical artifacts produced by three domain-neutral
packages to the Operational Safety Objectives (OSOs) in SORA 2.5. It is an
engineering index for assembling a safety case. It is not a compliance matrix,
an operational risk assessment, a declaration of conformity, a certification
claim, or evidence that any OSO has been met.

SORA assigns the applicant responsibility for identifying the OSOs applicable
to an operation. The required robustness depends on the operation's SAIL. When
an integrity or assurance level contains several criteria, all applicable
criteria must be met. Acceptance of standards, means of compliance, simulation
validity, organisational evidence, and the resulting safety case remains with
the applicant and the competent authority.

The mapping was reviewed on 2026-07-26 against:

- [JARUS SORA 2.5 package][jarus-package], version 2.5, JAR_doc_25 through
  JAR_doc_34, published 2024-05-13;
- [JARUS SORA 2.5 Main Body][jarus-main], JAR_doc_25, public release;
- [JARUS SORA 2.5 Annex E][jarus-annex-e], JAR_doc_28, public release;
- [EASA ED Decision 2025/018/R][easa-decision], dated 2025-09-29, which
  introduced the SORA 2.5 package into the AMC and GM to Regulation (EU)
  2019/947;
- [EASA Easy Access Rules for Unmanned Aircraft Systems][easa-ear], revision
  from 2026-06-30; and
- [EASA Annex E to AMC1 to Article 11][easa-annex-e], the consolidated
  integrity and assurance criteria for OSOs.

The JARUS material is the source methodology. For operations within the EASA
framework, the consolidated EASA rules and the competent authority's decisions
govern the application.

## Artifact Vocabulary

The package names below identify provenance and responsibility boundaries.
Schema validity proves only that a document has the required structure and
cross-document consistency; it does not prove that the recorded assertion is
true.

### `robotics-runtime-contracts`

- `acceptance-scenario.v4` records the intended execution, expected ROS graph,
  timing, evidence policy, safety boundary, and measurable assertions.
- `acceptance-run.v1` binds a run identifier, scenario digest, domains, and
  time authority.
- `runtime-manifest.v1` records observed software, workload, transport,
  accelerator, security, timing, and physical-target facts.
- `evidence-index.v2` and `mcap-summary.v1` bind retained evidence to media
  type, size, digest, channels, and message statistics.
- `acceptance-result.v4`, `acceptance-aggregate.v2`, and `causal-chain.v1`
  represent scoped verdicts, unevaluated coverage, and cross-domain causal
  observations.
- `execution-permit.v1` and `execution-verification.v1` bind a physical
  observation to reviewed identities, policy, target, image digest, validity
  interval, and nonce.
- `qualification-bundle.v1` and `qualification-policy.v1` define the signed
  qualification statement and the independently supplied trust policy.

### `robotics-acceptance-harness`

- `explain` validates and cross-checks an execution bundle before observation.
- `verify` observes declared ROS graph readiness, lifecycle states, forbidden
  interfaces, metrics, time evidence, and finalized evidence, then emits
  `acceptance-result.json` and `junit.xml`.
- `aggregate` verifies complete per-domain result coverage for one immutable
  run.
- `trace-evaluate` evaluates declared cross-domain channel observations and
  causal-chain trace evidence.

The harness is attach-only. It does not start or control the system, validate
an operations manual, qualify personnel, approve a design, or decide which
OSOs apply.

### `robotics-runtime-infra`

- Runtime manifests, health observations, ROS launch tests, simulator logs,
  MCAP recordings and summaries, OpenTelemetry metrics and traces, benchmarks,
  and provider-conformance reports record technical test observations.
- Finalized evidence indexes bind retained artifacts to their digests.
- SPDX SBOMs, BuildKit provenance, package manifests, image digests, and
  GitHub artifact attestations support software configuration identification
  and build traceability.
- Qualification statements and Sigstore bundles bind selected artifacts from
  one run to an independently supplied verification policy.
- Physical-attach preflight records and observation-only security checks
  support target identification and the absence of declared command
  interfaces during the observation window.

These artifacts describe a specific build and execution. They do not establish
airworthiness, environmental qualification, operational approval, staff
competence, or organisational capability.

## OSO-by-OSO Mapping

Each row identifies artifacts that may contribute technical evidence to an
applicant's substantiation. `None direct` means that the package may preserve
externally produced evidence by digest, but does not itself generate evidence
for the objective.

| OSO | Objective | Contracts artifacts that may contribute | Harness artifacts that may contribute | Infrastructure artifacts that may contribute | What these artifacts do not prove | Remaining owner |
| --- | --- | --- | --- | --- | --- | --- |
| 01 | Operator is competent or proven | Run identity, qualification bundle, evidence index | Repeatable JSON/JUnit results and aggregate history | Attested release and qualification records | Organisational competence, safety management, procedures, duties, audit, or operating certificate | Operator defines the organisation and ConOps; competent authority or designated entity performs required audit or verification |
| 02 | UAS designed and produced by a competent or proven entity | Runtime and qualification document structure | None direct | SBOM, provenance, package manifests, image digest, test and qualification records | Material suitability, production controls, physical configuration traceability, approved design or production organisation, or conformity of each UAS | Designer and producer maintain design and production records; applicant selects acceptable equipment; competent authority accepts or verifies the claimed basis |
| 03 | UAS maintained by a competent or proven entity | Evidence index can bind external maintenance records by digest | None direct | Software version, image, and test history for a specific execution | Maintenance instructions, physical maintenance status, authorised staff, release to service, training, maintenance programme, or maintenance log | Operator and maintenance organisation control instructions, staff authorisations, programme, releases, and logs |
| 04 | UAS developed to authority-recognised design standards | Qualification statement can identify the exact technical record set | Repeatable results can support a design-verification activity | Traceable tests, analyses, simulation records, SBOM, provenance, and immutable images | Applicability or recognition of a design standard, complete design assurance, DVR, type certificate, or restricted type certificate | Designer establishes compliance; applicant justifies applicability; competent authority recognises the standard or means of compliance |
| 05 | UAS design considers system safety and reliability | Scenario assertions, runtime manifest, result coverage, qualification bundle | Measured pass, fail, incomplete, lifecycle, timing, and causal-chain observations | Fault-oriented simulation records, MCAP, metrics, traces, logs, conformance reports, and build traceability | Complete functional hazard assessment, failure-condition classification, quantitative reliability, independence, development assurance, or representative coverage of the operational envelope | Designer performs safety assessment and assurance; applicant justifies test coverage and simulation validity; competent authority accepts the substantiation |
| 06 | C3 link characteristics are appropriate | Transport, timing, channel, metric, and evidence declarations | Attributed latency, age, loss, readiness, and causal observations when declared | Transport benchmarks, channel observations, MCAP statistics, time evidence, metrics, and traces | Operational RF environment, spectrum authorisation, interference resistance, coverage, required communication performance across the ConOps, or service continuity | Applicant defines requirements and operating environment; designer and service provider supply performance data; spectrum and aviation authorities grant required permissions |
| 07 | Product inspection confirms consistency with the ConOps | Runtime manifest, target identity, image digest, permit, and verification record | Cross-check of declared target, runtime, evidence, and validity interval | Physical preflight record, immutable software identity, health observations, and observation logs | Physical airframe condition, assembly, payload, calibration, damage, conformity with approved configuration, trained inspection staff, or completed inspection checklist | Operator performs and records inspection and training; designer supplies inspection instructions; competent authority validates procedures when required |
| 08 | Procedures address technical issues with the UAS | Scenario, expected graph, failure assertions, evidence policy, scoped result | Results from declared normal, contingency, and emergency procedure tests | Simulation, playback, logs, MCAP, metrics, traces, and test reports for the exercised cases | Complete operations manual, human-error treatment, procedure adherence in service, flight-envelope coverage, representativeness of simulation, or authority validation | Operator authors, trains, tests, controls, and follows procedures; applicant justifies the method and coverage; competent authority validates when required |
| 09 | Remote crew is trained, current, and able to control technical abnormal situations | Evidence index may bind external training and currency records by digest | None direct | A controlled simulation or playback environment may host exercises and retain their technical outputs | Identity of the trainee, competence, curriculum adequacy, practical assessment, recurrent training, currency, or authority verification | Operator defines and records competency-based training and currency; competent authority or designated entity validates or verifies when required |
| 10 | Safe recovery from a technical issue | Recovery assertions, timing limits, result scope, causal chain, evidence policy | Observed recovery state, timing, messages, lifecycle, and declared metrics | Fault-oriented simulation or HIL observations, MCAP, traces, metrics, and logs | Safety integrity of the recovery design, all relevant failures, flight-envelope coverage, physical representativeness, or acceptable residual risk | Designer substantiates recovery design; applicant selects failures and validates test representativeness; competent authority accepts the means and assurance |
| 11 | Procedures handle deterioration of external systems | Scenario conditions, expected graph, external channel observations, evidence policy | Observed response to declared loss, latency, readiness, timing, and causal conditions | Simulation or playback of service deterioration, metrics, traces, MCAP, and logs | Complete identification of external systems and failure modes, operational procedures, staff performance, provider obligations, or authority validation | Operator identifies dependencies and controls procedures; service providers define limitations; applicant validates coverage; competent authority accepts it |
| 12 | UAS design manages deterioration of external systems | Recovery assertions, runtime dependencies, channel contracts, qualification bundle | Observed design response and bounded recovery outcome | Fault-injection observations, timing evidence, MCAP, traces, metrics, and immutable build identity | Design independence, no-single-failure argument, complete failure analysis, software or airborne electronic hardware assurance, or type approval | Designer performs safety and design assurance; applicant demonstrates applicability to the ConOps; competent authority verifies the claimed integrity as required |
| 13 | External services are adequate for the operation | Runtime dependencies, channel observations, timing and evidence requirements | Measured service-facing readiness, latency, age, availability samples, and causal observations | Time-source evidence, transport benchmarks, service metrics, traces, MCAP, and retained logs | Contractual roles, provider competence, end-to-end service level over the operation, geographic coverage, contingency arrangements, or authority acceptance | Operator and provider define responsibilities and service performance; applicant demonstrates adequacy for the ConOps; competent authority validates when required |
| 14 | Procedures address human error | Scenario assertions and evidence policy can encode specific reviewed test cases | Results for observable actions and system responses in those cases | Simulation, playback, traces, metrics, MCAP, logs, and test reports | Human task analysis, procedure usability, crew resource management, adherence, workload, complete error coverage, or authority validation | Operator develops, validates, trains, and controls procedures; human-factors specialists assess them; competent authority validates when required |
| 15 | Remote crew is trained, current, and able to control human-error abnormal situations | Evidence index may bind external training and currency records by digest | None direct | A controlled simulation environment may host exercises and preserve technical outputs | Competence, training syllabus, trainee identity, recurrent training, currency, assessment outcome, or authority verification | Operator owns competency and currency records; competent authority or designated entity validates or verifies when required |
| 16 | Multi-crew coordination | Scenario may declare observable communication channels and timing assertions | Channel readiness, attributed timing, and causal observations for a defined exercise | Traces, metrics, MCAP, and logs from the exercised communication path | Task allocation quality, communication procedure completeness, crew resource management, staff competence, redundant devices, or real operational adherence | Operator defines roles, procedures, equipment, and training; applicant validates the exercise; competent authority accepts the assurance |
| 17 | Remote crew is fit to operate | Evidence index may bind external declarations or records by digest | None direct | None direct | Physical or mental fitness, fatigue risk, duty and rest compliance, medical fitness, or the validity of personal declarations | Operator manages fitness, duty, rest, and records; crew members make required declarations; medical and competent authorities perform their assigned oversight |
| 18 | Automatic flight-envelope protection addresses human error | Scenario limits, runtime identity, result and qualification bundle | Observed boundary response, timing, lifecycle, and causal outcome | Simulation or qualified hardware observations, MCAP, metrics, traces, and exact software image identity | Completeness of the protected envelope, all relevant pilot errors, independence, design assurance, physical performance, DVR, or type approval | Designer defines and substantiates protection; applicant validates operational applicability and coverage; competent authority verifies the required assurance |
| 19 | Safe recovery from human error | Recovery assertions, timing, evidence policy, scoped result | Observed error detection, response, recovery, and causal sequence | Human-in-the-loop or scripted simulation records, MCAP, traces, metrics, and logs | Complete human-error analysis, procedure quality, training, representative human behaviour, physical recovery performance, or authority validation | Operator and designer define complementary procedural and design mitigations; applicant validates coverage; competent authority accepts the assurance |
| 20 | Human-factors evaluation finds the HMI appropriate | Evidence index may bind an external evaluation report and source data by digest | Observable HMI-related ROS events can be evaluated only when explicitly declared | Time-aligned logs, traces, MCAP, and metrics may support an external evaluation | HMI usability, workload, fatigue, confusion risk, accessibility, representative user performance, or a completed human-factors evaluation | Operator and designer commission a qualified human-factors evaluation with representative users and tasks; competent authority accepts the method when required |
| 21 | Procedures address adverse operating conditions | Scenario may declare condition thresholds, responses, and required evidence | Observed threshold, response, timing, lifecycle, and result for exercised conditions | Simulation or playback inputs, sensor data, MCAP, metrics, traces, and logs | Complete environmental envelope, forecast and monitoring procedures, staff adherence, representative adverse conditions, flight coverage, or authority validation | Operator defines, validates, trains, and follows procedures; applicant justifies environmental models and coverage; competent authority validates when required |
| 22 | Remote crew is trained to identify and avoid critical environmental conditions | Evidence index may bind external training and assessment records by digest | None direct | Simulation or playback may host a training exercise and retain technical outputs | Curriculum adequacy, trainee identity, competence, recurrent training, practical assessment, or authority verification | Operator provides competency-based environmental training and records; competent authority or designated entity validates or verifies when required |
| 23 | Safe environmental conditions are defined, measurable, and adhered to | Scenario thresholds, runtime sensor identity, attributed metrics, time authority, and evidence policy | Evaluation of declared measurements, freshness, source attributes, timing, and threshold results | Sensor logs, MCAP, time evidence, metrics, traces, runtime manifest, and test reports | Correctness of operational limits, sensor calibration, meteorological source suitability, complete conditions, crew training, operational adherence beyond the observation, or authority acceptance | Designer states limitations; operator defines monitoring and procedures; applicant validates measurement sources and coverage; competent authority accepts the substantiation |
| 24 | UAS is designed and qualified for adverse environmental conditions | Qualification bundle may bind external qualification reports and exact tested configuration | Results may index declared environmental tests without judging the qualification basis | Exact software identity plus retained test data, logs, MCAP, metrics, traces, and attestations | Environmental qualification, physical test severity, test-laboratory competence, similarity argument, coverage of the ConOps, DO-160 compliance, DVR, or type approval | Designer conducts and controls environmental qualification; applicant demonstrates applicability to the ConOps; competent authority accepts the standard, evidence, and assurance |

## Use in a Safety Case

For each applicable OSO, the applicant should:

1. derive the required robustness from the approved SORA process and record the
   exact integrity and assurance criteria;
2. identify the claim being made, the responsible organisation, and the
   configuration and operational scope;
3. reference only artifacts whose scenario, runtime, target, time interval, and
   digests match that scope;
4. justify the representativeness of simulation, playback, HIL, or observation
   evidence for the intended operation;
5. record every criterion that remains unevaluated or depends on organisational,
   human, design, environmental, service-provider, or authority evidence; and
6. have the completed substantiation reviewed under the operator's safety
   management and the applicable competent-authority process.

An automated `passed` result is therefore a technical finding for the declared
scenario. It must not be translated into "OSO met" without the remaining
integrity and assurance criteria being addressed by the responsible parties.

[jarus-package]: https://jarus-rpas.org/publications/
[jarus-main]: https://jarus-rpas.org/wp-content/uploads/2024/06/SORA-v2.5-Main-Body-Release-JAR_doc_25.pdf
[jarus-annex-e]: https://jarus-rpas.org/wp-content/uploads/2024/06/SORA-v2.5-Annex-E-Release.JAR_doc_28pdf.pdf
[easa-decision]: https://www.easa.europa.eu/en/document-library/agency-decisions/ed-decision-2025018r
[easa-ear]: https://www.easa.europa.eu/en/document-library/easy-access-rules/online-publications/easy-access-rules-unmanned-aircraft-systems
[easa-annex-e]: https://www.easa.europa.eu/en/document-library/easy-access-rules/online-publications/easy-access-rules-unmanned-aircraft-systems?erules-id=ERULES-1963177438-15559
