import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as pause } from 'node:timers/promises';
import { referenceFile } from '@robotics-runtime/host';
import { ComposeExecution, EngineMetadata } from '@robotics-runtime/infra-host';

const ulogPath = '/aas/github_apps/PX4-Autopilot/build/px4_sitl_default/rootfs/0/log';
const statusTopic = '/Drone1/fmu/out/vehicle_status_v1';
const globalPositionTopic = '/Drone1/fmu/out/vehicle_global_position';
const commandTopic = '/Drone1/fmu/in/vehicle_command';
const topics = [
  '/clock', statusTopic, '/Drone1/fmu/out/vehicle_local_position_v1',
  globalPositionTopic, '/Drone1/fmu/out/vehicle_command_ack',
  ...['takeoff', 'land'].flatMap(action => ['status', 'feedback'].map(kind => '/Drone1/' + action + '_action/_action/' + kind)),
];
const recorderIdentity = '/evidence/recorder-identity.json';
const recordingOptions = ['bag', 'record', '-s', 'mcap', '-o', '/evidence/flight', '--use-sim-time', '--include-hidden-topics'];
export const recorderArgs = [...recordingOptions, ...topics];
export const recorderBootstrap = `
import json, os, sys
from pathlib import Path

pid = os.getpid()
start_ticks = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
with Path(sys.argv[1]).open('x') as identity:
    json.dump({'pid': pid, 'start_ticks': start_ticks}, identity)
os.execvp('ros2', ['ros2', *sys.argv[2:]])
`;
export const settleRecorder = `
import json, os, select, signal, sys
from pathlib import Path

def settle(path, expected_argv):
    identity = json.loads(Path(path).read_text())
    pid = identity["pid"]
    if type(pid) is not int or pid <= 1 or not identity["start_ticks"].isdigit():
        raise ValueError("invalid recorder process identity")
    status = {**identity, "settlement": "already exited"}
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        return status
    try:
        poll = select.poll()
        poll.register(fd, select.POLLIN)
        try:
            ticks = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
            argv = [os.fsdecode(arg) for arg in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\\0") if arg]
        except FileNotFoundError:
            if poll.poll(0):
                return status
            raise
        if ticks != identity["start_ticks"]:
            raise RuntimeError("recorder PID was reused")
        if poll.poll(0):
            return status
        indexes = [i for i, arg in enumerate(argv) if Path(arg).name == "ros2"]
        if len(indexes) != 1 or argv[indexes[0]+1:] != expected_argv:
            raise RuntimeError("recorder argv differs from its launch")
        try:
            signal.pidfd_send_signal(fd, signal.SIGINT)
        except ProcessLookupError:
            return status
        if not poll.poll(10_000):
            raise TimeoutError("recorder process did not exit after SIGINT")
        return {**identity, "settlement": "exited after SIGINT"}
    finally:
        os.close(fd)

print(json.dumps(settle(sys.argv[1], sys.argv[2:])))
`;
export const verifyClosedCapture = `
import os, sys
from pathlib import Path

directory = Path(sys.argv[1])
metadata = directory / "metadata.yaml"
if not metadata.is_file() or metadata.stat().st_size == 0:
    raise ValueError("recorder metadata is missing or empty")
magic = b"\\x89MCAP0\\r\\n"
with (directory / "flight_0.mcap").open("rb") as data:
    if data.seek(0, os.SEEK_END) < 2 * len(magic):
        raise ValueError("MCAP is too short")
    data.seek(0)
    start = data.read(len(magic))
    data.seek(-len(magic), os.SEEK_END)
    if start != magic or data.read(len(magic)) != magic:
        raise ValueError("MCAP header or footer marker is missing")
`;
const ros = [
  'set -e', '. /opt/ros/jazzy/setup.bash', '. /aas/github_ws/install/setup.bash',
  '. /aas/aircraft_ws/install/setup.bash', 'export ROS_DOMAIN_ID=1 PYTHONUNBUFFERED=1',
  'export FASTRTPS_DEFAULT_PROFILES_FILE=/aas/aircraft_resources/comms/fastdds_no_air_radio.xml',
].join('\n') + '\n';
export const stableReadiness = `
class ReadyWindow:
    def __init__(self):
        self.start = self.last = None
        self.count = 0

    def observe(self, message):
        timestamp = message.timestamp
        if not (message.pre_flight_checks_pass and message.arming_state == 1 and not message.gcs_connection_lost):
            self.__init__()
            return None
        if self.last is None or not 0 < timestamp - self.last <= 1_500_000:
            self.start, self.count = timestamp, 0
        self.last, self.count = timestamp, self.count + 1
        if self.count >= 3 and timestamp - self.start >= 3_000_000:
            return {"first_us": self.start, "last_us": timestamp, "samples": self.count,
                    "disarmed": True, "preflight": True, "gcs_connected": True}
        return None

class WaypointWindow:
    def __init__(self, command, origin, geodesic):
        self.target = command["target"]
        self.marker = command["timestamp"]
        self.geodesic = geodesic
        if self.distance((origin["lat"], origin["lon"]), self.target[:2]) <= 2.0:
            raise ValueError("pre-request position was already inside the target radius")
        self.reset_segment()

    def distance(self, first, second):
        return self.geodesic.Inverse(*first, *second)["s12"]

    def reset_dwell(self):
        self.ticks = []
        self.samples = 0
        self.max_horizontal = self.max_vertical = 0.0

    def reset_segment(self):
        self.previous = None
        self.origin = None
        self.east_progress = None
        self.reset_dwell()

    def observe(self, message):
        import math

        stamp, sample = message.timestamp, message.timestamp_sample
        coordinates = (message.lat, message.lon)
        if (stamp <= self.marker or sample <= self.marker or not message.lat_lon_valid
                or not message.alt_valid or message.dead_reckoning
                or not all(math.isfinite(v) for v in (*coordinates, message.alt))):
            self.reset_segment()
            return None
        epoch = (message.lat_lon_reset_counter, message.alt_reset_counter)
        if self.previous:
            prior, prior_sample, prior_epoch = self.previous
            if not (0 < stamp - prior <= 500_000 and 0 < sample - prior_sample <= 500_000
                    and epoch == prior_epoch):
                self.reset_segment()
        self.previous = stamp, sample, epoch
        horizontal = self.distance(coordinates, self.target[:2])
        vertical = abs(message.alt - self.target[2])
        if self.origin is None:
            if horizontal > 2.0:
                self.origin = coordinates, horizontal
            return None
        if self.east_progress is None:
            point, prior_radius = self.origin
            moved = self.geodesic.Inverse(*point, *coordinates)
            east = moved["s12"] * math.sin(math.radians(moved["azi1"]))
            if east > 0.5 and horizontal < prior_radius:
                self.east_progress = east
        if self.east_progress is None or horizontal > 2.0 or vertical > 0.8:
            self.reset_dwell()
            return None

        tick = {"timestamp_us": stamp, "timestamp_sample_us": sample, "lat": message.lat,
                "lon": message.lon, "alt_m": message.alt}
        self.samples += 1
        self.max_horizontal = max(self.max_horizontal, horizontal)
        self.max_vertical = max(self.max_vertical, vertical)
        if not self.ticks:
            self.ticks.append(tick)
            return None
        previous = self.ticks[-1]
        if stamp - previous["timestamp_us"] < 500_000:
            return None
        if self.distance((previous["lat"], previous["lon"]), coordinates) >= 0.2:
            self.reset_dwell()
            self.samples, self.max_horizontal, self.max_vertical = 1, horizontal, vertical
        self.ticks.append(tick)
        if len(self.ticks) < 7:
            return None
        return {
            "target": self.target, "command_us": self.marker, "east_progress_m": self.east_progress,
            "sample_count": self.samples, "max_horizontal_error_m": self.max_horizontal,
            "max_vertical_error_m": self.max_vertical, "reset_counters": epoch, "ticks": self.ticks,
        }

def listen(message_type, topic, window):
    import rclpy
    from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy

    rclpy.init()
    node = rclpy.create_node("aas_px4_observation")
    qos = QoSProfile(depth=10, reliability=ReliabilityPolicy.BEST_EFFORT, durability=DurabilityPolicy.VOLATILE)
    result = None

    def observe(message):
        nonlocal result
        result = window.observe(message)

    subscription = node.create_subscription(message_type, topic, observe, qos)
    try:
        while result is None:
            rclpy.spin_once(node, timeout_sec=0.5)
        return result
    finally:
        node.destroy_subscription(subscription)
        node.destroy_node()
        rclpy.try_shutdown()

def main():
    import json, sys

    if len(sys.argv) == 1:
        from px4_msgs.msg import VehicleStatus
        result = listen(VehicleStatus, "/Drone1/fmu/out/vehicle_status_v1", ReadyWindow())
    else:
        from geographiclib.geodesic import Geodesic
        from px4_msgs.msg import VehicleGlobalPosition
        inputs = json.loads(sys.argv[1])
        result = listen(VehicleGlobalPosition, "/Drone1/fmu/out/vehicle_global_position",
                        WaypointWindow(inputs["command"], inputs["origin"], Geodesic.WGS84))
    print(json.dumps(result))

if __name__ == "__main__":
    main()
`;
const pane = 'sim:px4_sitl_1.0';
const digest = /^[a-f0-9]{64}$/;

