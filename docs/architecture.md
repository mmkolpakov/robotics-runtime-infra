# Architecture

This repository implements execution environments and simulator providers for
[the runtime architecture](https://github.com/mmkolpakov/robotics-runtime/blob/main/docs/architecture.md).
The common Python packages validate documents and evaluate evidence; the Cordis
host manages composition and owned resources. Product repositories supply
application-specific behavior and assets.

## Execution and native APIs

A provider is a Cordis plugin plus its bounded native worker, environment and
qualification profile. Compose/Execa owns worker execution. Engine metadata is
read from the same actual endpoint; missing required facts are not filled from
Compose declarations.

Gazebo, Webots and Isaac remain separate native paths:

- ROS Gazebo uses Jazzy/Harmonic and upstream `simulation_interfaces`.
  ROS-free PX4/Gazebo uses native Gz Transport/WorldControl and MAVSDK.
- Webots uses `webots-controller`, a finite `Robot/Supervisor` controller and
  native camera capture. No common ROS dependency or unverified PX4 bridge is
  introduced.
- Isaac uses its official runtime, native application/physics/rendering APIs
  and RTSP writer. The provider retains GPU/runtime/asset identities and
  separate license requirements.

Control and media clients consume the selected native SDK or endpoint directly.
The host does not carry frame payloads, replace the autopilot or translate scenes.
SDF, WBT/PROTO and USD fixtures are checked separately.

## Readiness and capability scope

A loaded plugin, a healthy process, a discovered service and a completed operation
are different facts. Backend startup must establish its native world/device,
required observations and time ownership. A published `GetSimulatorFeatures`
response does not prove that one request advances one physics tick.

Capabilities are accepted for an exact version and environment. A native camera
buffer is not an RTSP endpoint. General simulator integration is not drone
dynamics or autopilot qualification.

Retained ROS v1 requirements such as Clock/JointState/TF remain in their own
profile. Non-ROS providers use native observations and the generic document/
evaluation boundary; they do not generate a fictitious ROS graph.

## Resource and evidence lifecycle

```mermaid
flowchart TB
    admission["Admit versions / assets / capability profile"]
    readiness["Start / observe backend and clock ownership"]
    measurement["Run native workload / collect observations"]
    capture["Close window / snapshot last state / drain recorder"]
    export["Export exact payloads and references"]
    dispose["Reset / dispose only acquired resources"]
    cleanup["Observe process / container / stream outcome"]
    verdict["Evaluate / sign package / independent verify"]

    admission --> readiness --> measurement --> capture --> export --> dispose --> cleanup --> verdict
```

Export precedes destructive reset or disposal. Plugin disposal does not reverse
commands or erase retained evidence. Cleanup errors and incomplete runtime facts
cannot produce a successful qualification; diagnostics remain available.

Inputs are read-only and distinct from writable results. Host and workers have
observed UID/group mappings. Docker and rootless Podman use deployment settings
appropriate to their actual Engine/socket; they do not require changing host
network or remote-access settings.

## Environments and releases

The common host and portable workers are checked on Docker CI and the declared
rootless Podman profile. Isaac's initial renderer/media profile requires a
supported native NVIDIA environment; CUDA discovery alone is not renderer
qualification. Offscreen frames and their visual review are separate from
physics-only success. A stream does not qualify a desktop GUI.

Own provider/bootstrap code and fixtures can be released independently of a
vendor runtime. NVIDIA runtime/assets are consumed through their official
distribution and are not silently republished in this repository's registry.

Source and released runs are independent gates. An immutable Python pair, host
asset and infra lock retain separate source identities; release qualification
installs the published artifacts without rebuilding them from source.

The provider line is under development. The retained released profile keeps its
current [compatibility scope](compatibility.md); the open neutral-robot
time/readiness failure remains open until a new complete run passes.
