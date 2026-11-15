import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { AasRun, recorderArgs, recorderBootstrap, settleRecorder, stableReadiness, verifyClosedCapture } from './provider.mjs';

function scenario(caseName) {
  return new AasRun({ jobs: {}, runResources: {} }, {
    case: caseName,
    compose: '/usr/bin/true', socket: '/tmp/fixture.sock', composeFile: '/tmp/compose.yaml',
    output: '/tmp/example-output', projectName: 'rr-aas-fixture', runId: 'fixture',
    subnetPrefix: '10.43', images: { simulation: {}, aircraft: {} },
  });
}

test('a transient preflight bit and interrupted status stream do not admit a goal', () => {
  const check = [
    'import sys',
    'from types import SimpleNamespace',
    'scope = {"__name__": "test"}',
    'exec(sys.argv[1], scope)',
    'window = scope["ReadyWindow"]()',
    'def sample(t, ready=True, lost=False, state=1):',
    '    return window.observe(SimpleNamespace(timestamp=t, pre_flight_checks_pass=ready, gcs_connection_lost=lost, arming_state=state))',
    'for t in (4_676_000, 5_176_000, 5_676_000, 6_176_000, 6_676_000, 7_176_000):',
    '    assert sample(t) is None',
    'assert sample(7_676_000, ready=False) is None',
    'assert sample(8_176_000) is None',
    'assert sample(10_176_000) is None',
    'assert sample(10_676_000, lost=True) is None',
    'for t in (11_176_000, 11_676_000, 12_176_000, 12_676_000, 13_176_000, 13_676_000):',
    '    assert sample(t) is None',
    'assert sample(14_176_000)["samples"] == 7',
  ].join('\n');
  const result = spawnSync('python3', ['-B', '-c', check, stableReadiness], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
});

test('an explicit Jazzy rejection does not send a Land goal', async () => {
  const run = scenario();
  run.nativeState = async () => ({ armingState: 1, landed: true });
  run.startRecorder = async () => {};
  run.save = async () => ({});
  const invoked = [];
  run.aircraft = async args => {
    if (args[0] === 'python3') return '{}';
    invoked.push(args[4]);
    return 'Waiting for an action server to become available...\n\nGoal was rejected.\n';
  };
  await assert.rejects(run.measure(new AbortController().signal), /takeoff goal was rejected/);
  assert.deepEqual(invoked, ['/Drone1/takeoff_action']);
});

test('closed files remain exportable after an interrupted client and missing channels', async () => {
  const run = scenario();
  run.recording = Promise.resolve({ ok: false, canceled: true, exitCode: 143 });
  run.compose = { run: async () => ({ ok: true, stdout: 'px4' }) };
  run.command = async args => {
    if (args.includes(settleRecorder)) return '{"settlement":"exited after SIGINT"}';
    return args.includes('file') ? '6 ' + 'a'.repeat(64) : '';
  };
  run.aircraft = async () => 'Storage id: mcap\nTopic: /clock | Type: rosgraph_msgs/msg/Clock | Count: 39';
  const operations = [];
  run.simulator = async args => {
    operations.push(args[0]);
    return args[0] === 'find' ? args[1] + '/2026-11-15/03_54_00.ulg' : '';
  };
  run.ownership = async () => {};
  run.save = async (name, data) => ({ name, data });
  const signal = new AbortController().signal;
  await assert.rejects(run.drain(signal), /recorder Compose client did not complete\nselected MCAP channels are incomplete/);
  const plan = await run.exportPlan(signal);
  assert.deepEqual(operations, ['tmux', '/bin/sh', 'find']);
  assert.equal(plan.exportRefs.length, 3);
  assert.ok(plan.exportRefs.every(ref => ref.sha256 === 'a'.repeat(64) && ref.size_bytes === 6));
  assert.equal(JSON.parse(run.drainRefs[0].data).composeClient.exitCode, 143);
});

test('the recorder pidfd observes exit and refuses reused identity and other argv', { timeout: 15_000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'aas-recorder-control-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const fake = join(dir, 'ros2');
  const identityPath = join(dir, 'identity.json');
  await writeFile(fake, '#!/usr/bin/env python3\nimport signal, sys\nsignal.signal(signal.SIGINT, lambda *_: sys.exit(0))\nprint("ready", flush=True)\nsignal.pause()\n',
    { mode: 0o700 });
  const env = { ...process.env, PATH: dir + ':' + process.env.PATH };
  const child = spawn('python3', ['-B', '-c', recorderBootstrap, identityPath, ...recorderArgs], { env });
  t.after(() => { if (child.exitCode === null && child.signalCode === null) child.kill(); });
  const exit = once(child, 'exit');
  await Promise.race([once(child.stdout, 'data'), exit.then(([code]) => { throw new Error('fixture exited ' + code); })]);
  const identity = JSON.parse(await readFile(identityPath, 'utf8'));
  assert.equal(identity.pid, child.pid);
  const invoke = (args = recorderArgs) => spawnSync('python3', ['-B', '-c', settleRecorder, identityPath, ...args],
    { encoding: 'utf8', timeout: 12_000 });
  await writeFile(identityPath, JSON.stringify({ ...identity, start_ticks: String(Number(identity.start_ticks) + 1) }));
  const reused = invoke();
  assert.notEqual(reused.status, 0);
  assert.match(reused.stderr, /recorder PID was reused/);
  await writeFile(identityPath, JSON.stringify(identity));
  const wrongArgv = invoke([...recorderArgs, '/wrong']);
  assert.notEqual(wrongArgv.status, 0);
  assert.match(wrongArgv.stderr, /recorder argv differs/);
  const stopped = invoke();
  assert.equal(stopped.status, 0, stopped.stderr);
  assert.equal(JSON.parse(stopped.stdout).settlement, 'exited after SIGINT');
  assert.deepEqual(await exit, [0, null]);
  const absent = invoke();
  assert.equal(absent.status, 0, absent.stderr);
  assert.equal(JSON.parse(absent.stdout).settlement, 'already exited');
});

test('finalized MCAP markers and metadata are required before export', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'aas-capture-control-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const marker = Buffer.from([0x89, 0x4d, 0x43, 0x41, 0x50, 0x30, 0x0d, 0x0a]);
  const data = join(dir, 'flight_0.mcap');
  const metadata = join(dir, 'metadata.yaml');
  const verify = () => spawnSync('python3', ['-IB', '-c', verifyClosedCapture, dir], { encoding: 'utf8' });
  await writeFile(metadata, 'rosbag2_bagfile_information:\n');
  await writeFile(data, Buffer.concat([marker, Buffer.from([1, 2]), marker]));
  const closed = verify();
  assert.equal(closed.status, 0, closed.stderr);
  await writeFile(data, Buffer.concat([marker, Buffer.alloc(16)]));
  assert.match(verify().stderr, /footer marker is missing/);
  await writeFile(data, Buffer.concat([marker, marker]));
  await writeFile(metadata, '');
  assert.match(verify().stderr, /metadata is missing or empty/);
});

