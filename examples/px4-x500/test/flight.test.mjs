import { test } from 'node:test';
import assert from 'node:assert/strict';
import { flightCase, actionResponse } from '../src/flight.mjs';

function fixture(options = {}) {
  let time = 0, armed = false, altitude = 0, phase = 'ground';
  const actions = [], reads = [], landSignals = [];
  const io = {
    async action(method, signal) {
      signal?.throwIfAborted();
      actions.push(method);
      if (method === 'arm') {
        armed = true;
        if (options.armError) throw new Error('original arm transport error');
      }
      if (method === 'takeoff') {
        if (!armed) return { action_result: { result: options.refusal ?? 'RESULT_COMMAND_DENIED' } };
        phase = 'flight'; altitude = options.noAscent ? 0 : 1.5;
        if (options.cancelAfterTakeoff) options.cancelAfterTakeoff.abort(new Error('operator cancel'));
      }
      if (method === 'land') {
        landSignals.push(signal);
        if (options.landError) throw new Error('later land error');
        phase = 'land'; armed = options.stillArmed ?? false; altitude = 0;
      }
      return { action_result: { result: 'RESULT_SUCCESS' } };
    },
    async read(type, signal) {
      signal?.throwIfAborted();
      reads.push(type);
      const value = {
        connection: { connection_state: { is_connected: options.disconnected ? false : true } },
        armed: { is_armed: armed },
        landed: { landed_state: phase === 'flight' || (phase === 'land' && options.notGrounded) ?
          'LANDED_STATE_IN_AIR' : 'LANDED_STATE_ON_GROUND' },
        position: { position: { relative_altitude_m: altitude } },
        health: { health: { is_armable: true, is_global_position_ok: true,
          is_home_position_ok: true, is_local_position_ok: true } },
      }[type];
      if (options.slowTelemetry) time += 100;
      return value;
    },
  };
  return { io, actions, reads, landSignals,
    config: { now: () => time, sleep: async ms => { time += ms; },
      readinessMs: 500, ascentMs: 500, settlementMs: 500, applicationMs: 200 } };
}

test('normal flight observes ascent then land/ground/disarm', async () => {
  const f = fixture();const result = await flightCase(f.io, 'land', f.config);
  assert.equal(result.observed, 'takeoff-then-grounded-disarmed');
  assert.deepEqual(f.actions, ['arm', 'takeoff', 'land']);
  assert.equal(f.reads.at(-1), 'armed');
});
test('unarmed denial is a vehicle response plus no-ascent observations', async () => {
  const f = fixture();const result = await flightCase(f.io, 'unarmed-refusal', f.config);
  assert.equal(result.observed, 'unarmed-command-denied');
  assert.deepEqual(f.actions, ['takeoff']);
  assert.equal(f.reads.filter(x => x === 'position').length, 4);
});
test('application deadline uses actual land settlement, not handle disposal', async () => {
  const f = fixture();const result = await flightCase(f.io, 'application-deadline', f.config);
  assert.equal(result.observed, 'application-deadline-then-grounded-disarmed');
  assert.deepEqual(f.actions, ['arm', 'takeoff', 'land']);
  assert.equal(f.landSignals[0], null);
});
test('command acknowledgement with absent ascent is not flight success', async () => {
  const f = fixture({ noAscent: true });
  await assert.rejects(flightCase(f.io, 'land', f.config), /position observation deadline/);
  assert.equal(f.actions.at(-1), 'land');
});
test('land acknowledgement without grounded state refuses', async () => {
  const f = fixture({ notGrounded: true });
  await assert.rejects(flightCase(f.io, 'land', f.config), /landed observation deadline/);
});
test('grounded but still armed refuses complete settlement', async () => {
  const f = fixture({ stillArmed: true });
  await assert.rejects(flightCase(f.io, 'land', f.config), /armed observation deadline/);
});
test('first command error survives later landing error', async () => {
  const f = fixture({ armError: true, landError: true });
  await assert.rejects(flightCase(f.io, 'land', f.config), /original arm transport error/);
  assert.deepEqual(f.actions, ['arm', 'land']);
});
test('operator cancellation still attempts independent land then retains cancellation', async () => {
  const abort = new AbortController();
  const f = fixture({ cancelAfterTakeoff: abort });
  await assert.rejects(flightCase(f.io, 'land', { ...f.config, signal: abort.signal }), /operator cancel/);
  assert.equal(f.actions.at(-1), 'land');
  assert.equal(f.landSignals[0], null);
});
test('transport timeout is not genuine unarmed command denial', async () => {
  const f = fixture({ refusal: 'RESULT_TIMEOUT' });
  await assert.rejects(flightCase(f.io, 'unarmed-refusal', f.config), /RESULT_TIMEOUT/);
  assert.equal(f.actions.at(-1), 'land');
});
test('discovery failure precedes all flight effects', async () => {
  const f = fixture({ disconnected: true });
  await assert.rejects(flightCase(f.io, 'land', f.config));
  assert.deepEqual(f.actions, []);
});
test('late good telemetry does not bypass an elapsed observation deadline', async () => {
  const f = fixture({ slowTelemetry: true });
  await assert.rejects(flightCase(f.io, 'land', { ...f.config, readinessMs: 50 }), /health observation deadline/);
  assert.deepEqual(f.actions, []);
});

test('application deadline interrupts a pending observation before independent landing', async () => {
  const f = fixture();
  const original = f.io.read;
  let positions = 0;
  f.io.read = async (kind, signal) => {
    if (kind === 'position' && ++positions === 2) {
      return new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => reject(signal.reason), { once: true });
      });
    }
    return original(kind, signal);
  };
  // Keep the test process alive; stock AbortSignal deadline timers are unref'ed.
  const keepAlive = new Promise(resolve => setTimeout(resolve, 80));
  const result = await flightCase(f.io, 'application-deadline', { ...f.config, applicationMs: 20 });
  await keepAlive;
  assert.equal(result.observed, 'application-deadline-then-grounded-disarmed');
  assert.deepEqual(f.actions, ['arm', 'takeoff', 'land']);
  assert.equal(f.landSignals[0], null);
});

test('cancel requests native cancellation but independent land waits for the unary callback', async () => {
  const abort = new AbortController();
  const requested = [];
  const nativeError = new Error('native canceled callback');
  let callback;
  let canceled = false;
  const client = {
    arm(_request, options, done) {
      assert(options.deadline > Date.now() && options.deadline <= Date.now() + 10000);
      requested.push('arm');
      callback = done;
      return { cancel() { canceled = true; } };
    },
    land(_request, _options, done) {
      requested.push('land');
      queueMicrotask(() => done(null, { action_result: { result: 'RESULT_SUCCESS' } }));
      return { cancel() {} };
    },
  };
  let settled = false;
  const original = actionResponse(client, 'arm', abort.signal);
  const ending = original.catch(async error => {
    assert.equal(error, nativeError);
    settled = true;
    await actionResponse(client, 'land', null);
  });
  abort.abort(new Error('original operator cancellation'));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(canceled, true);
  assert.equal(settled, false);
  assert.deepEqual(requested, ['arm']);
  callback(nativeError);
  await ending;
  assert.deepEqual(requested, ['arm', 'land']);
  assert.equal(abort.signal.reason.message, 'original operator cancellation');
});
