import assert from 'node:assert/strict';
import {test} from 'node:test';
import type {TestContext} from 'node:test';
import {createServer} from 'node:http';
import {lstat, mkdtemp, mkdir, readFile, rm, stat, symlink, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {Context, Jobs, RunResources} from '@robotics-runtime/host';
import WebotsNative from '../src/plugins/webots-provider/index.js';
import type {WebotsConfig} from '../src/plugins/webots-provider/index.js';
import {EngineMetadata} from '../src/engine-metadata.js';

async function fixture(t: TestContext, retained = true) {
  const root = await mkdtemp(join(tmpdir(), 'rr-webots-retention-'));
  const ctx = new Context();
  await ctx.plugin(Jobs, {timeoutMs: 2000, maxBufferBytes: 1048576}).await();
  await ctx.plugin(RunResources, 'webots-test-owner').await();
  const config: WebotsConfig = {
    composeExecutable: join(root, 'compose'), socketPath: join(root, 'engine.sock'),
    composeFiles: [join(root, 'compose.yaml')], cwd: root,
    workerImage: 'localhost/webots@sha256:' + 'a'.repeat(64), runVolume: 'test-source',
    outputRoot: join(root, 'source'), mode: 'physics-only', deadlineMs: 1000,
    ...(retained ? {artifactDirectory: join(root, 'retained')} : {}),
  };
  await writeFile(config.composeExecutable, '#!' + process.execPath + '\nimport {appendFileSync} from "node:fs";appendFileSync(' + JSON.stringify(join(root, 'effects')) + ',JSON.stringify(process.argv.slice(2))+"\\n");\n', {mode: 0o700});
  const fiber = ctx.plugin(WebotsNative, config);
  await fiber.await();
  const provider = ctx.get('webots');
  const resources = ctx.get('runResources');
  assert.ok(provider);
  assert.ok(resources);
  t.after(async () => {
    await ctx.fiber.dispose().catch(() => {});
    await rm(root, {recursive: true, force: true});
  });
  return {root, ctx, provider, resources, config};
}

async function nativeFiles(provider: WebotsNative) {
  await mkdir(provider.output, {recursive: true});
  const names = ['controller-result.json', 'measurement.json', 'last-native-state.json',
    'ready.json', 'worker-identity.json', 'oci-init.json', 'engine-readiness.json',
    'renderer.txt', 'packages.tsv', 'binaries.sha256', 'controller.log', 'webots.log',
    'xvfb.log', 'pre-reset.json'];
  const expected = new Map<string, Buffer>();
  for (const name of names) {
    const bytes = name === 'webots.log' ? Buffer.alloc(5 * 1024 * 1024, 0x6b) : Buffer.from(name + '\n');
    await writeFile(join(provider.output, name), bytes);
    expected.set(name, bytes);
  }
  const result = Buffer.from(JSON.stringify({owner_id: provider.ownerId, evidence_exported_before_stop: true}));
  await writeFile(join(provider.output, 'worker-result.json'), result);
  expected.set('worker-result.json', result);
  return expected;
}

test('caller mutation cannot retarget the admitted worker and omitted retention preserves the source default', async t => {
  const {provider, config} = await fixture(t, false);
  const selected = config.workerImage, files = [...config.composeFiles];
  config.workerImage = 'localhost/foreign@sha256:' + 'b'.repeat(64);
  (config.composeFiles as string[]).push('/foreign/compose.yaml');
  assert.equal(provider.config.workerImage, selected);
  assert.deepEqual(provider.config.composeFiles, files);
  assert.throws(() => Object.assign(provider.config, {workerImage: config.workerImage}), TypeError);
  assert.throws(() => (provider.config.composeFiles as string[]).push('/foreign'), TypeError);
  assert.equal(provider.retainedOutput, provider.output);
  const expected = await nativeFiles(provider);
  const refs = await provider.exportEvidence(AbortSignal.timeout(1000));
  assert.equal(refs.length, expected.size);
  assert.ok(refs.every(ref => fileURLToPath(ref.uri).startsWith(provider.output + '/')));
});

test('exported retained bytes survive removal of the actual source files, including a large native log', async t => {
  const {provider} = await fixture(t);
  const expected = await nativeFiles(provider);
  const refs = await provider.exportEvidence(AbortSignal.timeout(1000));
  assert.equal(refs.length, expected.size);
  await rm(provider.output, {recursive: true});
  for (const ref of refs) {
    const path = fileURLToPath(ref.uri);
    assert.ok(path.startsWith(provider.retainedOutput + '/'));
    const bytes = await readFile(path), original = expected.get(path.split('/').at(-1)!)!;
    assert.deepEqual(bytes, original);
    assert.equal(ref.size_bytes, original.length);
    assert.equal(ref.sha256, createHash('sha256').update(original).digest('hex'));
  }
});

test('an occupied retention root refuses export and leaves the original native bytes available', async t => {
  const {provider, config} = await fixture(t);
  const expected = await nativeFiles(provider);
  await writeFile(config.artifactDirectory!, 'occupied');
  await assert.rejects(provider.exportEvidence(AbortSignal.timeout(1000)));
  for (const [name, bytes] of expected) assert.deepEqual(await readFile(join(provider.output, name)), bytes);
  assert.equal(await readFile(config.artifactDirectory!, 'utf8'), 'occupied');
});

async function ownershipApi(root: string, inventory: () => unknown[], volumes: () => unknown) {
  const api = createServer((request, response) => {
    let value: unknown;
    if (request.url === '/version') value = {ApiVersion: '1.41', MinAPIVersion: '1.24'};
    else if (request.url?.startsWith('/v1.41/containers/json')) value = inventory();
    else if (request.url?.startsWith('/v1.41/volumes')) value = volumes();
    else if (request.url?.startsWith('/v1.41/networks')) value = [];
    else {response.statusCode = 500; value = {error: 'unexpected test API request'};}
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify(value));
  });
  const socketPath = join(root, 'engine.sock');
  await new Promise<void>(resolve => api.listen(socketPath, resolve));
  const engine = await EngineMetadata.connect({socketPath, operationMinApi: '1.24', operationMaxApi: '1.53'});
  return {engine, close: async () => {
    api.closeAllConnections();
    await new Promise<void>((resolve, reject) => api.close(error => error ? reject(error) : resolve()));
  }};
}