function checked(result) {
  if (!result.ok) throw new Error(result.diagnostic ?? result.stderr);
  return result.stdout;
}

function empty(inventory) {
  return inventory.containers.length === 0 && inventory.networks.length === 0
    && (inventory.volumes.Volumes === null || inventory.volumes.Volumes.length === 0);
}

function field(text, name) {
  const value = text.match(new RegExp('^\\s*' + name + ':\\s*(\\S+)', 'mi'));
  if (!value) throw new Error('missing native field ' + name);
  return value[1].toLowerCase();
}

export class AasRun {
  constructor(ctx, input) {
    this.jobs = ctx.jobs;
    this.resources = ctx.runResources;
    this.input = input;
    const { compose, socket, composeFile, projectName, runId, output, images, subnetPrefix } = input;
    const env = { ROBOTICS_RUN_ID: runId, AAS_SIMULATION_IMAGE: images.simulation.reference,
      AAS_AIRCRAFT_IMAGE: images.aircraft.reference, AAS_SUBNET: subnetPrefix };
    this.options = { executable: compose, socketPath: socket, projectName, files: [composeFile],
      cwd: output, env, timeoutMs: 110_000, maxBufferBytes: 4_194_304 };
    this.compose = new ComposeExecution(this.jobs, this.options);
    this.owner = { runId, projectName };
    this.measurementRefs = [];
    this.recordingTopics = input.case === 'takeoff-reposition-land' ? [...topics, commandTopic] : topics;
    this.recorderArgs = [...recordingOptions, ...this.recordingTopics];
  }

