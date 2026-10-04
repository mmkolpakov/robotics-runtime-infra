import assert from 'node:assert/strict';
import {test} from 'node:test';
import {ComposeExecution, selectApi, validateObservation, type FiniteJobRequest, type FiniteJobResult, type ContainerRequirement} from '../src/index.js';
const result: FiniteJobResult = {ok: true, exitCode: 0, signal: undefined, timedOut: false, canceled: false, stdout: '5.3.1\n', stderr: '', diagnostic: undefined, code: undefined, durationMs: 1};

test('Compose delegates finite argv and fixes the same Unix endpoint without inherited engine context', async () => {
  let observed: FiniteJobRequest | undefined;
  const compose = new ComposeExecution({run: async r => {observed = r; return result}}, {executable: '/usr/local/bin/docker-compose', socketPath: '/run/engine.sock', projectName: 'owned-1', files: ['/immutable/compose.yaml'], cwd: '/immutable', env: {ROBOTICS_RUN_ID: 'run1'}});
  await compose.requireVersion();
  assert.deepEqual(observed?.args, ['--project-name', 'owned-1', '--file', '/immutable/compose.yaml', 'version', '--short']);
  assert.equal(observed?.env?.DOCKER_HOST, 'unix:///run/engine.sock');
  assert.equal(observed?.extendEnv, false);
  for (const replacement of ['--project-name=other', '-pother', '-fother', '--context=other']) await assert.rejects(compose.run(['down', replacement]));
  const abort = new AbortController();
  await compose.run(['run', '--no-deps', 'contracts'], abort.signal);
  assert.equal(observed?.cancelSignal, abort.signal);
});

test('metadata API selection is explicit and rejects missing or disjoint ranges', () => {
  const endpoint = {socketPath: '/run/engine.sock', clientMinApi: '1.24', clientMaxApi: '1.53'};
  assert.equal(selectApi({ApiVersion: '1.41', MinAPIVersion: '1.24'}, endpoint).clientApi, '1.41');
  assert.throws(() => selectApi({ApiVersion: '1.41'}, endpoint), /incomplete/);
  assert.throws(() => selectApi({ApiVersion: '1.23', MinAPIVersion: '1.20'}, endpoint), /do not overlap/);
});
const facts = selectApi({ApiVersion: '1.41', MinAPIVersion: '1.24'}, {socketPath: '/run/engine.sock', clientMinApi: '1.24', clientMaxApi: '1.53'});
const required: ContainerRequirement = {runId: 'run1', projectName: 'owned-1', user: '10001:1000', imageDigest: 'repo@sha256:abc', mounts: [{destination: '/run/robotics/input', readOnly: true, volumeName: 'owned-input'}], hostConfig: {Memory: 268435456, ReadonlyRootfs: true}};
function native() {
  return {Id: 'c'.repeat(64), Image: 'sha256:image', Config: {User: '10001:1000', Labels: {'org.robotics.runtime.run-id': 'run1', 'com.docker.compose.project': 'owned-1'}}, State: {Status: 'exited', Running: false, ExitCode: 0}, Mounts: [{Type: 'volume', Name: 'owned-input', Destination: '/run/robotics/input', RW: false}], HostConfig: {Memory: 268435456, ReadonlyRootfs: true, NetworkMode: 'none'}, NetworkSettings: {Networks: {}}};
}
const image = {Id: 'sha256:image', RepoDigests: ['repo@sha256:abc']};
test('native metadata requires every used resource field and never substitutes expected declarations', () => {
  assert.equal(validateObservation(facts, native(), image, [], required).status, 'complete');
  const raw = native();
  delete (raw.HostConfig as Partial<typeof raw.HostConfig>).Memory;
  const missing = validateObservation(facts, raw, image, [], required);
  assert.equal(missing.status, 'incomplete');
  assert.ok(missing.missing.includes('container.HostConfig.Memory'));
  raw.Mounts[0]!.RW = true;
  assert.ok(validateObservation(facts, raw, image, [], required).mismatches.includes('mount./run/robotics/input.RW'));
  raw.Config.Labels['org.robotics.runtime.run-id'] = 'other';
  assert.ok(validateObservation(facts, raw, image, [], required).mismatches.includes('owner.run-id'));
  assert.equal(validateObservation(facts, {}, {}, [], required).status, 'incomplete');
});

test('native networks require inspected identity, and released digest is independently bound', () => {
  const c = native();
  c.HostConfig.NetworkMode = 'owned-1_default';
  (c.NetworkSettings.Networks as Record<string, unknown>).n = {NetworkID: 'network-id'};
  assert.ok(validateObservation(facts, c, image, [], required).missing.includes('network.n.inspect'));
  assert.equal(validateObservation(facts, c, image, [{Id: 'network-id'}], required).status, 'complete');
  assert.ok(validateObservation(facts, c, {Id: 'sha256:image', RepoDigests: ['other']}, [{Id: 'network-id'}], required).mismatches.includes('image.released-digest'));
});

test('a declared namespace cannot replace differing projected metadata', () => {
  const c = native();
  (c.HostConfig as Record<string,unknown>).UsernsMode = 'private';
  const observed=validateObservation(facts,c,image,[],{...required,hostConfig:{...required.hostConfig,UsernsMode:'keep-id:uid=1000,gid=1000'}});
  assert.equal(observed.status,'incomplete');
  assert.ok(observed.mismatches.includes('container.HostConfig.UsernsMode'));
});

test('the immutable profile also participates in teardown', async () => {
  const requests: FiniteJobRequest[]=[];
  const compose=new ComposeExecution({run:async r=>{requests.push(r);return result}},{executable:'/usr/local/bin/docker-compose',socketPath:'/run/engine.sock',projectName:'owned-1',files:['/immutable/compose.yaml'],profiles:['host-preflight'],cwd:'/immutable'});
  await compose.run(['up','--detach','host-image']);
  await compose.run(['down','--volumes']);
  assert.ok(requests.every(r=>r.args.join(' ').includes('--profile host-preflight')));
  await assert.rejects(compose.run(['down','--profile','other']));
});
