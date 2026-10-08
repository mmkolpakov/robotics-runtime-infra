# Native provider source qualification

The producers use the public qualification-profile, conformance-result, provider requirement and
evidence-index APIs. The infra-owned extension records native time representation and epoch,
frames and units, lifecycle facts, and separate operation request, result and effect references.
It is validated through the existing digest-pinned extension boundary.

The fixed Gazebo and Webots inputs contain accepted native CPU source observations. Projection
into conformance documents does not rerun physics. Gazebo records project cleanup; the selected
Webots proof records native process-group cleanup and evidence retained before reset. Their scopes
remain distinct. Native integer nanoseconds stay decimal strings; Webots binary64 seconds retain
their hexadecimal representation. Non-ROS providers do not imitate Clock, JointState or TF.

Isaac representative inputs produce skipped conformance, unevaluated execution and no capabilities.
They cannot satisfy a request for native execution. GPU, sensor, RTSP, GUI and installed-consumer
qualification require their own execution evidence.

Run `host/tools/qualify-provider-documents.mjs` with the source root, the selected Engine socket and
a new output directory. Public API checks cover missing providers and capabilities, source and
retained tamper, time and frame units, export-before-reset, extension binding and retained payloads
after original inputs are removed. Source proof hashes are recorded in
`docs/proofs/native-provider-source-qualification.json`.
