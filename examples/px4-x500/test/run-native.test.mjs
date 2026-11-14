import test from 'node:test';
import assert from 'node:assert/strict';
import {chmod, copyFile, mkdtemp, mkdir, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {runNativeAttempt, launchNative} from '../src/run-native.mjs';

const identities = {source_system_id: 245, source_component_id: 190, target_system_id: 1, target_component_id: 1};

async function fixture(t, failWorker = false) {
  const archiveRoot = await mkdtemp(join(tmpdir(), 'px4-native-unit-'));
  t.after(() => rm(archiveRoot, {recursive: true, force: true}));
  await mkdir(join(archiveRoot, 'capture'));
  const trustRoot = await mkdtemp(join(tmpdir(), 'px4-trust-unit-'));
  t.after(() => rm(trustRoot, {recursive: true, force: true}));
  await writeFile(join(trustRoot, 'profile.json'), '{}', {mode: 0o600});
  await writeFile(join(archiveRoot, 'capture/controller-manifest.json'), JSON.stringify({
    started_unix_ns:'1793708634567111000', finished_unix_ns:'1793708634567464000',
  }));
  const calls = [];
  const px4 = {
    config:{mode:'native-sdk-v2', archiveRoot},
    async startNativeLogger(){calls.push('logger-on')},
    async executeNative(){calls.push('worker');if(failWorker)throw new Error('unknown worker')},
    async closeNativeMeasurement(){calls.push('close');if(failWorker)throw new Error('unsettled');await px4.drainRecorders()},
    async captureLastState(){calls.push('last-state')},
    async drainRecorders(){calls.push('drain')},
    async exportEvidence(){calls.push('export')},
  };
  let drained = false;
  px4.drainRecorders = async () => {if (!drained) {calls.push('drain');drained = true}};
  const run = {
    context:{get:()=>px4}, beginMeasurement(){calls.push('measurement')},
    async finish(hooks){
      calls.push('finish');
      try {
        for (const name of ['closeMeasurement','captureLastState','drainRecorders','exportEvidence']) {
          await hooks[name](new AbortController().signal);
        }
        return {status:'passed',phases:[{phase:'exporting-evidence',status:'passed'}]};
      } catch {return {status:'incomplete'}}
    },
  };
  const owner = {async start(){calls.push('start');return run}};
  const jobs = {async run(job){calls.push(job);return {ok:true,exitCode:0}}};
  return {calls,px4,args:{owner,jobs,caseName:'land',
    issued:{profile_id:'profile',run_id:'run-1'},archiveRoot,sdkIds:{...identities},
    producerPython:'/usr/bin/python3',producerPath:'/opt/producer.py',
    harnessExecutable:'/usr/bin/robotics-acceptance',evaluatorTrust:{profile:join(trustRoot,'profile.json'),
      receipts:['/trust/receipt.json'],verifications:['/trust/verification.json'],dependencies:['/trust/dependency.json']},
    signal:new AbortController().signal}};
}

test('owner calls worker, drains before pause, then runs public producer and evaluator', async t => {
  const {args,calls} = await fixture(t);
  const result = await runNativeAttempt(args);
  assert.equal(result.completion.status,'passed');
  assert.deepEqual(calls.slice(0,8),['start','logger-on','measurement','worker','finish','close','drain','last-state']);
  assert.equal(calls[8],'export');
  assert.deepEqual(calls[9].args.slice(0,3),['-B','/opt/producer.py','complete']);
  assert.equal(calls[10].args[0],'evaluate');
  assert.equal(calls[10].args[calls[10].args.indexOf('--window-start-ns')+1],'1793708634567111000');
  assert.equal(calls[10].args[calls[10].args.indexOf('--window-end-ns')+1],'1793708634567464000');
  for(const [flag,value] of [['--evaluator-receipt','/trust/receipt.json'],
    ['--evaluator-verification','/trust/verification.json'],['--evaluator-receipt-dependency','/trust/dependency.json']]){
    assert.equal(calls[10].args[calls[10].args.indexOf(flag)+1],value);
  }
  assert.ok(calls[10].args.includes('--evaluator-trust-profile'));
});

test('unsettled worker returns incomplete without export or assessment', async t => {
  const {args,calls} = await fixture(t,true);
  const result = await runNativeAttempt(args);
  assert.equal(result.completion.status,'incomplete');
  assert.ok(!calls.includes('export'));
  assert.equal(calls.filter(v=>typeof v==='object').length,0);
});

test('direct CLI refuses before native launch', () => {
  const path=fileURLToPath(new URL('../src/run-native.mjs',import.meta.url));
  const result=spawnSync(process.execPath,[path],{encoding:'utf8'});
  assert.notEqual(result.status,0);
  assert.match(result.stderr,/unsupported native case/);
});


test('missing or evidence-contained evaluator trust refuses before owner start',async t=>{
  const {args,calls}=await fixture(t);
  args.evaluatorTrust.receipts=[];
  await assert.rejects(runNativeAttempt(args),/evaluator trust paths/);
  assert.equal(calls.length,0);
  args.evaluatorTrust.receipts=['/trust/receipt.json'];
  args.evaluatorTrust.profile=join(args.archiveRoot,'capture','controller-manifest.json');
  await assert.rejects(runNativeAttempt(args),/outside the evidence archive/);
  assert.equal(calls.length,0);
});

async function launchFixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'px4-bootstrap-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const archive = join(root, 'archive'), trusted = join(root, 'trusted');
  await mkdir(join(archive, 'inputs'), {recursive: true});
  await mkdir(trusted, {mode: 0o700});
  const operatorPath = join(trusted, 'operator.json'), profilePath = join(trusted, 'cordis.json');
  const compose = join(trusted, 'compose.yaml'), module = join(trusted, 'px4.mjs');
  await writeFile(compose, 'services: {}'); await writeFile(module, 'export default () => {};');
  const config = {mode: 'native-sdk-v2', archiveRoot: archive, initSha256: '1'.repeat(64), composeFiles: [compose]};
  await writeFile(profilePath, JSON.stringify([{id: 'px4', name: module, config}]));
  await chmod(profilePath, 0o400);
  const trust = join(trusted, 'trust.json'); await writeFile(trust, '{}', {mode: 0o600});
  const operator = {archiveRoot: archive, sdkIds: {...identities}, profile: {id: 'source-sdk', profilePath,
    files: [profilePath, module, compose].map(path => ({path, sha256: '2'.repeat(64)})),
    requiredBindings: [{entryId: 'px4', service: 'px4'}], isolatedServices: ['px4']},
    producerPython: '/usr/bin/python3', producerPath: '/opt/producer.py', harnessExecutable: '/usr/bin/harness',
    evaluatorTrust: {profile: trust, receipts: ['/trust/receipt'], verifications: ['/trust/verification'], dependencies: []}};
  const inputPath = join(archive, 'inputs', 'pre-run-inputs.json');
  await writeFile(inputPath, JSON.stringify({domain_id: 'px4', run_id: 'issued'}));
  const save = () => writeFile(operatorPath, JSON.stringify(operator), {mode: 0o600}); await save();
  return {operator, operatorPath, inputPath, profilePath, compose, save};
}

