import assert from 'node:assert/strict';
import { setTimeout as pause } from 'node:timers/promises';

export const CASES = ['land', 'unarmed-refusal', 'application-deadline'];

// A cancellation request does not settle a mutating RPC before its native callback.
export function actionResponse(client, method, signal) {
  signal?.throwIfAborted();
  return new Promise((resolve, reject) => {
    let call;
    let settled = false;
    const stop = () => { call?.cancel(); };
    call = client[method]({}, { deadline: Date.now() + 10000 }, (error, response) => {
      settled = true;
      signal?.removeEventListener('abort', stop);
      if (error) reject(error);
      else if (signal?.aborted) reject(signal.reason);
      else resolve(response);
    });
    if (!settled) {
      signal?.addEventListener('abort', stop, { once: true });
      if (signal?.aborted) stop();
    }
  });
}

// Policy stays in this consumer. The SDK supplies unchanged generated clients.
export async function flightCase(io, name, {
  signal, now = () => performance.now(),
  sleep = (ms, cancel = signal) => pause(ms, undefined, { signal: cancel ?? undefined }),
  readinessMs = 45000, ascentMs = 20000, settlementMs = 45000, applicationMs = 2000,
} = {}) {
  assert(CASES.includes(name));
  const read = (type, cancel = signal) => io.read(type, cancel);
  const wait = async (type, predicate, ms, cancel = signal) => {
    const end = now() + ms;
    for (;;) {
      cancel?.throwIfAborted();
      const value = await read(type, cancel);
      if (now() >= end) throw new Error(type + ' observation deadline');
      if (predicate(value)) return value;
      await sleep(100, cancel);
    }
  };
  const success = async (method, cancel = signal) => {
    const value = await io.action(method, cancel);
    assert.equal(value.action_result?.result, 'RESULT_SUCCESS', method + ' rejected');
    return value;
  };
  const takeoffIfArmed = async () => {
    const armed = await read('armed');
    if (armed.is_armed === false) return { dispatched: false,
      refusal: { method: 'takeoff', boundary: 'caller-precondition', reason: 'unarmed' } };
    assert.equal(armed.is_armed, true, 'actual armed state required before takeoff');
    return { dispatched: true, response: await success('takeoff') };
  };
  assert.equal((await read('connection')).connection_state?.is_connected, true);
  assert.equal((await read('armed')).is_armed, false, 'start only on genuinely unarmed vehicle');
  assert.equal((await read('landed')).landed_state, 'LANDED_STATE_ON_GROUND');
  if (name === 'unarmed-refusal') {
    const baseline = (await read('position')).position?.relative_altitude_m;
    assert(Number.isFinite(baseline));
    try {
    const takeoff = await takeoffIfArmed();
    assert.equal(takeoff.dispatched, false, 'unarmed caller must not dispatch takeoff');
    for (let i = 0; i < 3; i++) {
      assert.equal((await read('armed')).is_armed, false);
      assert.equal((await read('landed')).landed_state, 'LANDED_STATE_ON_GROUND');
      const altitude = (await read('position')).position?.relative_altitude_m;
      assert(Number.isFinite(altitude) && Math.abs(altitude - baseline) <= 0.2,
        'refusal must have observed no ascent');
      await sleep(100);
    }
    return { case: name, observed: 'caller-refused-unarmed',
      refusal: takeoff.refusal };
    } catch (firstError) {
      // Unexpected state changes still require independent settlement on these owned actors.
      try {
        await success('land', null);
        await wait('landed', v => v.landed_state === 'LANDED_STATE_ON_GROUND', settlementMs, null);
        await wait('armed', v => v.is_armed === false, settlementMs, null);
      } catch (settlementError) {
        console.error('independent flight settlement failed:', settlementError);
      }
      throw firstError;
    }
  }
  await wait('health', value => {
    const h = value.health;
    return h?.is_armable && h.is_global_position_ok && h.is_home_position_ok && h.is_local_position_ok;
  }, readinessMs);
  let commandMayHaveArmed = false;
  let firstError;
  let effect;
  try {
    commandMayHaveArmed = true;
    await success('arm');
    await wait('armed', value => value.is_armed === true, readinessMs);
    const takeoff = await takeoffIfArmed();
    assert.equal(takeoff.dispatched, true, 'armed state lost before takeoff dispatch');
    effect = await wait('position', value =>
      Number.isFinite(value.position?.relative_altitude_m) && value.position.relative_altitude_m >= 1.2,
    ascentMs);
    assert.equal((await read('armed')).is_armed, true);
    if (name === 'application-deadline') {
      const end = now() + applicationMs;
      const deadline = AbortSignal.any([
        AbortSignal.timeout(applicationMs), ...(signal ? [signal] : []),
      ]);
      try {
        while (now() < end) {
          await read('position', deadline);
          await sleep(100, deadline);
        }
      } catch (error) {
        if (signal?.aborted || !deadline.aborted || deadline.reason?.name !== 'TimeoutError') throw error;
      }
    }
  } catch (error) {
    firstError = error;
  } finally {
    // Flight settlement, not SDK/context disposal or a native hang verdict.
    if (commandMayHaveArmed) {
      try {
        await success('land', null);
        await wait('landed', v => v.landed_state === 'LANDED_STATE_ON_GROUND', settlementMs, null);
        await wait('armed', v => v.is_armed === false, settlementMs, null);
      } catch (error) {
        if (firstError) console.error('independent flight settlement failed:', error);
        firstError ??= error;
      }
    }
  }
  if (firstError) throw firstError;
  return { case: name, observed: name === 'land' ? 'takeoff-then-grounded-disarmed' :
    'application-deadline-then-grounded-disarmed', ascent: effect };
}
