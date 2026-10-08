// Configuration IDs are distinct from distribution manifest digests.
export function canonicalConfigId(value) {
  if (typeof value !== 'string' || !/^(?:sha256:)?[a-f0-9]{64}$/.test(value)) {
    throw new Error('native image config ID is malformed');
  }
  return value.startsWith('sha256:') ? value : 'sha256:' + value;
}

export function assertOwned(native, expected) {
  if (!native || native.Id !== expected.cid ||
      canonicalConfigId(native.Image) !== canonicalConfigId(expected.image) ||
      native.Config?.Labels?.['org.example.nav2.owner'] !== expected.owner ||
      typeof native.Name !== 'string' ||
      native.Name.replace(/^\//, '') !== expected.name) {
    throw new Error('native ownership changed before cleanup');
  }
  return native;
}

// Acquisition refusal remains primary; this only recovers a possibly created object.
export async function recoverCreated(command, expected) {
  const raw = await command('recover-created-inventory',
    ['ps', '--all', '--quiet', '--no-trunc', '--filter',
      'label=org.example.nav2.owner=' + expected.owner, '--filter', 'name=^' + expected.name + '$']);
  const ids = raw.trim().split(/\s+/).filter(Boolean);
  if (ids.length > 1 || ids.some(id => !/^[a-f0-9]{64}$/.test(id))) {
    throw new Error('owned acquisition inventory is not one exact native ID');
  }
  if (!ids.length) return null;
  const records = JSON.parse(await command('recover-created-inspect', ['inspect', ids[0]]));
  if (!Array.isArray(records) || records.length !== 1) throw new Error('native inspect is not one object');
  return assertOwned(records[0], {...expected, cid: ids[0]});
}

export function createdId(raw) {
  if (typeof raw !== 'string' || !/^[a-f0-9]{64}\n?$/.test(raw)) {
    throw new Error('exact native container ID missing');
  }
  return raw.endsWith('\n') ? raw.slice(0, -1) : raw;
}

export function nativeWaitExit(raw) {
  if (typeof raw !== 'string' || !/^(?:0|[1-9][0-9]{0,2})\n?$/.test(raw)) {
    throw new Error('native wait did not report one integer exit');
  }
  const exit = Number(raw.endsWith('\n') ? raw.slice(0, -1) : raw);
  if (exit > 255) throw new Error('native wait exit is outside native status range');
  return exit;
}

export function assertRosStopSignal(native) {
  if (native.Config?.StopSignal !== 2 && native.Config?.StopSignal !== 'SIGINT') {
    throw new Error('native ROS launch shutdown signal is not SIGINT');
  }
}

export async function admitAndStart(command, expected) {
  const records = JSON.parse(await command('inspect-acquired', ['inspect', expected.cid]));
  if (!Array.isArray(records) || records.length !== 1) throw new Error('native inspect is not one object');
  const native = assertOwned(records[0], expected);
  assertRosStopSignal(native);
  await command('start', ['start', expected.cid]);
  return native;
}

export async function removeUnstartedOwned(command, native, expected) {
  assertOwned(native, expected);
  if (native.State?.Running === false && native.State?.Pid === 0 &&
      ['created', 'configured'].includes(native.State?.Status)) {
    await command('remove', ['rm', expected.cid]);
    return true;
  }
  return false;
}
