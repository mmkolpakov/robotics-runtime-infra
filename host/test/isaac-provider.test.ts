import {test} from 'node:test';
import assert from 'node:assert/strict';
import {Context,Service,RunResources,Admission,RunOwner,RunStartupError} from '@robotics-runtime/host';
import type {JobRequest,JobResult} from '@robotics-runtime/host';
import {mkdtemp,rm,stat,mkdir,readFile,writeFile,copyFile,chmod} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash,randomUUID} from 'node:crypto';
import {fileURLToPath,pathToFileURL} from 'node:url';
import Inputs from '../src/plugins/isaac-provider/inputs.js';
import type {IsaacPlan} from '../src/plugins/isaac-provider/inputs.js';
import Isaac from '../src/plugins/isaac-provider/index.js';
import {observeIsaacHost,requireNativeIsaacHost} from '../src/plugins/isaac-provider/admission.js';

const plan=(outputDirectory='/retained/output/isaac/'+'a'.repeat(24)):IsaacPlan=>({
  runId:'fixture-owner',scope:'a'.repeat(24),
  compose:{executable:'/tools/compose',socketPath:'/tools/engine.sock',projectName:'rr-isaac-fixture',files:['/input/compose.yaml'],cwd:'/input'},
  inputVolume:'rr-isaac-input',resultVolume:'rr-isaac-results',outputDirectory,
  sourceRefs:[{uri:'file:///input/native-observe.py',sha256:'a'.repeat(64),size_bytes:1},{uri:'file:///input/fixture.usda',sha256:'0a19bca17a24a7d61bdef19dc410a220ef1ffe464f4e992a5c1cae7c52cbca29',size_bytes:1}],
  compatibilityCheckerRefs:[{uri:'file:///retained/native-checker.json',sha256:'b'.repeat(64),size_bytes:1}],
  steps:60,dtSeconds:1/60,renderFrames:0,width:640,height:480,deadlineMs:30000,
});
test('Isaac issuer freezes owner-bound inventory and refuses reused outputs and invalid bounds',async()=>{
  const ctx=new Context(),fiber=ctx.plugin(Inputs);await fiber.await();
  try {
    const issuer=ctx.get('isaacInputs');assert.ok(issuer);
    const value=plan(),token=issuer.issue(value);value.compose.files=['/changed'];
    assert.deepEqual(issuer.get(token,value.runId).compose.files,['/input/compose.yaml']);
    assert.ok(Object.isFrozen(issuer.get(token,value.runId).compose.files));
    assert.throws(()=>issuer.get(token,'foreign'),/not issued/);
    assert.throws(()=>issuer.issue(plan()),/already issued/);
    for(const deadlineMs of [0,-1,1.5,300001])assert.throws(()=>issuer.issue({...plan(),deadlineMs}),/deadline/);
    for(const steps of [0,1.5,10001])assert.throws(()=>issuer.issue({...plan(),steps}),/workload/);
    assert.throws(()=>issuer.issue({...plan(),compatibilityCheckerRefs:[]}),/checker evidence/);
  }finally{await fiber.dispose();await ctx.fiber.dispose()}
});
test('native Isaac profile refuses WSL and incomplete platform facts',()=>{
  const native={os:'linux',architecture:'x64',kernel:'6.8.0-generic',distribution:'ubuntu',release:'24.04'};
  requireNativeIsaacHost(native);
  for(const facts of [{...native,kernel:'6.6-microsoft-standard-WSL2'},{...native,os:'windows'},{...native,release:'22.04'},{...native,kernel:''}])assert.throws(()=>requireNativeIsaacHost(facts));
});
test('actual HOME admission refuses before any launch job or acquired resource',async t=>{
  const host=await observeIsaacHost();
  try{requireNativeIsaacHost(host);t.skip('negative environment check requires an unsupported actual host');return}catch{}
  const root=await mkdtemp(join(tmpdir(),'rr-isaac-refusal-')),output=join(root,'output/isaac','a'.repeat(24));
  const requests:JobRequest[]=[];
  class Recorder extends Service {
    constructor(ctx:Context){super(ctx,'jobs')}
    async run(request:JobRequest):Promise<JobResult>{requests.push(request);throw new Error('launch must not be called')}
  }
  const ctx=new Context();
  const jobs=ctx.plugin(Recorder),resources=ctx.plugin(RunResources,'fixture-owner'),inputs=ctx.plugin(Inputs);
  await Promise.all([jobs.await(),resources.await(),inputs.await()]);
  const token=ctx.isaacInputs.issue(plan(output)),config={token};
  const provider=ctx.plugin(Isaac,config);await provider.await();config.token='mutated-after-construction';
  try {
    await assert.rejects(ctx.get('isaac')!.ready(new AbortController().signal),/does not qualify WSL|requires native Ubuntu/);
    assert.equal(requests.length,0);assert.deepEqual(ctx.runResources.pending(),[]);
    await assert.rejects(stat(output),{code:'ENOENT'});
  }finally{
    await provider.dispose();await inputs.dispose();await resources.dispose();await jobs.dispose();await ctx.fiber.dispose();
    await rm(root,{recursive:true,force:true});
  }
});