  async command(args, signal) {
    return checked(await this.compose.run(args, signal));
  }

  async save(name, output, mode) {
    const path = join(this.input.output, name);
    await writeFile(path, output, { flag: 'wx', mode });
    return referenceFile(path);
  }

  async ownership(signal) {
    const simulator = this.namespaceParentId ?? (await this.command(['ps', '--all', '--quiet', 'simulation'], signal)).trim();
    const owner = { ...this.owner, ...(digest.test(simulator) ? { networkNamespaceContainerId: simulator } : {}) };
    const facts = await this.engine.projectOwnership(owner, { cancelSignal: signal });
    if (facts.status !== 'complete') throw new Error('Compose project ownership is incomplete');
    return facts;
  }

  async inspectActors(facts, signal) {
    const byRole = new Map(facts.containerDetails.map(value => [value.Config.Labels['com.docker.compose.service'], value]));
    if (facts.containerDetails.length !== 3 || byRole.size !== 3) throw new Error('expected the three admitted service actors');
    const requirements = [
      ['simulation', this.input.images.simulation, ulogPath, 'ulog'],
      ['aircraft', this.input.images.aircraft, '/evidence', 'recordings'],
      ['gcs', this.input.images.simulation],
    ];
    for (const [role, image, destination, volume] of requirements) {
      const actor = byRole.get(role);
      if (!actor || actor.Mounts.length !== Number(Boolean(volume))) throw new Error('unexpected mounts or missing role ' + role);
      const actual = await this.engine.inspect(actor.Id, {
        ...this.owner, imageDigest: image.reference, imageId: image.id, user: role === 'gcs' ? '1001:1002' : '0:0',
        mounts: volume ? [{ destination, volumeName: this.owner.projectName + '_' + volume, readOnly: false }] : [],
        hostConfig: { Privileged: role !== 'gcs' },
        ...(role === 'gcs' ? { networkNamespaceContainerId: byRole.get('simulation').Id } : {}),
      }, { cancelSignal: signal });
      if (actual.status !== 'complete' || actual.container.State.Running !== true) {
        const observed = { missing: actual.missing, mismatches: actual.mismatches, state: actual.container.State.Status,
          exit: actual.container.State.ExitCode };
        throw new Error('live identity differs for ' + role + ': ' + JSON.stringify(observed));
      }
    }
  }

