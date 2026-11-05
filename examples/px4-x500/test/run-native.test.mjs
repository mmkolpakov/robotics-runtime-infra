import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {runNativeAttempt} from '../src/run-native.mjs';

async function fixture(t, failWorker = false) {
  const archiveRoot = await mkdtemp(join(tmpdir(), 'px4-native-unit-'));
  t.after(() => rm(archiveRoot, {recursive: true, force: true}));
  await mkdir(join(archiveRoot, 'capture'));
  const trustRoot = await mkdtemp(join(tmpdir(), 'px4-trust-unit-'));
  t.after(() => rm(trustRoot, {recursive: true, force: true}));
  await writeFile(join(trustRoot, 'profile.json'), '{}');
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
    issued:{profile_id:'profile',run_id:'run-1'},archiveRoot,sdkIds:{},
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
  assert.match(result.stderr,/requires an admitted SDK\/image composition/);
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