test('same-project foreign ownership refuses actual cleanup commands and retains the observed refusal', async t => {
  const {root, ctx, provider, resources} = await fixture(t);
  const foreign = {Id: 'c'.repeat(64), Labels: {
    'com.docker.compose.project': provider.project, 'org.robotics.runtime.run-id': 'foreign-owner',
  }};
  const api = await ownershipApi(root, () => [foreign], () => ({Volumes: null}));
  try {
    Object.assign(provider, {engine: api.engine});
    await ctx.fiber.dispose().catch(() => {});
    const outcomes = await resources.verify(1000);
    assert.equal(outcomes[0].attempted, true);
    assert.equal(outcomes[0].released, false);
    assert.match(outcomes[0].cleanupError!, /ownership is incomplete; cleanup effects refused/);
    await assert.rejects(stat(join(root, 'effects')), {code: 'ENOENT'});
    const before = JSON.parse(await readFile(join(provider.retainedOutput, 'engine-cleanup-before.json'), 'utf8'));
    assert.equal(before.status, 'incomplete');
    assert.deepEqual(before.inventory.containers, [foreign]);
    assert.ok(outcomes[0].evidenceRefs.length > 0);
  } finally {await api.close();}
});

test('missing volume inventory cannot qualify cleanup as released', async t => {
  const {root, ctx, provider, resources} = await fixture(t);
  const api = await ownershipApi(root, () => [], () => ({}));
  try {
    Object.assign(provider, {engine: api.engine});
    await ctx.fiber.dispose().catch(() => {});
    const outcomes = await resources.verify(1000);
    assert.equal(outcomes[0].released, false);
    assert.match(outcomes[0].cleanupError!, /cleanup effects refused/);
    await assert.rejects(stat(join(root, 'effects')), {code: 'ENOENT'});
    const observed = JSON.parse(await readFile(join(provider.retainedOutput, 'engine-cleanup.json'), 'utf8'));
    assert.equal(observed.released, false);
    assert.ok(observed.observation.missing.includes('project.volumes'));
  } finally {await api.close();}
});

test('repeated identical export reuses retained regular files without replacing or rewriting them', async t => {
  const {provider} = await fixture(t);
  await nativeFiles(provider);
  const first = await provider.exportEvidence(AbortSignal.timeout(1000));
  const path = join(provider.retainedOutput, 'controller-result.json');
  const before = await lstat(path, {bigint: true});
  const repeated = await provider.exportEvidence(AbortSignal.timeout(1000));
  const after = await lstat(path, {bigint: true});
  assert.deepEqual(repeated, first);
  assert.equal(after.ino, before.ino);
  assert.equal(after.mtimeNs, before.mtimeNs);
  assert.equal(after.ctimeNs, before.ctimeNs);
});

test('different existing retained bytes refuse export without overwriting source or prior target', async t => {
  const {provider} = await fixture(t);
  const expected = await nativeFiles(provider);
  await mkdir(provider.retainedOutput, {recursive: true});
  const target = join(provider.retainedOutput, 'controller-result.json');
  await writeFile(target, 'prior retained bytes');
  const before = await lstat(target, {bigint: true});
  await assert.rejects(provider.exportEvidence(AbortSignal.timeout(1000)), /retained native bytes differ/);
  assert.equal(await readFile(target, 'utf8'), 'prior retained bytes');
  const after = await lstat(target, {bigint: true});
  assert.equal(after.ino, before.ino);
  assert.equal(after.mtimeNs, before.mtimeNs);
  assert.deepEqual(await readFile(join(provider.output, 'controller-result.json')), expected.get('controller-result.json'));
});

test('an existing retained symlink is refused even if its destination has identical bytes', async t => {
  const {root, provider} = await fixture(t);
  const expected = await nativeFiles(provider);
  await mkdir(provider.retainedOutput, {recursive: true});
  const prior = join(root, 'prior-file');
  await writeFile(prior, expected.get('controller-result.json')!);
  const target = join(provider.retainedOutput, 'controller-result.json');
  await symlink(prior, target);
  await assert.rejects(provider.exportEvidence(AbortSignal.timeout(1000)), /regular file/);
  assert.equal((await lstat(target)).isSymbolicLink(), true);
  assert.deepEqual(await readFile(prior), expected.get('controller-result.json'));
  assert.deepEqual(await readFile(join(provider.output, 'controller-result.json')), expected.get('controller-result.json'));
});
