import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createReadStream} from 'node:fs';
import {readFile, stat, writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {Context, Jobs, RunResources} from '@robotics-runtime/host';
import {EngineMetadata} from '@robotics-runtime/infra-host';
import FinalInputs from '@robotics-runtime/infra-host/plugins/legacy-finalization-inputs';
import Finalizer from '@robotics-runtime/infra-host/plugins/legacy-finalization';

const [control] = process.argv.slice(2);
assert.ok(control.startsWith('/retained/control-run-'));
await assert.rejects(stat('/run/robotics'), {code: 'ENOENT'});
const completion = JSON.parse(await readFile(control + '/live-completion.json', 'utf8'));
const plan = JSON.parse(await readFile(control + '/finalization-plan.json', 'utf8'));
const before = JSON.parse(await readFile(control + '/before-source-teardown.json', 'utf8'));
assert.equal(completion.status, 'passed');
assert.equal(completion.runId, plan.runId);
const facts = async path => {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return {sha256: hash.digest('hex'), size_bytes: (await stat(path)).size};
};
const audit = async () => {
  for (const [path, expected] of Object.entries(before)) {
    assert.ok(path.startsWith('/retained/'));
    assert.deepEqual(await facts(path), expected, 'retained raw bytes changed: ' + path);
  }
  for (const ref of completion.evidenceRefs) {
    const path = fileURLToPath(ref.uri);
    assert.ok(path.startsWith('/retained/'));
    const actual = await facts(path);
    assert.equal(actual.sha256, ref.sha256);
    assert.equal(actual.size_bytes, ref.size_bytes);
  }
};
await audit();
const ctx = new Context();
await ctx.plugin(Jobs, {timeoutMs: 240000, maxBufferBytes: 4194304}).await();
await ctx.plugin(RunResources, plan.runId).await();
await ctx.plugin(FinalInputs).await();
ctx.get('legacyFinalizationInputs').issue(plan);
const fiber = ctx.plugin(Finalizer);
await fiber.await();
const service = ctx.get('legacyFinalization');
const engine = await EngineMetadata.connect({socketPath: '/engine.sock', operationMinApi: '1.24', operationMaxApi: '1.53'});
const own = await engine.remainingOwned(process.env.C18_HOST_OWNER);
const host = own.containers.find(row => row.Labels?.['com.docker.compose.service'] === 'installed-postprocessor');
assert.ok(host);
const observed = await engine.inspect(host.Id, {
  runId: process.env.C18_HOST_OWNER, projectName: process.env.C18_HOST_PROJECT,
  imageDigest: process.env.C18_NODE_IMAGE, user: '1000:1000',
  mounts: [{destination: '/retained', readOnly: false, volumeName: process.env.C18_RETAINED_VOLUME}],
  hostConfig: {Init: true, ReadonlyRootfs: true, NetworkMode: 'none', Memory: 1073741824},
});
assert.equal(observed.status, 'complete', JSON.stringify(observed));
assert.ok(!observed.container.Mounts.some(row => row.Name === process.env.C18_SOURCE_VOLUME || row.Destination === '/run/robotics'));
await writeFile(control + '/retained-only-host.json', JSON.stringify(observed, null, 2) + '\n');
try {
  const qualified = await service.qualifyAfterCleanup(completion, AbortSignal.timeout(240000));
  await audit();
  const aggregate = JSON.parse(await readFile(plan.aggregatePath, 'utf8'));
  assert.equal(aggregate.per_domain_aggregate, 'passed');
  assert.equal(aggregate.cross_domain_e2e.status, 'unevaluated');
  const live = JSON.parse(await readFile(plan.resultPath, 'utf8'));
  assert.equal(live.status, 'passed');
  assert.equal(live.evaluation_mode, 'live');
  const report = {
    status: 'passed', scope: 'installed ROS live aggregate and independent retained-only portable qualification',
    runId: plan.runId, source_present: false, rawFilesVerifiedAfterTeardown: Object.keys(before).length,
    originalLiveResult: live, aggregate, qualified, installedOrigins: Object.fromEntries([
      '@robotics-runtime/host', '@robotics-runtime/infra-host',
      '@robotics-runtime/infra-host/plugins/legacy-finalization',
    ].map(name => [name, import.meta.resolve(name)])),
  };
  assert.ok(Object.values(report.installedOrigins).every(value => value.startsWith('file:///app/node_modules/')));
  await writeFile(control + '/installed-public-qualification.json', JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report));
} finally {
  await ctx.fiber.dispose();
}
