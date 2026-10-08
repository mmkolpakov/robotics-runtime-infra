import { test } from 'node:test';
import assert from 'node:assert/strict';
import { admitActors, configDigest } from '../src/admission.mjs';

function actors() {
  const config = { px4Id: 'a'.repeat(64), serverId: 'b'.repeat(64),
    ownerId: 'run-123', project: 'rr-px4-' + 'c'.repeat(24), grpcPort: 50113, runVolume: 'retained-stock-data' };
  const pins = { worker_image_id: 'sha256:' + 'd'.repeat(64), worker_manifest_sha256: 'e'.repeat(64) };
  const image = { Config: { Env: ['PATH=/usr/bin:/bin', 'PX4_SIM_MODEL=gz_x500',
    'PX4_SYS_AUTOSTART=4001', 'PX4_GZ_WORLD=default'] }, Id: pins.worker_image_id, RepoDigests: ['localhost/stock@sha256:' + 'e'.repeat(64)] };
  const actor = (id, service, provider) => ({ Id: id, Image: image.Id,
    State: { Running: true, OOMKilled: false }, RestartCount: 0,
    Config: { User: '1000:1000', Labels: { 'org.robotics.runtime.run-id': config.ownerId,
      'com.docker.compose.project': config.project, 'com.docker.compose.service': service,
      'org.robotics.runtime.provider': provider } },
    HostConfig: { ReadonlyRootfs: true, Privileged: false, Init: true,
      Memory: service === 'px4-native' ? 4294967296 : 268435456,
      CapDrop: ['ALL'], CapAdd: [], PidsLimit: 256, SecurityOpt: ['no-new-privileges'], Tmpfs: { '/tmp': 'rw,mode=1777,size=' +
        (service === 'px4-native' ? '512m' : '32m') } }, Mounts: [] });
  const px4 = actor(config.px4Id, 'px4-native', 'px4-stock');
  px4.NetworkSettings = { Networks: { [config.project + '_default']: {
    NetworkID: 'f'.repeat(64), IPAddress: '10.89.0.2' } }, Ports: { '50051/tcp': [{ HostIp: '127.0.0.1', HostPort: '50113' }] } };
  px4.Config.Entrypoint = ['/opt/px4/build/px4_sitl_default/bin/px4'];
  px4.Config.Cmd = ['-d', '/opt/px4/build/px4_sitl_default/etc', '-w',
    '/run/robotics/output/px4/' + 'c'.repeat(24) + '/rootfs'];
  px4.Config.Env = [...image.Config.Env, 'GZ_PARTITION=' + 'c'.repeat(24)];
  px4.Mounts = [{ Type: 'volume', Driver: 'local', Name: config.runVolume, Source: '/retained/data',
    Destination: '/run/robotics', RW: true }];
  px4.HostConfig.NetworkMode = config.project + '_default';
  const server = actor(config.serverId, 'mavsdk-native', 'mavsdk-native');
  server.Config.Entrypoint = ['/opt/robotics/mavsdk_server'];
  server.Config.Cmd = ['-p', '50051', 'udpin://0.0.0.0:14540'];
  server.HostConfig.NetworkMode = 'container:' + px4.Id;
  server.Config.Env = [...image.Config.Env];
  const volume = { Name: config.runVolume, Driver: 'local', Options: {}, Mountpoint: '/retained/data' };
  const network = { Id: 'f'.repeat(64), Driver: 'bridge', Containers: {
    [px4.Id]: { IPv4Address: '10.89.0.2/24' } }, Name: config.project + '_default', Labels: {
    'org.robotics.runtime.run-id': config.ownerId, 'org.robotics.runtime.provider': 'px4-stock',
    'com.docker.compose.project': config.project } };
  return [config, px4, server, image, pins, volume, network];
}
test('exact observed owned simulation pair binds the local endpoint', () => {
  assert.equal(admitActors(...actors()), '127.0.0.1:50113');
});
for (const [name, change] of [
  ['same labels with foreign image', v => { v[1].Image = 'sha256:' + 'f'.repeat(64); }],
  ['foreign run', v => { v[2].Config.Labels['org.robotics.runtime.run-id'] = 'another-run'; }],
  ['foreign namespace parent', v => { v[2].HostConfig.NetworkMode = 'host'; }],
  ['nonloopback listener', v => { v[1].NetworkSettings.Ports['50051/tcp'][0].HostIp = '0.0.0.0'; }],
  ['different manifest', v => { v[3].RepoDigests = ['localhost/stock@sha256:' + 'f'.repeat(64)]; }],
  ['stopped worker', v => { v[1].State.Running = false; }],
  ['restart', v => { v[2].RestartCount = 1; }],
  ['non-simulator command', v => { v[1].Config.Entrypoint = ['/bin/sleep']; }],
  ['changed MAVLink endpoint', v => { v[2].Config.Cmd = ['-p', '50051', 'serial:///dev/ttyUSB0']; }],
  ['ambiguous simulation environment', v => { v[1].Config.Env.push('PX4_SIM_MODEL=another'); }],
  ['different simulation model', v => { v[1].Config.Env[1] = 'PX4_SIM_MODEL=another'; }],
  ['code path replaced by bind mount', v => { v[1].Mounts = [{ Destination: '/opt/px4' }]; }],
  ['prototype-named environment key', v => { v[1].Config.Env.push('__proto__=foreign'); }],
  ['arbitrary PX4 loader override', v => { v[1].Config.Env.push('LD_PRELOAD=/tmp/custom.so'); }],
  ['arbitrary server routing override', v => { v[2].Config.Env.push('MAVSDK_ENDPOINT=foreign'); }],
  ['foreign retained volume', v => { v[1].Mounts[0].Name = 'foreign'; }],
  ['foreign volume source', v => { v[1].Mounts[0].Source = '/foreign'; }],
  ['readonly retained volume', v => { v[1].Mounts[0].RW = false; }],
  ['missing retained volume', v => { v[1].Mounts = []; }],
  ['volume replaced by bind', v => { v[1].Mounts[0].Type = 'bind'; }],
  ['server has retained volume', v => { v[2].Mounts = [v[1].Mounts[0]]; }],
  ['externally remapped volume', v => { v[5].Options = { device: '/foreign', type: 'none', o: 'bind' }; }],
  ['foreign network owner', v => { v[6].Labels['org.robotics.runtime.run-id'] = 'foreign'; }],
  ['changed tmpfs size', v => { v[1].HostConfig.Tmpfs['/tmp'] = 'rw,mode=1777,size=1m'; }],
  ['unexpected tmpfs mount', v => { v[2].HostConfig.Tmpfs['/opt'] = 'rw'; }],
  ['missing image environment', v => { delete v[3].Config.Env; }],
  ['foreign network attachment', v => { v[1].NetworkSettings.Networks = { foreign: {} }; }],
  ['extra namespace attachment', v => { v[1].NetworkSettings.Networks.extra = {}; }],
  ['foreign network identity', v => { v[1].NetworkSettings.Networks[v[6].Name].NetworkID = 'a'.repeat(64); }],
  ['foreign network member', v => { v[6].Containers['b'.repeat(64)] = {}; }],
  ['different attached address', v => { v[6].Containers[v[1].Id].IPv4Address = '10.89.0.3/24'; }],
  ['foreign injected hostname', v => { v[1].Config.Hostname = v[1].Id.slice(0, 12); v[1].Config.Env.push('HOSTNAME=foreign'); }],
  ['foreign engine marker', v => { v[2].Config.Env.push('container=foreign'); }],
  ['contradictory tmpfs mode', v => { v[1].HostConfig.Tmpfs['/tmp'] += ',mode=0700'; }],
  ['added capability', v => { v[2].HostConfig.CapAdd = ['SYS_ADMIN']; }],
  ['missing capability drop', v => { v[1].HostConfig.CapDrop = []; }],
  ['foreign PID resource bound', v => { v[1].HostConfig.PidsLimit = 512; }],
  ['host network', v => { v[1].HostConfig.NetworkMode = 'host'; }],
  ['missing declared native fields', v => { delete v[1].State.OOMKilled; }],
]) test(name + ' refuses before command selection', () => {
  const v = actors();change(v);assert.throws(() => admitActors(...v));
});

