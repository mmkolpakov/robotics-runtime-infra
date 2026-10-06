import assert from 'node:assert/strict';
import {Context, Jobs} from '@robotics-runtime/host';
import {ComposeExecution, EngineMetadata} from '@robotics-runtime/infra-host';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {setTimeout as pause} from 'node:timers/promises';

const [root, socket, executable, image, artifacts] = process.argv.slice(2);
assert.ok(import.meta.resolve('@robotics-runtime/infra-host').startsWith('file://' + root + '/node_modules/'));
const identity = JSON.parse(await readFile(root + '/identity.json', 'utf8'));
for (const name of [identity.sourceVolume, identity.retainedVolume]) {
  assert.match(name, /^rr-[a-z0-9][a-z0-9-]{0,59}$/);
}
assert.notEqual(identity.sourceVolume, identity.retainedVolume);
const owner = identity.hostOwner;
const project = identity.hostProject;
assert.match(owner, /^rr-webots-host-[a-f0-9]{24}$/);
assert.equal(project, owner);
const ctx = new Context();
await ctx.plugin(Jobs, {timeoutMs: 300000, maxBufferBytes: 4 * 1024 * 1024}).await();
const engine = await EngineMetadata.connect({socketPath: socket, operationMinApi: '1.24', operationMaxApi: '1.53'});
const compose = new ComposeExecution(ctx.jobs, {
  executable, socketPath: socket, projectName: project,
  files: [root + '/compose.host.yaml'], cwd: root, timeoutMs: 300000,
  maxBufferBytes: 4 * 1024 * 1024,
  env: {
    C18_NODE_IMAGE: image, C18_WORKER_IMAGE: identity.workerImage,
    C18_SOCKET: socket, C18_SOURCE_VOLUME: identity.sourceVolume,
    C18_RETAINED_VOLUME: identity.retainedVolume, C18_HOST_OWNER: owner,
  },
});
await mkdir(artifacts, {recursive: false});
const save = async (name, value) => writeFile(artifacts + '/' + name, JSON.stringify(value, null, 2) + '\n');
const requireJob = async (name, args) => {
  const result = await ctx.jobs.run({executable: '/usr/bin/podman', args, extendEnv: true, timeoutMs: 30000, maxBufferBytes: 4 * 1024 * 1024});
  await save(name + '.json', result);
  assert.equal(result.ok, true, result.stderr);
  return result;
};
const lastJson = value => {
  for (const line of value.trim().split('\n').reverse()) {
    if (line.startsWith('{')) return JSON.parse(line);
  }
  throw new Error('worker returned no structured qualification result');
};
try {
  const before = JSON.parse((await requireJob('unrelated-containers-before', ['ps', '--all', '--format', 'json'])).stdout);
  for (const name of [identity.sourceVolume, identity.retainedVolume]) {
    const exists = await ctx.jobs.run({executable: '/usr/bin/podman', args: ['volume', 'exists', name], extendEnv: true, timeoutMs: 10000});
    assert.equal(exists.exitCode, 1, 'qualification volumes must be new: ' + name);
  }
  await requireJob('create-retained-volume', [
    'volume', 'create', '--label', 'org.robotics.runtime.storage-owner=' + owner,
    '--label', 'org.robotics.runtime.run-id=' + owner, identity.retainedVolume,
  ]);
  await compose.requireVersion();
  const init = await compose.run(['run', '--rm', '--no-deps', 'storage-init']);
  await save('storage-init.json', init);
  assert.equal(init.ok, true, init.stderr);
  const job = compose.run(['run', '--rm', '--no-deps', 'installed-host']);
  let observed = false;
  const end = performance.now() + 60000;
  while (!observed && performance.now() < end) {
    const inv = await engine.remainingOwned(owner);
    const host = inv.containers.find(row => row.Labels?.['com.docker.compose.service'] === 'installed-host');
    if (host) {
      const metadata = await engine.inspect(host.Id, {
        runId: owner, projectName: project, imageDigest: image,
        mounts: [
          {destination: '/run/robotics', readOnly: false, volumeName: identity.sourceVolume},
          {destination: '/retained', readOnly: false, volumeName: identity.retainedVolume},
        ],
        hostConfig: {Init: true, ReadonlyRootfs: true, NetworkMode: 'none', Memory: 1073741824},
        user: '1000:1000',
      });
      await save('actual-installed-host.json', metadata);
      assert.equal(metadata.status, 'complete', JSON.stringify(metadata));
      observed = true;
    } else await pause(25);
  }
  const result = await job;
  await save('installed-host-job.json', result);
  assert.equal(result.ok, true, result.stderr);
  assert.equal(observed, true);
  const native = lastJson(result.stdout);
  assert.equal(native.passed, true);
  const own = await engine.projectOwnership({runId: owner, projectName: project});
  await save('host-project-before-source-teardown.json', own);
  assert.equal(own.status, 'complete', JSON.stringify(own));
  assert.equal(own.inventory.containers.length, 0);
  assert.equal(own.inventory.networks.length, 0);
  const sourceAudit = await compose.run([
    'run', '--rm', '--no-deps', 'source-byte-audit',
    '--retained', '/retained', '--source-root', '/run/robotics',
    '--audit-output', '/retained/before-source-teardown-byte-audit.json',
  ]);
  await save('before-source-teardown-byte-job.json', sourceAudit);
  assert.equal(sourceAudit.ok, true, sourceAudit.stderr);
  const beforeBytes = lastJson(sourceAudit.stdout);
  assert.equal(beforeBytes.status, 'passed');
  assert.equal(beforeBytes.source_present, true);
  const source = JSON.parse((await requireJob('source-volume-before-teardown', ['volume', 'inspect', identity.sourceVolume])).stdout)[0];
  assert.equal(source.Name, identity.sourceVolume);
  assert.equal(source.Labels?.['org.robotics.runtime.storage-owner'], owner);
  assert.equal(source.Labels?.['org.robotics.runtime.run-id'], owner);
  assert.equal(source.Labels?.['com.docker.compose.project'], project);
  const ownedBefore = await engine.remainingOwned(owner);
  assert.equal(ownedBefore.containers.length, 0);
  assert.equal(ownedBefore.networks.length, 0);
  assert.ok(ownedBefore.volumes.Volumes?.some(row => row.Name === identity.sourceVolume));
  assert.ok(ownedBefore.volumes.Volumes.every(row => [identity.sourceVolume, identity.retainedVolume].includes(row.Name)));
  await save('owned-resources-before-source-teardown.json', ownedBefore);
  const down = await compose.run(['down', '--remove-orphans']);
  await save('host-project-down.json', down);
  assert.equal(down.ok, true, down.stderr);
  await requireJob('remove-only-owned-source-volume', ['volume', 'rm', identity.sourceVolume]);
  const absent = await ctx.jobs.run({executable: '/usr/bin/podman', args: ['volume', 'exists', identity.sourceVolume], extendEnv: true, timeoutMs: 10000});
  await save('source-volume-absence.json', absent);
  assert.equal(absent.exitCode, 1);
  const ownedAfter = await engine.remainingOwned(owner);
  await save('owned-resources-after-source-teardown.json', ownedAfter);
  assert.equal(ownedAfter.containers.length, 0);
  assert.equal(ownedAfter.networks.length, 0);
  assert.deepEqual(ownedAfter.volumes.Volumes.map(row => row.Name), [identity.retainedVolume]);
  const postprocess = new ComposeExecution(ctx.jobs, {
    executable, socketPath: socket, projectName: project + '-portable',
    files: [root + '/compose.retained.yaml'], cwd: root, timeoutMs: 120000,
    maxBufferBytes: 4 * 1024 * 1024,
    env: {C18_WORKER_IMAGE: identity.workerImage, C18_RETAINED_VOLUME: identity.retainedVolume, C18_HOST_OWNER: owner},
  });
  const portable = await postprocess.run([
    'run', '--rm', '--no-deps', 'retained-byte-verifier',
    '--retained', '/retained', '--source-root', '/run/robotics',
    '--expected-audit', '/retained/before-source-teardown-byte-audit.json',
    '--output', '/retained/portable-after-source-teardown',
  ]);
  await save('retained-only-portable-job.json', portable);
  assert.equal(portable.ok, true, portable.stderr);
  const verified = lastJson(portable.stdout);
  assert.equal(verified.status, 'passed');
  assert.equal(verified.source_present, false);
  assert.equal(verified.all_original_retained_bytes_unchanged, true);
  assert.deepEqual(verified.native_byte_audit, beforeBytes.audit);
  assert.equal(verified.tampered_copy.refused, true);
  assert.equal(verified.public_aggregate.status, 'unsupported');
  const after = JSON.parse((await requireJob('unrelated-containers-after', ['ps', '--all', '--format', 'json'])).stdout);
  const afterIds = new Set(after.map(row => row.Id));
  assert.ok(before.every(row => afterIds.has(row.Id)), 'a pre-existing unrelated container disappeared');
  const afterPortable = await engine.remainingOwned(owner);
  await save('owned-resources-after-portable.json', afterPortable);
  assert.equal(afterPortable.containers.length, 0);
  assert.equal(afterPortable.networks.length, 0);
  assert.deepEqual(afterPortable.volumes.Volumes.map(row => row.Name), [identity.retainedVolume]);
  const postprocessAfter = await engine.projectOwnership({runId: owner, projectName: project + '-portable'});
  await save('portable-project-after.json', postprocessAfter);
  assert.equal(postprocessAfter.status, 'complete');
  assert.equal(postprocessAfter.inventory.containers.length, 0);
  assert.equal(postprocessAfter.inventory.networks.length, 0);
  const finalOwn = await engine.projectOwnership({runId: owner, projectName: project});
  await save('host-project-after-portable.json', finalOwn);
  assert.equal(finalOwn.status, 'complete');
  assert.equal(finalOwn.inventory.containers.length, 0);
  assert.equal(finalOwn.inventory.networks.length, 0);
  const report = {
    status: 'passed', scope: 'native-only installed two-TGZ Webots qualification',
    project, identity, engine: engine.facts, native, portable: verified,
    sourceVolumeRemoved: true, retainedVolume: identity.retainedVolume,
    unrelatedContainerIdsPreserved: before.map(row => row.Id).sort(),
    publicAggregate: verified.public_aggregate,
  };
  await save('native-only-report.json', report);
  console.log(JSON.stringify(report));
} catch (error) {
  await save('failure.json', {status: 'failed', diagnostic: String(error), identity, project});
  throw error;
} finally {
  await ctx.fiber.dispose();
}