  async ready(signal) {
    await this.compose.requireVersion(signal);
    await this.command(['config', '--quiet'], signal);
    this.engine = await EngineMetadata.connect({ socketPath: this.input.socket,
      operationMinApi: '1.24', operationMaxApi: '1.53' }, { cancelSignal: signal });
    const project = await this.engine.projectOwnership(this.owner, { cancelSignal: signal });
    if (project.status !== 'complete' || !empty(project.inventory)) throw new Error('Compose project ownership is incomplete or already in use');
    if (!empty(await this.engine.remainingOwned(this.owner.runId, { cancelSignal: signal }))) throw new Error('run identity is already in use');
    this.resources.track({ id: 'compose-project', ownerId: this.owner.runId,
      cleanup: async () => {
        await this.ownership();
        await this.command(['down', '--timeout', '5', '--volumes', '--remove-orphans']);
      },
      verifyCleanup: async cleanupSignal => {
        const facts = await this.ownership(cleanupSignal);
        const released = empty(facts.inventory) && empty(await this.engine.remainingOwned(this.owner.runId, { cancelSignal: cleanupSignal }));
        return { released, evidenceRefs: [await this.save('cleanup.json', JSON.stringify({ released, facts }, null, 2))] };
      },
    });
    await this.command(['up', '--detach', '--no-build', '--pull', 'never'], signal);
    const facts = await this.ownership(signal);
    await this.inspectActors(facts, signal);
    this.namespaceParentId = facts.containerDetails.find(actor => actor.Config.Labels['com.docker.compose.service'] === 'simulation').Id;
    const parent = await this.save('namespace-parent.json', JSON.stringify({
      attempt: this.input.attempt, id: this.namespaceParentId,
    }) + '\n', 0o400);
    const state = await this.aircraft(['python3', '-B', '-c', stableReadiness], signal, '45s');
    return { ready: true, evidenceRefs: [parent, await this.save('ready.txt', state)] };
  }

  async aircraft(args, signal, limit = '8s') {
    return this.command(['exec', '-T', 'aircraft', '/bin/bash', '-c',
      ros + 'exec /usr/bin/timeout -k 2s "$@"', 'ros', limit, ...args], signal);
  }

  async waitStatus(filter, limit, signal) {
    return this.aircraft(['ros2', 'topic', 'echo', '--once', '--filter', filter,
      '--qos-reliability', 'best_effort', '--qos-durability', 'volatile',
      statusTopic, 'px4_msgs/msg/VehicleStatus'], signal, limit);
  }

