import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, lstat } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { createHash } from 'node:crypto';
import { Context, Jobs, Mavsdk, isDisposed } from '@robotics-runtime/host';
import { admitActors, inspectionArguments } from './admission.mjs';
import { readOperatorInput } from './operator-input.mjs';
import { flightCase, actionResponse, CASES } from './flight.mjs';

const [name, configPath, output] = process.argv.slice(2);
assert(CASES.includes(name) && isAbsolute(configPath ?? '') && isAbsolute(output ?? ''),
  'usage: node src/run.mjs CASE ABSOLUTE_OPERATOR_JSON NEW_ABSOLUTE_OUTPUT');
const config = await readOperatorInput(configPath);
assert.equal(config.curlExecutable, '/usr/bin/curl', 'fixed stock curl executable required');
assert(isAbsolute(config.engineSocket ?? ''));
const socket = await lstat(config.engineSocket);
assert(socket.isSocket() && !socket.isSymbolicLink(), 'actual selected Unix Engine socket required');
const pins = JSON.parse(await readFile(new URL('../input-pins.json', import.meta.url), 'utf8'));
await mkdir(output, { recursive: false, mode: 0o700 });
const ctx = new Context();
const jobsFiber = ctx.plugin(Jobs, { timeoutMs: 10000, maxBufferBytes: 1048576 });
await jobsFiber.await();
let sdkFiber;
let sequence = 0;
let outcome;
let firstError;
const cancel = new AbortController();
const requestCancel = () => cancel.abort(new Error('operator requested flight settlement'));
process.on('SIGINT', requestCancel);
process.on('SIGTERM', requestCancel);
const retain = async (kind, value) => {
  await writeFile(join(output, String(sequence++).padStart(4, '0') + '-' + kind + '.json'),
    JSON.stringify(value, null, 2) + '\n', { flag: 'wx' });
};
const native = async (kind, id) => {
  const args = inspectionArguments(config, kind, id);
  const result = await ctx.jobs.run({
    executable: config.curlExecutable, args, extendEnv: false,
    env: { PATH: '/usr/bin:/bin' },
  });
  const { stdout, ...status } = result;
  await retain('native-job', { kind, id, status });
  assert.equal(result.ok, true, 'selected Engine admission read failed');
  const value = JSON.parse(stdout);
  // Retain only safe identity/shape facts before validation; never Env/unknown command or label values.
  const entry = value.Config?.Entrypoint;
  const expected = id === config.px4Id ? '/opt/px4/build/px4_sitl_default/bin/px4' :
    id === config.serverId ? '/opt/robotics/mavsdk_server' : null;
  await retain('native-inspection-shape', { kind, id,
    raw_sha256: createHash('sha256').update(stdout).digest('hex'),
    entrypoint_kind: Array.isArray(entry) ? 'array' : typeof entry,
    entrypoint_count: Array.isArray(entry) ? entry.length : null,
    expected_entrypoint_matches: expected ? JSON.stringify(entry) === JSON.stringify([expected]) : null,
    running: typeof value.State?.Running === 'boolean' ? value.State.Running : null,
    owner_matches: value.Config?.Labels?.['org.robotics.runtime.run-id'] === config.ownerId,
    project_matches: (value.Config?.Labels ?? value.Labels)?.['com.docker.compose.project'] === config.project,
    network_members: kind === 'network' ? Object.keys(value.Containers ?? {}).filter(v => /^[a-f0-9]{64}$/.test(v)) : null });
  return value;
};
try {
  await retain('incomplete', { case: name, scope: 'external simulated flight controller only' });
  assert.match(config.px4Id, /^[a-f0-9]{64}$/);
  assert.match(config.serverId, /^[a-f0-9]{64}$/);
  assert.match(config.runVolume, /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/);
  assert.match(config.project, /^rr-px4-[a-f0-9]{24}$/);
  const px4 = await native('container', config.px4Id);
  const server = await native('container', config.serverId);
  const image = await native('image', pins.worker_image_id);
  const volume = await native('volume', config.runVolume);
  const network = await native('network', config.project + '_default');
  const endpoint = admitActors(config, px4, server, image, pins, volume, network);
  await retain('admitted-actors', { ownerId: config.ownerId, project: config.project,
    actors: [px4, server].map(v => ({ Id: v.Id, Image: v.Image, State: v.State,
      RestartCount: v.RestartCount, User: v.Config.User, Labels: v.Config.Labels,
      NetworkMode: v.HostConfig.NetworkMode })),
    image: { Id: image.Id, RepoDigests: image.RepoDigests },
    runVolume: volume.Name, network: { Id: network.Id, Name: network.Name }, endpoint });
  cancel.signal.throwIfAborted();
  sdkFiber = ctx.plugin(Mavsdk, { endpoint, deadlineMs: 5000 });
  await sdkFiber.await();
  const sdk = ctx.mavsdk;
  const streams = { armed: 'subscribeArmed', landed: 'subscribeLandedState',
    position: 'subscribePosition', health: 'subscribeHealth' };
  const io = {
    async read(kind, signal) {
      const value = kind === 'connection' ? await sdk.observeConnectionState(signal) :
        await sdk.first(sdk.clients.telemetry[streams[kind]]({}, { deadline: Date.now() + 5000 }), signal);
      await retain('telemetry-' + kind, { monotonic_ms: performance.now(), value });
      return value;
    },
    async action(method, signal) {
      signal?.throwIfAborted();
      // Preserve an issued command before its possibly late/native response.
      let writeError;
      try { await retain('action-issued', { method, monotonic_ms: performance.now() }); }
      catch (error) { if (method !== 'land') throw error; writeError = error; }
      let value;
      try {
        value = await actionResponse(sdk.clients.action, method, signal);
      } catch (error) {
        await retain('action-error', { method, name: error.name, message: error.message,
          code: error.code, details: error.details,
          cancellationReason: signal?.aborted ? String(signal.reason) : null }).catch(() => {});
        throw error;
      }
      await retain('action-' + method, { monotonic_ms: performance.now(), value });
      if (writeError) throw writeError;
      return value;
    },
  };
  outcome = await flightCase(io, name, { signal: cancel.signal });
  // A mid-case restart cannot become a successful observation on the initial actor proof.
  admitActors(config, await native('container', config.px4Id),
    await native('container', config.serverId), image, pins,
    await native('volume', config.runVolume),
    await native('network', config.project + '_default'));
} catch (error) { firstError = error; }
finally {
  try {
    await sdkFiber?.dispose();
    if (sdkFiber) assert(isDisposed(sdkFiber), 'MAVSDK child handles did not settle');
    await jobsFiber.dispose();
    assert(isDisposed(jobsFiber), 'Jobs child did not settle');
  } catch (error) { firstError ??= error; }
  process.off('SIGINT', requestCancel);
  process.off('SIGTERM', requestCancel);
}
await retain('controller-result', { complete: !firstError, outcome,
  error: firstError ? String(firstError) : null,
  scope: 'flight observations/SDK child settlement only; not producer cleanup or public evaluator verdict' });
if (firstError) { console.error(firstError); process.exitCode = 1; }
