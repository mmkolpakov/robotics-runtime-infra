import { test } from 'node:test';
import assert from 'node:assert/strict';
import { externalCase, externalOperator, captureConsumerFailure, finishAfterConsumer } from '../../../host/tools/qualify-px4-stock.mjs';

test('default producer path and exactly three explicit controller cases', () => {
  assert.equal(externalCase([]), null);
  for (const name of ['land', 'unarmed-refusal', 'application-deadline']) {
    assert.equal(externalCase(['--external-case', name]), name);
  }
  for (const args of [['land'], ['--external-case', 'kill'], ['--external-case', 'land', '--extra']]) {
    assert.throws(() => externalCase(args));
  }
});
function facts(id, service, overrides = {}) {
  return { status: 'complete', container: { Id: id.repeat(64), Config: { Labels: {
    'org.robotics.runtime.run-id': 'issued-run',
    'com.docker.compose.project': 'rr-px4-' + 'c'.repeat(24),
    'com.docker.compose.service': service, ...overrides,
  } } } };
}
test('operator bootstrap takes real distinct IDs from complete admitted facts', () => {
  const config = { runVolume: 'issued-volume', grpcPort: 50113 };
  const result = externalOperator(config, facts('a', 'px4-native'), facts('b', 'mavsdk-native'),
    'issued-run', 'rr-px4-' + 'c'.repeat(24), '/usr/bin/podman');
  assert.equal(result.px4Id, 'a'.repeat(64));
  assert.equal(result.serverId, 'b'.repeat(64));
  assert.equal(result.runVolume, 'issued-volume');
  assert.equal(result.grpcPort, 50113);
});
test('incomplete/foreign/native-ID-alias facts refuse bootstrap', () => {
  const config = { runVolume: 'issued-volume', grpcPort: 50113 };
  const owner = 'issued-run', project = 'rr-px4-' + 'c'.repeat(24);
  const bad = facts('a', 'px4-native');bad.status = 'incomplete';
  assert.throws(() => externalOperator(config, bad, facts('b', 'mavsdk-native'), owner, project, '/usr/bin/podman'));
  assert.throws(() => externalOperator(config, facts('a', 'px4-native'),
    facts('b', 'mavsdk-native', { 'org.robotics.runtime.run-id': 'foreign' }), owner, project, '/usr/bin/podman'));
  assert.throws(() => externalOperator(config, facts('a', 'px4-native'), facts('a', 'mavsdk-native'), owner, project, '/usr/bin/podman'));
  assert.throws(() => externalOperator(config, facts('a', 'px4-native'), facts('b', 'mavsdk-native'), owner, project, 'podman'));
});
test('consumer failure still forwards exact owner hooks for native cleanup', async () => {
  const hooks = Object.freeze({ closeMeasurement() {}, captureLastState() {}, drainRecorders() {}, exportEvidence() {} });
  const first = new Error('original controller timeout');
  let received;
  const completion = { status: 'passed', scope: 'cleanup only' };
  await assert.rejects(finishAfterConsumer({ async finish(value) { received = value; return completion; } },
    hooks, first, () => {}), actual => actual === first);
  assert.equal(received, hooks);
});
test('original consumer error survives later owner cleanup or diagnostic failure', async () => {
  const first = new Error('original denied/no-ascent failure');
  const later = new Error('later producer cleanup error');
  let recorded;
  await assert.rejects(finishAfterConsumer({ async finish() { throw later; } }, {}, first,
    error => { recorded = error; throw new Error('diagnostic write failure'); }), error => error === first);
  assert.equal(recorded, later);
});
test('unrelated owner failure is not swallowed', async () => {
  const error = new Error('owner finish failed');
  await assert.rejects(finishAfterConsumer({ async finish() { throw error; } }, {}, null, () => {}),
    actual => actual === error);
});

test('unexpected dispatch rejection and refusal-write failure still finish once', async () => {
  const first = new Error('Jobs dispatch rejected');
  const hooks = Object.freeze({ closeMeasurement() {}, captureLastState() {}, drainRecorders() {}, exportEvidence() {} });
  const order = [];let finishes = 0;
  const error = await captureConsumerFailure(async () => { order.push('dispatch'); throw first; },
    async actual => { assert.equal(actual, first);order.push('retain-refusal');throw new Error('write failed'); });
  await assert.rejects(finishAfterConsumer({ async finish(actual) {
    finishes++;assert.equal(actual, hooks);order.push('finish');return { status: 'passed' };
  } }, hooks, error, () => {}), actual => actual === first);
  assert.equal(finishes, 1);
  assert.deepEqual(order, ['dispatch', 'retain-refusal', 'finish']);
});
test('completion retained before secondary refusal, original consumer error wins', async () => {
  const first = new Error('original controller refusal');
  const later = new Error('resource still active');
  const order = [];let recorded;
  await assert.rejects(finishAfterConsumer({ async finish() { return { status: 'failed' }; } }, {}, first,
    async error => { recorded = error;order.push('secondary'); },
    async completion => { order.push('retain-completion');assert.equal(completion.status, 'failed');throw later; }),
    actual => actual === first);
  assert.equal(recorded, later);
  assert.deepEqual(order, ['retain-completion', 'secondary']);
});
