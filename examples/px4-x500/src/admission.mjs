import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import { isAbsolute } from 'node:path';

export function configDigest(value) {
  assert.equal(typeof value, 'string');
  assert.match(value, /^(?:sha256:)?[a-f0-9]{64}(?![\s\S])/);
  return value.replace(/^sha256:/, '');
}

export function inspectionArguments(config, kind, id) {
  assert(isAbsolute(config.engineSocket ?? ''), 'absolute selected Engine socket required');
  assert(/^1\.(?:2[4-9]|[34][0-9]|5[0-3])$/.test(config.engineApiVersion ?? ''),
    'selected Engine API must stay in the admitted operation range');
  const routes = {
    container: ['containers', '/json'], image: ['images', '/json'],
    volume: ['volumes', ''], network: ['networks', ''],
  };
  assert(Object.hasOwn(routes, kind), 'fixed read-only inspection operation required');
  if (kind === 'container') {
    assert.match(id, /^[a-f0-9]{64}$/);
    assert([config.px4Id, config.serverId].includes(id), 'issued actor ID required');
  } else if (kind === 'image') {
    configDigest(id);
  } else if (kind === 'volume') {
    assert.match(id, /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/);
    assert.equal(id, config.runVolume);
  } else {
    assert.match(config.project, /^rr-px4-[a-f0-9]{24}$/);
    assert.equal(id, config.project + '_default');
  }
  const [collection, suffix] = routes[kind];
  return ['--disable', '--silent', '--show-error', '--fail', '--max-time', '10',
    '--unix-socket', config.engineSocket, '--request', 'GET',
    'http://localhost/v' + config.engineApiVersion + '/' + collection + '/' + encodeURIComponent(id) + suffix];
}

function environment(values) {
  assert(Array.isArray(values));
  const result = Object.create(null);
  for (const value of values) {
    assert.equal(typeof value, 'string');
    const at = value.indexOf('=');
    assert(at > 0);
    const key = value.slice(0, at);
    assert(!Object.hasOwn(result, key), 'duplicate environment key');
    result[key] = value.slice(at + 1);
  }
  return { ...result };
}

function actorEnvironment(actor, baseline) {
  const values = environment(actor.Config.Env);
  // Native engines may inject these identity fields into otherwise unchanged image env.
  if (Object.hasOwn(values, 'HOSTNAME') && !Object.hasOwn(baseline, 'HOSTNAME')) {
    assert.equal(actor.Config.Hostname, actor.Id.slice(0, 12));
    assert(values.HOSTNAME === actor.Config.Hostname, 'native hostname environment differs');
    delete values.HOSTNAME;
  }
  if (Object.hasOwn(values, 'container') && !Object.hasOwn(baseline, 'container')) {
    assert(values.container === 'podman', 'native engine environment differs');
    delete values.container;
  }
  return values;
}

function tmpfs(actor, size) {
  const mounts = actor.Mounts.filter(v => v.Destination === '/tmp');
  const options = actor.HostConfig.Tmpfs ?? {};
  assert(Object.keys(options).every(k => k === '/tmp'));
  assert(mounts.length <= 1);
  for (const mount of mounts) assert(mount.Type === 'tmpfs' && mount.RW === true);
  assert.equal(typeof options['/tmp'], 'string', 'observed tmpfs options required');
  const parts = options['/tmp'].split(',');
  assert.equal(parts.filter(v => v === 'rw').length, 1);
  assert.equal(parts.filter(v => v.startsWith('mode=')).join(), 'mode=1777');
  assert(parts.every(v => ['rw', 'mode=1777', 'rprivate', 'nosuid', 'nodev', 'tmpcopyup'].includes(v) ||
    /^size=\d+[kmg]?$/i.test(v)));
  const sizes = parts.filter(v => v.startsWith('size='));
  assert.equal(sizes.length, 1);
  const match = /^size=(\d+)([kmg]?)$/i.exec(sizes[0]);
  assert(match);
  assert.equal(Number(match[1]) * ({ '': 1, k: 1024, m: 1048576, g: 1073741824 })[match[2].toLowerCase()], size);
}