test('bare native configuration ID equals only its exact optional-prefixed config digest', () => {
  const v = actors();
  v[3].Id = v[3].Id.slice(7);
  v[1].Image = v[3].Id;
  assert.equal(admitActors(...v), '127.0.0.1:50113');
  assert.equal(configDigest(v[3].Id), configDigest(v[4].worker_image_id));
});
for (const value of ['SHA256:' + 'd'.repeat(64), 'sha256:' + 'd'.repeat(63),
  'sha256:' + 'D'.repeat(64), 'sha256:sha256:' + 'd'.repeat(64), 'd'.repeat(64) + '\n']) {
  test('malformed configuration digest refuses: ' + JSON.stringify(value), () => {
    assert.throws(() => configDigest(value));
  });
}

test('native bridge representation requires the same exact owned named attachment', () => {
  const v = actors();
  v[1].HostConfig.NetworkMode = 'bridge';
  v[1].NetworkSettings.Networks[v[6].Name].NetworkID = v[6].Name;
  assert.equal(admitActors(...v), '127.0.0.1:50113');
});

test('native identity env is bound to actual hostname and the known engine marker', () => {
  const v = actors();
  for (const actor of [v[1], v[2]]) {
    actor.Config.Hostname = actor.Id.slice(0, 12);
    actor.Config.Env.push('HOSTNAME=' + actor.Config.Hostname, 'container=podman');
  }
  assert.equal(admitActors(...v), '127.0.0.1:50113');
});

test('observed native expanded drop-all capability set is exact and admits no additions', () => {
  const v = actors();
  for (const actor of [v[1], v[2]]) actor.HostConfig.CapDrop = ['CHOWN', 'DAC_OVERRIDE',
    'FOWNER', 'FSETID', 'KILL', 'NET_BIND_SERVICE', 'SETFCAP', 'SETGID', 'SETPCAP', 'SETUID', 'SYS_CHROOT'];
  assert.equal(admitActors(...v), '127.0.0.1:50113');
  v[1].HostConfig.CapDrop.pop();
  assert.throws(() => admitActors(...v));
});

test('refused foreign environment values are absent from assertion diagnostics', () => {
  for (const field of ['AUTH_TOKEN', 'HOSTNAME', 'container']) {
    const v = actors();
    v[1].Config.Hostname = v[1].Id.slice(0, 12);
    v[1].Config.Env.push(field + '=foreign-secret-marker');
    assert.throws(() => admitActors(...v), error => {
      assert.equal(String(error).includes('foreign-secret-marker'), false);
      assert.equal(JSON.stringify(error).includes('foreign-secret-marker'), false);
      return true;
    });
  }
});