test('unsealed Compose input refuses before loading host or starting an owner', async t => {
  const f = await launchFixture(t); f.operator.profile.files.pop(); await f.save();
  let loaded = false;
  await assert.rejects(launchNative(['land', f.operatorPath, f.inputPath], async () => {loaded = true}), /every Compose/);
  assert.equal(loaded, false);
});

test('writable or archive-contained bootstrap profile refuses before host effects', async t => {
  const f = await launchFixture(t);
  await chmod(f.profilePath, 0o600);
  await assert.rejects(launchNative(['land', f.operatorPath, f.inputPath]), /read-only/);
  f.operator.profile.profilePath = f.inputPath; await f.save();
  await assert.rejects(launchNative(['land', f.operatorPath, f.inputPath]), /outside the evidence archive/);
});

test('Context disposal is awaited after plugin and owner failures', async t => {
  for (const failure of ['jobs', 'owner']) {
    const f = await launchFixture(t); const calls = [];
    const Jobs = Symbol('jobs'), Admission = Symbol('admission'), RunOwner = Symbol('owner');
    class Context {
      fiber = {dispose: async () => {await Promise.resolve(); calls.push('disposed')}};
      admission = {admit: async () => {calls.push('admission'); if (failure === 'admission') throw new Error('admission refused')}};
      runOwner = {start: async () => {calls.push('owner'); throw new Error('owner refused')}};
      async plugin(plugin) {if (plugin === Jobs && failure === 'jobs') throw new Error('jobs refused')}
    }
    await assert.rejects(launchNative(['land', f.operatorPath, f.inputPath], async () => ({Context, Jobs, Admission, RunOwner})), /refused|absolute native/);
    assert.equal(calls.at(-1), 'disposed');
    if (failure === 'jobs') assert.ok(!calls.includes('owner'));
  }
});


test('structurally equal reordered binding reaches the owner and awaits Context disposal', async t => {
  const f = await launchFixture(t), calls = [];
  f.operator.profile.requiredBindings = [{service: 'px4', entryId: 'px4'}];
  f.operator.profile.isolatedServices = []; await f.save();
  const Jobs = Symbol('jobs'), Admission = Symbol('admission'), RunOwner = Symbol('owner');
  class Context {
    fiber = {dispose: async () => {await Promise.resolve(); calls.push('disposed')}};
    runOwner = {start: async () => {calls.push('owner'); return {
      context: {get: () => ({config: {mode: 'native-sdk-v2', archiveRoot: f.operator.archiveRoot},
        startNativeLogger: async () => {throw new Error('software control stops before measurement')}})},
      finish: async () => ({status: 'incomplete'}),
    }}};
    async plugin() {}
  }
  const result = await launchNative(['land', f.operatorPath, f.inputPath], async () => ({Context, Jobs, Admission, RunOwner}));
  assert.equal(result.completion.status, 'incomplete');
  assert.deepEqual(calls, ['owner', 'disposed']);
});