  async simulator(args, signal) {
    return this.command(['exec', '-T', 'simulation', ...args], signal);
  }

  async nativeState(name, signal) {
    const terminal = ['tmux'];
    const process = await this.simulator([...terminal, 'display-message', '-p', '-t', pane, '#{pane_current_command}'], signal);
    if (process.trim() !== 'px4') throw new Error('owned PX4 console is unavailable');
    for (const query of ['listener vehicle_status -n 1', 'listener vehicle_land_detected -n 1', 'listener vehicle_global_position -n 1']) {
      await this.simulator([...terminal, 'send-keys', '-t', pane, '-l', '--', query], signal);
      await this.simulator([...terminal, 'send-keys', '-t', pane, 'Enter'], signal);
      await pause(350, undefined, { signal });
    }
    const capture = await this.simulator([...terminal, 'capture-pane', '-p', '-J', '-S', '-', '-t', pane], signal);
    this.measurementRefs.push(await this.save(name + '.log', capture));
    const status = capture.split('TOPIC: vehicle_status').at(-1);
    return {
      armingState: Number(field(status, 'arming_state')),
      takeoffTime: Number(field(status, 'takeoff_time')),
      timestamp: Number(field(status, 'timestamp')),
      landed: field(capture.split('TOPIC: vehicle_land_detected').at(-1), 'landed') === 'true',
      altitude: Number(field(capture.split('TOPIC: vehicle_global_position').at(-1), 'alt')),
    };
  }