test('a healthy Compose client has time to settle after its recorder exits', async () => {
  const run = scenario();
  run.recorderClient = new AbortController();
  run.recording = new Promise(resolve => setTimeout(() => resolve({ ok: true, exitCode: 0 }), 25));
  run.recording.then(result => { run.recorderClientResult = result; });
  run.compose = { run: async () => ({ ok: true, stdout: 'px4' }) };
  run.command = async () => '{"settlement":"exited after SIGINT"}';
  run.simulator = async () => '';
  run.aircraft = async () => 'Storage id: mcap\n' + recorderArgs.slice(recorderArgs.indexOf('--include-hidden-topics') + 1)
    .map(topic => 'Topic: ' + topic + ' | Type: fixture | Count: 1').join('\n');
  run.save = async (name, data) => ({ name, data });
  const refs = await run.drain(new AbortController().signal);
  assert.equal(run.recorderClient.signal.aborted, false);
  assert.equal(JSON.parse(refs[0].data).composeClient.exitCode, 0);
});

test('only the explicit waypoint case adds the command channel', () => {
  assert.deepEqual(scenario().recorderArgs, recorderArgs);
  assert.deepEqual(scenario('takeoff-land').recorderArgs, recorderArgs);
  assert.deepEqual(scenario('takeoff-reposition-land').recorderArgs,
    [...recorderArgs, '/Drone1/fmu/in/vehicle_command']);
});

test('waypoint settlement requires observed progress and consecutive fresh position samples', () => {
  const check = [
    'import math,sys',
    'from types import SimpleNamespace',
    'scope = {"__name__": "test"}',
    'exec(sys.argv[1], scope)',
    'class FixtureGeodesic:',
    '    @staticmethod',
    '    def Inverse(a,b,c,d):',
    '        return {"s12": math.hypot(c-a,d-b), "azi1": math.degrees(math.atan2(d-b,c-a))}',
    'command = {"target":[0,0,10], "timestamp":1_000_000}',
    'def make():',
    '    return scope["WaypointWindow"](command, {"lat":0,"lon":-10}, FixtureGeodesic())',
    'def sample(window, time, east, valid=True, resets=0):',
    '    return window.observe(SimpleNamespace(timestamp=time, timestamp_sample=time, lat=0, lon=east, alt=10,',
    '        lat_lon_valid=valid, alt_valid=valid, dead_reckoning=False, lat_lon_reset_counter=resets, alt_reset_counter=resets))',
    'stationary = make()',
    'for i in range(10):',
    '    assert sample(stationary,1_250_000+i*500_000,0) is None',
    'stale = make()',
    'assert sample(stale,1_250_000,-4) is None',
    'assert sample(stale,1_500_000,0) is None',
    'assert sample(stale,1_500_000,0) is None',
    'for i in range(1,9):',
    '    assert sample(stale,1_500_000+i*500_000,0) is None',
    'reset = make()',
    'assert sample(reset,1_250_000,-4) is None',
    'for i in range(8):',
    '    assert sample(reset,1_500_000+i*500_000,0,resets=1) is None',
    'good = make()',
    'assert sample(good,1_250_000,-4) is None',
    'for i in range(6):',
    '    assert sample(good,1_500_000+i*500_000,0) is None',
    'result = sample(good,4_500_000,0)',
    'assert len(result["ticks"]) == 7 and result["sample_count"] == 7 and result["east_progress_m"] == 4',
    'assert result["ticks"][-1]["timestamp_us"]-result["ticks"][0]["timestamp_us"] == 3_000_000',
  ].join('\n');
  const result = spawnSync('python3', ['-B', '-c', check, stableReadiness], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
});