test('native Admission and Include reject the unsupported HOME backend without launch or false ready',async t=>{
  const host=await observeIsaacHost();
  try{requireNativeIsaacHost(host);t.skip('negative gate requires an unsupported actual host');return}catch{}
  // Keep the copied immutable closure beneath the package so normal npm resolution stays native.
  const base=fileURLToPath(new URL('../../.tools/',import.meta.url));await mkdir(base,{recursive:true});
  const root=await mkdtemp(join(base,'isaac-admission-')),owner=randomUUID(),output=join(root,'output/isaac','a'.repeat(24));
  const ctx=new Context();let jobs=0;
  class Recorder extends Service {constructor(ctx:Context){super(ctx,'jobs')}async run():Promise<JobResult>{jobs++;throw new Error('unsupported host must not launch')}}
  const jobFiber=ctx.plugin(Recorder),inputFiber=ctx.plugin(Inputs);await Promise.all([jobFiber.await(),inputFiber.await()]);
  const token=ctx.isaacInputs.issue({...plan(output),runId:owner});
  const paths=['compose-execution.js','engine-metadata.js','plugins/isaac-provider/index.js','plugins/isaac-provider/inputs.js','plugins/isaac-provider/admission.js'];
  const immutable:{path:string;sha256:string}[]=[];
  for(const relative of paths){
    const source=fileURLToPath(new URL('../src/'+relative,import.meta.url)),target=join(root,'src',relative);
    await mkdir(join(target,'..'),{recursive:true});await copyFile(source,target);await chmod(target,0o444);
    immutable.push({path:target,sha256:createHash('sha256').update(await readFile(target)).digest('hex')});
  }
  const profile=join(root,'profile.json');
  await writeFile(profile,JSON.stringify([{id:'isaac-native',name:pathToFileURL(join(root,'src/plugins/isaac-provider/index.js')).href,config:{token}}]));
  await chmod(profile,0o444);
  immutable.push({path:profile,sha256:createHash('sha256').update(await readFile(profile)).digest('hex')});
  const admission=ctx.plugin(Admission,{profiles:[{id:'isaac-source-negative',profilePath:profile,files:immutable,
    requiredBindings:[{entryId:'isaac-native',service:'isaac'}],isolatedServices:['isaac'],deadlineMs:3000}]});
  const ownerFiber=ctx.plugin(RunOwner);await Promise.all([admission.await(),ownerFiber.await()]);
  try{
    await assert.rejects(ctx.runOwner.start('isaac-source-negative',owner),(error:unknown)=>{
      assert.ok(error instanceof RunStartupError,String(error));
      assert.match(error.message,/does not qualify WSL|requires native Ubuntu/);
      assert.notEqual(error.completion.status,'passed');
      assert.ok(!error.completion.phases.some(p=>p.phase==='ready'&&p.status==='passed'));
      assert.deepEqual(error.completion.resourceOutcomes,[]);return true;
    });
    assert.equal(jobs,0);await assert.rejects(stat(output),{code:'ENOENT'});
  }finally{
    await ownerFiber.dispose();await admission.dispose();await inputFiber.dispose();await jobFiber.dispose();await ctx.fiber.dispose();
    for(const file of [profile,...immutable.map(v=>v.path)])await chmod(file,0o644);
    await rm(root,{recursive:true,force:true});
  }
});
