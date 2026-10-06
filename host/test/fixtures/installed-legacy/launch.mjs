import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {Context, Jobs} from '@robotics-runtime/host';
import {ComposeExecution, EngineMetadata} from '@robotics-runtime/infra-host';

const [root, socket, image, artifacts] = process.argv.slice(2);
assert.match(image, /^[^\s@]+@sha256:[a-f0-9]{64}$/, 'observed full Node RepoDigest required');
assert.ok(import.meta.resolve('@robotics-runtime/infra-host').startsWith('file://' + root + '/node_modules/'));
const identity = JSON.parse(await readFile(root + '/identity.json', 'utf8'));
const runId = 'run-' + randomUUID(), project = 'rr-installed-ros-host-' + runId.slice(4, 12);
const owner = 'installed-ros-host-' + runId.slice(4, 12);
for (const name of [identity.sourceVolume, identity.retainedVolume]) assert.match(name, /^rr-[a-z0-9][a-z0-9-]{1,120}$/);
assert.notEqual(identity.sourceVolume, identity.retainedVolume);
await mkdir(artifacts, {recursive: false});
const save = async (name, value) => writeFile(artifacts + '/' + name + '.json', JSON.stringify(value, null, 2) + '\n');
const ctx = new Context();
await ctx.plugin(Jobs, {timeoutMs: 600000, maxBufferBytes: 4194304}).await();
const engine = await EngineMetadata.connect({socketPath: socket, operationMinApi: '1.24', operationMaxApi: '1.53'});
const job = async (name, args) => {
  const result = await ctx.jobs.run({executable: '/usr/bin/podman', args, extendEnv: true, timeoutMs: 30000, maxBufferBytes: 4194304});
  await save(name, result);
  assert.equal(result.ok, true, result.stderr);
  return result;
};
const env = {
  C18_NODE_IMAGE: image, C18_SOCKET: socket, C18_HOST_OWNER: owner, C18_HOST_PROJECT: project,
  C18_SOURCE_VOLUME: identity.sourceVolume, C18_RETAINED_VOLUME: identity.retainedVolume,
  C18_DEPLOYMENT_HOST_ROOT: root + '/deployment',
};
const compose = new ComposeExecution(ctx.jobs, {
  executable: root + '/tools/docker-compose', socketPath: socket, projectName: project,
  files: [root + '/compose.host.yaml'], cwd: root, env, timeoutMs: 600000, maxBufferBytes: 4194304,
});
const lastJson = text => JSON.parse(text.trim().split('\n').reverse().find(line => line.startsWith('{')));
try {
  const before = JSON.parse((await job('pre-existing-containers-before', ['ps', '--all', '--format', 'json'])).stdout);
  for (const volume of [identity.sourceVolume, identity.retainedVolume]) {
    const exists = await ctx.jobs.run({executable: '/usr/bin/podman', args: ['volume', 'exists', volume], extendEnv: true, timeoutMs: 10000});
    assert.equal(exists.exitCode, 1, 'qualification volumes must be new');
  }
  await job('create-retained-volume', ['volume', 'create', '--label', 'org.robotics.runtime.storage-owner=' + owner, '--label', 'org.robotics.runtime.run-id=' + owner, identity.retainedVolume]);
  await compose.requireVersion();
  const init = await compose.run(['run', '--rm', '--no-deps', 'storage-init']);
  await save('storage-init', init);
  assert.equal(init.ok, true, init.stderr);
  const output = '/retained/startup-' + runId;
  const live = await compose.run([
    'run', '--rm', '--no-deps', 'installed-host', '/inputs', '/engine.sock',
    '/usr/local/bin/docker-compose', runId, identity.sourceVolume, identity.retainedVolume,
    identity.simulationId, identity.simulationImage, identity.finalizerImage,
    identity.evidenceImage, output, identity.deploymentRevision,
  ]);
  await save('installed-live-job', live);
  assert.equal(live.ok, true, live.stderr);
  assert.equal(lastJson(live.stdout).status, 'passed');
  const hostOwned = await engine.projectOwnership({runId: owner, projectName: project});
  await save('host-before-source-teardown', hostOwned);
  assert.equal(hostOwned.status, 'complete', JSON.stringify(hostOwned));
  assert.equal(hostOwned.inventory.containers.length, 0);
  assert.equal(hostOwned.inventory.networks.length, 0);
  const runtime = await engine.remainingOwned(runId);
  await save('runtime-cleanup-before-source-teardown', runtime);
  assert.equal(runtime.containers.length, 0);
  assert.equal(runtime.networks.length, 0);
  assert.ok(runtime.volumes.Volumes === null || runtime.volumes.Volumes.length === 0);
  const volume = JSON.parse((await job('actual-source-volume-before-teardown', ['volume', 'inspect', identity.sourceVolume])).stdout)[0];
  assert.equal(volume.Name, identity.sourceVolume);
  assert.equal(volume.Labels?.['org.robotics.runtime.storage-owner'], owner);
  assert.equal(volume.Labels?.['org.robotics.runtime.run-id'], owner);
  assert.equal(volume.Labels?.['com.docker.compose.project'], project);
  const down = await compose.run(['down', '--remove-orphans']);
  await save('host-down', down);
  assert.equal(down.ok, true, down.stderr);
  await job('remove-only-owned-source-volume', ['volume', 'rm', identity.sourceVolume]);
  const absent = await ctx.jobs.run({executable: '/usr/bin/podman', args: ['volume', 'exists', identity.sourceVolume], extendEnv: true, timeoutMs: 10000});
  await save('source-volume-absence', absent);
  assert.equal(absent.exitCode, 1);
  const postProject = project + '-retained';
  const postprocess = new ComposeExecution(ctx.jobs, {
    executable: root + '/tools/docker-compose', socketPath: socket, projectName: postProject,
    files: [root + '/compose.post.yaml'], cwd: root, env: {...env, C18_HOST_PROJECT: postProject},
    timeoutMs: 600000, maxBufferBytes: 4194304,
  });
  const qualified = await postprocess.run(['run', '--rm', '--no-deps', 'installed-postprocessor', '/retained/control-' + runId]);
  await save('installed-retained-only-qualification-job', qualified);
  assert.equal(qualified.ok, true, qualified.stderr);
  const verified = lastJson(qualified.stdout);
  assert.equal(verified.status, 'passed');
  assert.equal(verified.source_present, false);
  assert.equal(verified.aggregate.per_domain_aggregate, 'passed');
  const hostAfter = await engine.remainingOwned(owner), runtimeAfter = await engine.remainingOwned(runId);
  await save('host-after-public-qualification', hostAfter);
  await save('runtime-after-public-qualification', runtimeAfter);
  assert.equal(hostAfter.containers.length, 0);
  assert.equal(hostAfter.networks.length, 0);
  assert.deepEqual(hostAfter.volumes.Volumes.map(row => row.Name), [identity.retainedVolume]);
  assert.equal(runtimeAfter.containers.length, 0);
  assert.equal(runtimeAfter.networks.length, 0);
  assert.ok(runtimeAfter.volumes.Volumes === null || runtimeAfter.volumes.Volumes.length === 0);
  const after = JSON.parse((await job('pre-existing-containers-after', ['ps', '--all', '--format', 'json'])).stdout);
  const ids = new Set(after.map(row => row.Id));
  assert.ok(before.every(row => ids.has(row.Id)), 'a pre-existing container disappeared');
  const report = {
    status: 'passed', scope: 'ordinary installed two-TGZ ROS/Gazebo live + public aggregate and portable qualification',
    identity, runId, project, sourceVolumeRemoved: true, retainedVolume: identity.retainedVolume,
    engine: engine.facts, verification: verified, preExistingContainerIdsPreserved: before.map(row => row.Id).sort(),
  };
  await save('installed-ros-public-report', report);
  console.log(JSON.stringify(report));
} catch (error) {
  await save('failure', {status: 'failed', diagnostic: String(error), identity, runId, project});
  throw error;
} finally {
  await ctx.fiber.dispose();
}
