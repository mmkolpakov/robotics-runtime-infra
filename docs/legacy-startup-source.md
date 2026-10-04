# Native legacy Gazebo/ROS startup source proof

This source candidate provides the retained neutral-robot profile through a native Cordis service. It does not replace the published acceptance runner or qualify a released R11 image. The existing runner and the failed released B3 baseline remain unchanged.

`@robotics-runtime/infra-host/plugins/gazebo-ros-v1` receives data from `LegacyInputs`, a service issued by the trusted bootstrap after the existing public Python admission helper selects and validates the robot-description artifact. The issued data is recursively frozen. Data documents are not native Loader profiles. The bootstrap creates a separate immutable root-array Include profile and supplies its pinned compiled-module closure to the public core Admission service.

The provider uses the public `Jobs` interface for every Compose invocation. Native check_urdf, ROS/Gazebo creation, GetEntities and clock operations run in the installed simulation workers. The Node host imports no ROS or Gazebo SDK. No timing controller, evaluator, signer or artifact serializer was reimplemented.

Startup order is application and declared observation services, native input checks, missing-file ACK/native-absence negative gate, fresh create ACK and same-process clean exit, native entity presence and canonical initialization, periodic clock owner, then observed Clock/JointState/TF readiness. The asset stays read-only after ownership begins. JointState is exactly slider_joint at zero; TF is base_link to slider_link at translation [0.2, 0, 0] and identity rotation. All readiness stamps must be strictly after the preceding native Clock cursor. Nanosecond values remain decimal strings across the host boundary. The unchanged native simulation_control stepper must still be running after readiness.

Metadata binds the exact source image ID, native user/mounts/resource fields and owner labels. A shared network namespace requires the actual acquired parent container ID, inspected owner labels and parent network facts. Native `none` is interpreted only after that chain is proved. Shared IPC is also checked against the exact simulation container ID. Unavailable network inspection remains incomplete. The source fixture includes the existing foundation UDP-only FastDDS XML and the existing conformance IPC settings before starting any process.

The source qualification uses native Admission and RunOwner. A bounded native Clock observation window begins only after backend readiness. Completion closes that window, stops the periodic writer without reset, pauses the native simulator and captures quiescent Clock/service state and GetEntities, retains diagnostics, disposes the native Fiber tree and verifies physical cleanup. No application recorder is acquired in this narrow fixture; its drain hook retains the actual role inventory. Application measurement, OTel/recording, public evaluation, packaging/signing and released B3 are separate open gates owned by the combined pipeline.

The final source run is `rr-c09-1791127143804`, under `artifacts/c09/startup-source-9`. All native lifecycle phases passed, the owner inventory was empty, and 104 emitted ArtifactRef entries were independently checked against actual file bytes and SHA256. Clock cursor was 18989000000 ns; Clock, exact JointState and TF samples were 19100000000 ns. Last native state was PAUSED (2), Clock 19151000000 ns, entity neutral_robot and native Result.RESULT_OK (1), with no reset. The source package uses the exact core asset from 55f135916ad508a01502812af62295fd09bbf227 and its checked npm integrity. The TypeScript predicate uses the official Cordis Fiber enum to require DISPOSED; it does not copy a state constant into the JavaScript caller.

The exact simulation image is sha256:59e092393a655e736b56c928acd51b921411fa4810cb030591e00138b2fc5ed4. This previously built source image is not the immutable released R10 image. The coordinator is sha256:1c227795630eb5d3a5069774031321f7aa48a47179af8345432bf1a0be6c7c60, with public contracts 0.18.2 and harness 0.19.1 observed through the Compose/Jobs route. Its build installs both hashlocked wheels and asserts their actual versions. The earlier coordinator 36507df2d5946710abaf28a3a948f0591f5b3ec1712dc9d81b65a9ba14c7c6aa inherited contracts 0.18.1; its earlier narrow proof is not labelled 0.18.2. The retained simulation base still has that earlier Python environment; it is used here for the native ROS SDK only, not public admission/evaluation.

Previous failed source runs remain retained. They exposed the worker argv/Compose option boundary, missing namespace-parent inspection, omitted foundation transport settings, the erased core enum export for JavaScript callers, Cordis inject access and the required measuring phase. None was changed into a pass. These source results do not close [the released B3 gate](qualification-baseline.md).

The readonly startup snapshot contains run/container IDs, ready/native metadata references, the owned Compose project and shared/input/evidence/results roots. Finalization can consume those facts after readiness without reconstructing ownership from declarations. `capture-last-state.py` reports native result_ok as a boolean based on imported Result.RESULT_OK; consumers must not assume that the native success code is zero. Pose capture is outside this narrow startup proof.

The compact retained summary is [legacy-startup-source.json](proofs/legacy-startup-source.json). The source command is:

```sh
node host/tools/qualify-gazebo-startup.mjs \
  /absolute/infra-root /absolute/owned-engine.sock /absolute/proof-output \
  sha256:59e092393a655e736b56c928acd51b921411fa4810cb030591e00138b2fc5ed4 \
  sha256:1c227795630eb5d3a5069774031321f7aa48a47179af8345432bf1a0be6c7c60
```

## Preparation before clock ownership

The trusted issued DTO may include fixed `preClockReadyJobs` finite Compose argv and `readyObservationServices`. Preparation runs after native asset/canonical initialization and before the periodic owner. Native entity and canonical facts are checked again after preparation. Late auxiliary services may start after the manifest exists; the actual acceptance observer starts in the combined measurement phase after full backend readiness. No established owner is stopped/restarted for conformance.

Source run rr-c09-1791132515543 used exact coordinator image 1c227795630eb5d3a5069774031321f7aa48a47179af8345432bf1a0be6c7c60 for ROS roles and public admission. Native five-step conformance passed before the periodic owner: paused15950000000→stepped15955000000 ns (exact5×1000000), then resumed15971000000 ns. Strict entity/Clock/JointState/TF reproof, native completion and actual empty cleanup all passed. Raw artifacts remain in artifacts/c09/startup-source-11. The image's embedded older foundation-lock revision is distinct from the observed installed public package versions18.2/19.1; this test does not claim the embedded source revision was upgraded.