test('public Admission rejects changed Compose bytes before importing the provider', async t => {
  const f = await launchFixture(t);
  const module = f.operator.profile.files[1].path;
  await writeFile(module, "throw new Error('provider must not import');\n");
  for (const file of f.operator.profile.files) {
    file.sha256 = createHash('sha256').update(await readFile(file.path)).digest('hex');
    await chmod(file.path, 0o444);
  }
  await f.save();
  await chmod(f.compose, 0o644); await writeFile(f.compose, 'services: {foreign: {}}'); await chmod(f.compose, 0o444);
  const host = await import('@robotics-runtime/host'), contexts = [];
  let disposed = false;
  class ObservedContext {
    constructor() {
      const ctx = new host.Context(), dispose = ctx.fiber.dispose.bind(ctx.fiber);
      ctx.fiber.dispose = async () => {await dispose(); await Promise.resolve(); disposed = true};
      contexts.push(ctx); return ctx;
    }
  }
  await assert.rejects(launchNative(['land', f.operatorPath, f.inputPath], async () => ({...host, Context: ObservedContext})), /hash|digest|SHA/);
  assert.equal(contexts.length, 1);
  assert.equal(disposed, true);
});


test('launch and disposal errors both survive and signal handlers are removed', async t => {
  const f = await launchFixture(t), primary = new Error('plugin refused'), cleanup = new Error('disposal refused');
  const before = ['SIGINT', 'SIGTERM'].map(signal => process.listenerCount(signal));
  class Context {
    fiber = {dispose: async () => {throw cleanup}};
    async plugin() {throw primary}
  }
  await assert.rejects(launchNative(['land', f.operatorPath, f.inputPath], async () => ({Context})), error => {
    assert.ok(error instanceof AggregateError); assert.deepEqual(error.errors, [primary, cleanup]);
    assert.equal(error.cause, primary); return true;
  });
  assert.deepEqual(['SIGINT', 'SIGTERM'].map(signal => process.listenerCount(signal)), before);
});


test('missing or malformed SDK IDs refuse before owner, logger or measurement', async t => {
  const {args, calls} = await fixture(t);
  for (const ids of [undefined, null, {}, {...identities, source_system_id: 0},
    {...identities, source_component_id: 256}, {...identities, target_system_id: 1.5},
    {...identities, target_component_id: '1'}, {...identities, extra: 1}]) {
    args.sdkIds = ids;
    await assert.rejects(runNativeAttempt(args), /^Error: explicit SDK identities required$/);
    assert.deepEqual(calls, []);
  }
});

test('SDK IDs are captured before asynchronous owner startup', async t => {
  const {args, px4} = await fixture(t), start = args.owner.start;
  let observed;
  px4.executeNative = async (_case, ids) => {observed = ids};
  args.owner.start = async (...values) => {args.sdkIds.source_system_id = 0; return start(...values)};
  await runNativeAttempt(args);
  assert.deepEqual(observed, identities);
});


test('CLI serializes the actual public startup completion without exposing its run context', async t => {
  const f = await launchFixture(t), module = f.operator.profile.files[1].path;
  await writeFile(module, `export default (ctx, config) => {
    ctx.provide('px4', {config, async ready() {throw new Error('software readiness refusal')}});
  };\n`);
  for (const file of f.operator.profile.files) {
    file.sha256 = createHash('sha256').update(await readFile(file.path)).digest('hex');
    await chmod(file.path, 0o444);
  }
  await f.save();
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('../src/run-native.mjs', import.meta.url)),
    'land', f.operatorPath, f.inputPath], {encoding: 'utf8', timeout: 10000});
  assert.equal(result.error, undefined);
  assert.notEqual(result.status, 0);
  const receipt = JSON.parse(result.stdout);
  assert.equal(receipt.startupError, 'software readiness refusal');
  assert.equal(receipt.completion.runId, 'issued');
  assert.notEqual(receipt.completion.status, 'passed');
  assert.ok(receipt.completion.phases.some(phase => phase.phase === 'preloading' && phase.status === 'error'));
  assert.equal(Object.hasOwn(receipt, 'run'), false);
  assert.equal(Object.hasOwn(receipt, 'evaluation'), false);
});


test('isolated CLI without the optional host SDK preserves its argument error', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'px4-cli-no-sdk-'));
  t.after(() => rm(directory, {recursive: true, force: true}));
  for (const name of ['run-native.mjs', 'operator-input.mjs']) {
    await copyFile(new URL('../src/' + name, import.meta.url), join(directory, name));
  }
  const result = spawnSync(process.execPath, [join(directory, 'run-native.mjs')], {encoding: 'utf8', timeout: 5000});
  assert.equal(result.error, undefined);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unsupported native case/);
  assert.doesNotMatch(result.stderr, /ERR_MODULE_NOT_FOUND/);
  assert.equal(result.stdout, '');
});