  async startRecorder(signal) {
    const recorder = new ComposeExecution(this.jobs, { ...this.options, timeoutMs: 250_000 });
    const script = ros + 'exec python3 -B -c "$@" >/evidence/recorder.log 2>&1';
    this.recorderClient = new AbortController();
    this.recording = recorder.run(['exec', '-T', 'aircraft', '/bin/bash', '-c', script, 'record',
      recorderBootstrap, recorderIdentity, ...this.recorderArgs], this.recorderClient.signal)
      .catch(error => ({ ok: false, diagnostic: String(error) }));
    this.recording.then(result => { this.recorderClientResult = result; });
    const deadline = performance.now() + 20_000;
    while (performance.now() < deadline) {
      signal.throwIfAborted();
      const result = await this.compose.run(['exec', '-T', 'aircraft', 'cat', '/evidence/recorder.log'], signal);
      const subscribed = new Set([...result.stdout.matchAll(/Subscribed to topic '([^']+)'/g)].map(match => match[1]));
      if (result.ok && this.recordingTopics.every(topic => subscribed.has(topic))) return;
      await pause(400, undefined, { signal });
    }
    throw new Error('recorder did not subscribe to all selected channels');
  }

  async goal(name, signal) {
    const type = name === 'takeoff' ? 'Takeoff' : 'Land';
    const altitude = name === 'takeoff' ? 'takeoff_altitude' : 'landing_altitude';
    const output = await this.aircraft(['ros2', 'action', 'send_goal', '--feedback', '/Drone1/' + name + '_action',
      'autopilot_interface_msgs/action/' + type, '{' + altitude + ': 10.0}'], signal, '85s');
    this.measurementRefs.push(await this.save(name + '.txt', output));
    if (/^Goal was rejected\.$/mi.test(output)) return false;
    const result = output.split('Result:').at(-1).split('Goal finished with status:')[0];
    if (!/Goal accepted with ID:\s*[a-f0-9]{32}/i.test(output) || !/^Goal finished with status:\s*SUCCEEDED$/mi.test(output)
      || !/^\s*success:\s*true\s*$/mi.test(result)) throw new Error(name + ' did not succeed');
    return true;
  }


  async waypoint(signal) {
    const initial = await this.aircraft(['ros2', 'topic', 'echo', '--once', '--filter',
      'm.lat_lon_valid and m.alt_valid and not m.dead_reckoning',
      '--qos-reliability', 'best_effort', '--qos-durability', 'volatile',
      globalPositionTopic, 'px4_msgs/msg/VehicleGlobalPosition'], signal);
    this.measurementRefs.push(await this.save('waypoint-before.txt', initial));
    const origin = Object.fromEntries(['lat', 'lon', 'alt', 'timestamp', 'timestamp_sample']
      .map(name => [name, Number(field(initial, name))]));
    if (!Object.values(origin).every(Number.isFinite) || !Number.isSafeInteger(origin.timestamp)
      || !Number.isSafeInteger(origin.timestamp_sample) || origin.timestamp <= 0 || origin.timestamp_sample <= 0)
      throw new Error('invalid pre-request PX4 position');

    const request = await this.aircraft(['ros2', 'service', 'call', '/Drone1/set_reposition',
      'autopilot_interface_msgs/srv/SetReposition', '{north: 0.0, east: 10.0, altitude: 10.0}'], signal, '12s');
    this.measurementRefs.push(await this.save('waypoint-service.txt', request));
    if (!/SetReposition_Response\(success=True(?:,|\))/.test(request)) throw new Error('SetReposition did not accept the waypoint');

    const filter = 'm.command == 192 and m.source_system == 255 and m.source_component == 0'
      + ' and m.target_system == 1 and m.target_component == 1 and m.timestamp > ' + origin.timestamp;
    const marker = await this.aircraft(['ros2', 'topic', 'echo', '--once', '--filter', filter,
      '--qos-reliability', 'best_effort', '--qos-durability', 'transient_local',
      commandTopic, 'px4_msgs/msg/VehicleCommand'], signal);
    this.measurementRefs.push(await this.save('waypoint-command.txt', marker));
    const command = { timestamp: Number(field(marker, 'timestamp')),
      target: ['param5', 'param6', 'param7'].map(name => Number(field(marker, name))) };
    if (!Number.isSafeInteger(command.timestamp) || command.timestamp <= origin.timestamp
      || !command.target.every(Number.isFinite) || Math.abs(command.target[0]) > 90 || Math.abs(command.target[1]) > 180)
      throw new Error('invalid waypoint command observation');

    const dwell = await this.aircraft(['python3', '-B', '-c', stableReadiness,
      JSON.stringify({ origin, command })], signal, '35s');
    this.measurementRefs.push(await this.save('waypoint-dwell.json', dwell));
  }

  async measure(signal) {
    const initial = await this.nativeState('initial', signal);
    if (initial.armingState !== 1 || !initial.landed) throw new Error('initial PX4 state must be landed and disarmed');
    await this.startRecorder(signal);
    const readiness = await this.aircraft(['python3', '-B', '-c', stableReadiness], signal, '25s');
    this.measurementRefs.push(await this.save('pre-takeoff-ready.json', readiness));
    let ascentError;
    let airborne;
    let needsLand = true;
    try {
      if (!await this.goal('takeoff', signal)) {
        needsLand = false;
        throw new Error('takeoff goal was rejected');
      }
      airborne = await this.nativeState('airborne', signal);
      if (airborne.armingState !== 2 || !(airborne.takeoffTime > 0) || airborne.landed || !(airborne.timestamp > initial.timestamp))
        throw new Error('fresh native airborne state is absent');
      const selector = "tmux list-panes -t drone:ap_interface -F '#{pane_id}' | while read -r pane; do tmux capture-pane -p -J -S - -t \"$pane\"; done";
      const home = await this.command(['exec', '-T', 'aircraft', '/bin/bash', '-ec', selector], signal);
      this.measurementRefs.push(await this.save('aircraft-action.log', home));
      const heights = new Set([...home.matchAll(/Saved home_lat_:\s*[0-9.+-]+, home_lon_:?\s*[0-9.+-]+, home_alt_:?\s*([0-9.+-]+)/g)].map(match => Number(match[1])));
      const [height] = heights;
      if (heights.size !== 1 || !(airborne.altitude - height > 9)) throw new Error('native altitude did not pass the stock 90% takeoff criterion');
      this.measurementRefs.push(await this.save('ascent.json', JSON.stringify({ homeAltitude: height, ...airborne })));
      if (this.input.case === 'takeoff-reposition-land') await this.waypoint(signal);
    } catch (error) {
      ascentError = error;
      this.measurementRefs.push(await this.save('ascent-error.txt', String(error)));
    } finally {
      if (needsLand && !signal.aborted && !await this.goal('land', signal)) throw new Error('land goal was rejected');
    }
    if (!needsLand) throw ascentError;
    signal.throwIfAborted();
    await this.waitStatus('m.arming_state == 1', '55s', signal);
    const landed = await this.nativeState('landed', signal);
    if (landed.armingState !== 1 || !landed.landed || !(landed.timestamp > (airborne ?? initial).timestamp)
      || (airborne && !(landed.altitude < airborne.altitude)))
      throw new Error('fresh native touchdown, descent and disarm are absent');
    if (ascentError) throw ascentError;
  }

  async drain(signal) {
    if (!this.recording) throw new Error('the recorder never started; the owned project is retained');
    const producer = JSON.parse(await this.command(['exec', '-T', 'aircraft', 'python3', '-B', '-c',
      settleRecorder, recorderIdentity, ...this.recorderArgs], signal));
    const native = await this.compose.run(['exec', '-T', 'simulation', 'tmux', 'display-message', '-p',
      '-t', pane, '#{pane_current_command}'], signal);
    if (native.ok && native.stdout.trim() === 'px4') await this.simulator(['tmux', 'send-keys', '-t', pane, 'C-c'], signal);
    const wait = 'for attempt in 1 2 3 4 5 6 7 8; do if pgrep -x px4 >/dev/null; then sleep 1; else test "$?" -eq 1; exit; fi; done; exit 1';
    await this.simulator(['/bin/sh', '-ec', wait], signal);
    if (!this.recorderClientResult && this.recorderClient && !this.recorderClient.signal.aborted)
      await Promise.race([this.recording, pause(1_000, undefined, { signal, ref: false })]);
    const detachedAfterClosure = Boolean(!this.recorderClientResult && this.recorderClient && !this.recorderClient.signal.aborted);
    if (detachedAfterClosure) this.recorderClient.abort();
    const { ok, exitCode, canceled, timedOut, code, diagnostic, signal: clientSignal } = await this.recording;
    this.drainRefs = [await this.save('recorder-settlement.json', JSON.stringify({
      producer, composeClient: { ok, exitCode, canceled, timedOut, code, diagnostic, signal: clientSignal, detachedAfterClosure },
    }, null, 2))];
    const bag = await this.aircraft(['ros2', 'bag', 'info', '/evidence/flight'], signal);
    if (!/^Storage id:\s*mcap\s*$/mi.test(bag)) throw new Error('closed MCAP metadata was not verified');
    await this.command(['exec', '-T', 'aircraft', 'python3', '-IB', '-c', verifyClosedCapture, '/evidence/flight'], signal);
    this.drained = true;
    this.drainRefs.push(await this.save('bag-info.txt', bag));
    const counts = new Map([...bag.matchAll(/Topic:\s*(\S+)\s*\|[^\n]*?Count:\s*(\d+)/g)].map(match => [match[1], Number(match[2])]));
    const errors = [];
    if (!ok && !detachedAfterClosure) errors.push('recorder Compose client did not complete');
    if (!this.recordingTopics.every(topic => counts.get(topic) > 0)) errors.push('selected MCAP channels are incomplete');
    if (errors.length) throw new Error(errors.join('\n'));
    return this.drainRefs.splice(0);
  }

  async exportPlan(signal) {
    if (!this.drained) throw new Error('producer closure is unverified; the owned project is retained');
    await this.ownership(signal);
    const logs = (await this.simulator(['find', ulogPath, '-mindepth', '2', '-maxdepth', '2', '-type', 'f', '-name', '*.ulg'], signal)).trim().split('\n');
    if (logs.length !== 1 || !logs[0].startsWith(ulogPath + '/') || !/\/\d{4}-\d{2}-\d{2}\/[\d_]+\.ulg$/.test(logs[0]))
      throw new Error('one closed PX4 ULog is required');
    const sources = [
      ['aircraft', '/evidence/flight/metadata.yaml', 'metadata.yaml'],
      ['aircraft', '/evidence/flight/flight_0.mcap', 'flight_0.mcap'],
      ['simulation', logs[0], 'px4.ulg'],
    ];
    const refs = [];
    for (const [role, source, name] of sources) {
      const wrapper = 'test -f "$1" && test ! -L "$1" && stat -c %s "$1" && sha256sum "$1"';
      const [length, checksum] = (await this.command(['exec', '-T', role, '/bin/bash', '-ec', wrapper, 'file', source], signal)).trim().split(/\s+/);
      const size = Number(length);
      if (!/^\d+$/.test(length) || !Number.isSafeInteger(size) || size <= 0 || size > 1024 ** 4 || !digest.test(checksum))
        throw new Error('closed file identity is missing');
      refs.push({ name, source: role + ':' + source, size_bytes: size, sha256: checksum });
    }
    const { executable, projectName, files, socketPath, env, cwd } = this.options;
    const script = 'compose=$1; project=$2; file=$3; shift 3; while [ "$#" -gt 0 ]; do "$compose" --project-name "$project" --file "$file" cp "$1" "$2"; shift 2; done';
    const exportRefs = refs.map(item => ({ uri: pathToFileURL(join(cwd, item.name)).href, size_bytes: item.size_bytes, sha256: item.sha256 }));
    return { refs, exportRefs, namespaceParentId: this.namespaceParentId, attempt: this.input.attempt, request: { executable: '/bin/sh',
      args: ['-ec', script, 'export', executable, projectName, files[0], ...refs.flatMap(ref => [ref.source, join(cwd, ref.name)])],
      cwd, env: { PATH: '/usr/local/bin:/usr/bin:/bin', ...env, DOCKER_HOST: 'unix://' + socketPath, DOCKER_CONFIG: '/nonexistent' },
      timeoutMs: 25_000, maxBufferBytes: 1_048_576, extendEnv: false } };
  }

  async exportEvidence(signal) {
    const plan = await this.exportPlan(signal);
    const path = join(this.input.output, 'closed-files.json');
    await writeFile(path, JSON.stringify(plan, null, 2) + '\n', { flag: 'wx', mode: 0o400 });
    const planRef = await referenceFile(path);
    checked(await this.jobs.run({ ...plan.request, cancelSignal: signal }));
    const copied = await Promise.all(plan.refs.map(item => referenceFile(join(this.input.output, item.name), { maxBytes: item.size_bytes })));
    for (const [index, ref] of copied.entries()) {
      const expected = plan.refs[index];
      if (ref.sha256 !== expected.sha256 || ref.size_bytes !== expected.size_bytes) throw new Error('copied evidence differs from closed bytes');
    }
    return [planRef, ...copied, ...(this.drainRefs ?? [])];
  }

  completion() {
    return {
      closeMeasurement: async () => [],
      captureLastState: async () => this.measurementRefs,
      drainRecorders: signal => this.drain(signal),
      exportEvidence: signal => this.exportEvidence(signal),
    };
  }
}

export default async function provider(ctx) {
  const input = ctx.get('aasInput');
  if (!input || input.runId !== ctx.runResources.ownerId) throw new Error('AAS inputs belong to another run');
  ctx.provide('aas', new AasRun(ctx, input));
}
provider.inject = ['aasInput', 'jobs', 'runResources'];
