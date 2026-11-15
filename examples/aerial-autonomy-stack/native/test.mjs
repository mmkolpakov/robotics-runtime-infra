import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { AasRun, stableReadiness } from './provider.mjs';

function scenario() {
  return new AasRun({ jobs: {}, runResources: {} }, {
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

test('missing channels report a failure while the closed files remain exportable', async () => {
  const run = scenario();
  run.recording = Promise.resolve({ ok: true, stdout: '' });
  run.command = async args => args.includes('file') ? '6 ' + 'a'.repeat(64) : '';
  run.aircraft = async () => 'Topic: /clock | Type: rosgraph_msgs/msg/Clock | Count: 39';
  run.simulator = async args => args[0] === 'find' ? args[1] + '/2026-11-15/03_54_00.ulg' : '';
  run.ownership = async () => {};
  run.save = async () => ({});
  const signal = new AbortController().signal;
  await assert.rejects(run.drain(signal), /selected MCAP channels are incomplete/);
  const plan = await run.exportPlan(signal);
  assert.equal(plan.exportRefs.length, 3);
  assert.ok(plan.exportRefs.every(ref => ref.sha256 === 'a'.repeat(64) && ref.size_bytes === 6));
});