export function admitActors(config, px4, server, image, pins, volume, network) {
  assert.match(config.px4Id, /^[a-f0-9]{64}$/);
  assert.match(config.serverId, /^[a-f0-9]{64}$/);
  assert.notEqual(config.px4Id, config.serverId);
  assert.match(config.ownerId, /^[a-zA-Z0-9][a-zA-Z0-9_.-]{1,100}$/);
  assert.match(config.project, /^rr-px4-[a-f0-9]{24}$/);
  assert(Number.isSafeInteger(config.grpcPort) && config.grpcPort >= 1024 && config.grpcPort <= 65535);
  assert.equal(configDigest(image.Id), configDigest(pins.worker_image_id));
  assert(image.RepoDigests?.some(ref => ref.endsWith('@sha256:' + pins.worker_manifest_sha256)));
  for (const [actor, id, service, provider] of [
    [px4, config.px4Id, 'px4-native', 'px4-stock'],
    [server, config.serverId, 'mavsdk-native', 'mavsdk-native'],
  ]) {
    assert.equal(actor.Id, id);
    assert.equal(configDigest(actor.Image), configDigest(image.Id));
    assert.equal(actor.State?.Running, true);
    assert.equal(actor.State?.OOMKilled, false);
    assert.equal(actor.RestartCount, 0);
    assert.equal(actor.Config?.User, '1000:1000');
    assert.equal(actor.HostConfig?.ReadonlyRootfs, true);
    assert.equal(actor.HostConfig?.Privileged, false);
    assert(Array.isArray(actor.Mounts));
    assert.equal(actor.HostConfig.Init, true);
    assert.deepEqual(actor.HostConfig.CapAdd ?? [], []);
    const dropped = actor.HostConfig.CapDrop?.map(v => v.replace(/^CAP_/, '')).sort();
    const nativeDropped = ['CHOWN', 'DAC_OVERRIDE', 'FOWNER', 'FSETID', 'KILL', 'NET_BIND_SERVICE',
      'SETFCAP', 'SETGID', 'SETPCAP', 'SETUID', 'SYS_CHROOT'].sort();
    assert(dropped && (JSON.stringify(dropped) === JSON.stringify(['ALL']) ||
      JSON.stringify(dropped) === JSON.stringify(nativeDropped)), 'stock all-capability drop required');
    if (actor === px4) assert.equal(actor.HostConfig.PidsLimit, 256);
    assert.equal(actor.HostConfig.Memory, actor === px4 ? 4294967296 : 268435456);
    assert.deepEqual(actor.HostConfig.SecurityOpt, ['no-new-privileges']);
    assert(actor.Mounts.every(v => (actor === px4 && v.Destination === '/run/robotics') || v.Destination === '/tmp'));
    tmpfs(actor, actor === px4 ? 536870912 : 33554432);
    assert.equal(actor.Config?.Labels?.['org.robotics.runtime.run-id'], config.ownerId);
    assert.equal(actor.Config?.Labels?.['com.docker.compose.project'], config.project);
    assert.equal(actor.Config?.Labels?.['com.docker.compose.service'], service);
    assert.equal(actor.Config?.Labels?.['org.robotics.runtime.provider'], provider);
  }
  assert.equal(server.HostConfig?.NetworkMode, 'container:' + px4.Id);
  assert(['bridge', config.project + '_default'].includes(px4.HostConfig?.NetworkMode));
  assert.deepEqual(Object.keys(px4.NetworkSettings?.Networks ?? {}), [config.project + '_default']);
  assert.deepEqual(px4.Config.Entrypoint, ['/opt/px4/build/px4_sitl_default/bin/px4']);
  assert.deepEqual(px4.Config.Cmd, ['-d', '/opt/px4/build/px4_sitl_default/etc', '-w',
    '/run/robotics/output/px4/' + config.project.slice('rr-px4-'.length) + '/rootfs']);
  assert.deepEqual(server.Config.Entrypoint, ['/opt/robotics/mavsdk_server']);
  assert.deepEqual(server.Config.Cmd, ['-p', '50051', 'udpin://0.0.0.0:14540']);
  const baseline = environment(image.Config?.Env);
  assert.equal(baseline.PX4_SIM_MODEL, 'gz_x500');
  assert.equal(baseline.PX4_SYS_AUTOSTART, '4001');
  assert.equal(baseline.PX4_GZ_WORLD, 'default');
  assert(isDeepStrictEqual(actorEnvironment(px4, baseline),
    { ...baseline, GZ_PARTITION: config.project.slice('rr-px4-'.length) }), 'PX4 environment differs from admitted image');
  assert(isDeepStrictEqual(actorEnvironment(server, baseline), baseline), 'server environment differs from admitted image');
  assert.match(config.runVolume, /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/);
  assert.equal(volume.Name, config.runVolume);
  assert.equal(volume.Driver, 'local');
  assert.deepEqual(volume.Options ?? {}, {});
  assert.equal(typeof volume.Mountpoint, 'string');
  const data = px4.Mounts.filter(v => v.Destination === '/run/robotics');
  assert.equal(data.length, 1);
  assert.equal(data[0].Type, 'volume');
  assert.equal(data[0].Driver, 'local');
  assert.equal(data[0].Name, volume.Name);
  assert.equal(data[0].Source, volume.Mountpoint);
  assert.equal(data[0].RW, true);
  assert(server.Mounts.every(v => v.Destination === '/tmp'));
  assert.equal(network.Name, config.project + '_default');
  assert.match(network.Id, /^[a-f0-9]{64}$/);
  assert.equal(network.Driver, 'bridge');
  assert.equal(network.Labels?.['com.docker.compose.project'], config.project);
  const attached = px4.NetworkSettings.Networks[network.Name];
  assert([network.Id, network.Name].includes(attached.NetworkID));
  assert.deepEqual(Object.keys(network.Containers ?? {}), [px4.Id]);
  assert.equal(network.Containers[px4.Id].IPv4Address.split('/')[0], attached.IPAddress);
  assert.equal(network.Labels?.['org.robotics.runtime.run-id'], config.ownerId);
  assert.equal(network.Labels?.['org.robotics.runtime.provider'], 'px4-stock');
  const ports = px4.NetworkSettings?.Ports?.['50051/tcp'];
  assert(Array.isArray(ports) && ports.length === 1);
  assert.equal(ports[0].HostIp, '127.0.0.1');
  assert.equal(ports[0].HostPort, String(config.grpcPort));
  return '127.0.0.1:' + config.grpcPort;
}
