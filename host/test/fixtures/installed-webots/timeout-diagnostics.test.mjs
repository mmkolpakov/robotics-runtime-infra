import assert from 'node:assert/strict';
import test from 'node:test';
import {constants} from 'node:fs';
import {mkdtemp,mkdir,writeFile,readFile,readdir,copyFile,rm,chmod} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';
import {randomUUID} from 'node:crypto';
import {Context,Admission,RunOwner,referenceFile,isDisposed} from '@robotics-runtime/host';
import {readNativeTimeoutDiagnostics} from './timeout-diagnostics.mjs';

const json=async(path,value)=>writeFile(path,JSON.stringify(value,null,2)+'\n');
const fixture=async t=>{
 const root=await mkdtemp(join(tmpdir(),'rr-webots-timeout-'));t.after(()=>rm(root,{recursive:true,force:true}));
 const source=join(root,'source');await mkdir(source);
 const ownerId=randomUUID();
 const worker={owner_id:ownerId,status:'canceled',diagnostic:'InterruptedError: finite worker canceled or deadline exceeded',evidence_exported_before_stop:false,processes_reaped:true,
  children:[{name:'controller',pid:57,registered_pgid:57,exit_code:-15,reaped:true,group_absent:true},{name:'webots',pid:56,registered_pgid:56,exit_code:0,reaped:true,group_absent:true},{name:'xvfb',pid:3,registered_pgid:3,exit_code:0,reaped:true,group_absent:true}]};
 await json(join(source,'worker-result.json'),worker);await writeFile(join(source,'cancel'),'worker deadline');
 return {root,source,ownerId,worker,read:()=>readNativeTimeoutDiagnostics(source,ownerId)};
};
const bytes=async root=>Object.fromEntries(await Promise.all((await readdir(root)).map(async name=>[name,(await readFile(join(root,name))).toString('hex')])));
const controller=(ownerId,state)=>({owner_id:ownerId,status:'canceled',diagnostic:'InterruptedError: measurement canceled before opening',samples:[],last_native_state:state});
const state={time_seconds:0,body_position_m:[0,0,1]};

test('deadline with absent controller and final state retains the actual missing-payload facts',async t=>{
 const f=await fixture(t),before=await bytes(f.source),facts=await f.read();
 assert.deepEqual(facts.controller,{available:false});assert.deepEqual(facts.lastState,{available:false});
 assert.equal(facts.worker.evidence_exported_before_stop,false);assert.equal(facts.marker,'worker deadline');
 assert.deepEqual(await bytes(f.source),before);
});
test('supplied canceled payloads stay bound to their actual owner and bytes',async t=>{
 const f=await fixture(t);
 await json(join(f.source,'controller-result.json'),controller(f.ownerId,state));await json(join(f.source,'last-native-state.json'),state);
 f.worker.evidence_exported_before_stop=true;f.worker.controller_result_ref=await referenceFile(join(f.source,'controller-result.json'));
 await json(join(f.source,'worker-result.json'),f.worker);
 const before=await bytes(f.source),facts=await f.read();
 assert.equal(facts.controller.available,true);assert.deepEqual(facts.lastState.value,state);assert.deepEqual(await bytes(f.source),before);
});
test('malformed or contradictory optional payloads do not become absent diagnostics',async t=>{
 const f=await fixture(t),p=join(f.source,'controller-result.json');
 for(const raw of ['{','null',JSON.stringify(controller('foreign',state)),JSON.stringify({...controller(f.ownerId,state),status:'completed'}),JSON.stringify({...controller(f.ownerId,state),samples:[{}]})]){
  await writeFile(p,raw);await assert.rejects(f.read);
 }
 await json(p,controller(f.ownerId,state));
 const last=join(f.source,'last-native-state.json');
 for(const raw of ['{','null',JSON.stringify({...state,time_seconds:-1}),JSON.stringify({...state,time_seconds:1})]){
  await writeFile(last,raw);await assert.rejects(f.read);
 }
});
test('natural deadline requires its exact marker, absent measurement and settled registered groups',async t=>{
 const f=await fixture(t);
 await writeFile(join(f.source,'cancel'),'owner canceled');await assert.rejects(f.read,/natural deadline/);
 await writeFile(join(f.source,'cancel'),'worker deadline');
 for(const name of ['measure','measurement.json']){
  await writeFile(join(f.source,name),'{}');await assert.rejects(f.read,/must remain absent/);await rm(join(f.source,name));
 }
 for(const change of [
  w=>{w.owner_id='foreign'},w=>{w.status='completed'},w=>{w.processes_reaped=false},
  w=>{w.children[0].group_absent=false},w=>{w.children[0].reaped=false},
  w=>{w.children[0].registered_pgid=999},w=>{w.children.pop()},
 ]){
  const changed=structuredClone(f.worker);change(changed);await json(join(f.source,'worker-result.json'),changed);await assert.rejects(f.read);
 }
});
test('claimed successful payload export requires the controller reference and matching bytes',async t=>{
 const f=await fixture(t);f.worker.evidence_exported_before_stop=true;await json(join(f.source,'worker-result.json'),f.worker);
 await assert.rejects(f.read);
 await json(join(f.source,'controller-result.json'),controller(f.ownerId,state));await assert.rejects(f.read);
 f.worker.controller_result_ref=await referenceFile(join(f.source,'controller-result.json'));f.worker.controller_result_ref.sha256='0'.repeat(64);
 await json(join(f.source,'worker-result.json'),f.worker);await assert.rejects(f.read);
});

const ownedRun=async(f,t)=>{
 const host=import.meta.resolve('@robotics-runtime/host');
 const plugin=join(f.root,'resource.mjs'),profile=join(f.root,'profile.json'),owned=join(f.root,'owned'),cleanup=join(f.root,'cleanup.json'),ready=join(f.root,'ready.json');
 await writeFile(owned,'owned unit resource');await json(ready,{ownerId:f.ownerId,localResourceAcquired:true});
 await writeFile(plugin,`import {Service,referenceFile} from ${JSON.stringify(host)};
import {writeFile,rm,stat} from 'node:fs/promises';
export default class Resource extends Service {
 static inject=['runResources'];
 constructor(ctx,config){super(ctx,'timeoutFixture');this.config=config;const ownerId=ctx.runResources.ownerId;ctx.runResources.track({
 id:'local-unit-resource',ownerId,
 cleanup:async()=>{await rm(config.owned);await writeFile(config.cleanup,JSON.stringify({ownerId,released:true}));},
 verifyCleanup:async()=>{let absent=false;try{await stat(config.owned)}catch(error){if(error.code!=='ENOENT')throw error;absent=true}return {released:absent,evidenceRefs:[await referenceFile(config.cleanup)]};}
 });}
 async ready(){return {ready:true,evidenceRefs:[await referenceFile(this.config.ready)]};}
}
`);
 await json(profile,[{id:'fixture',name:pathToFileURL(plugin).href,config:{owned,cleanup,ready}}]);
 await Promise.all([plugin,profile].map(path=>chmod(path,0o444)));
 const files=await Promise.all([plugin,profile].map(async path=>({path,sha256:(await referenceFile(path)).sha256})));
 const ctx=new Context();
 await ctx.plugin(Admission,{profiles:[{id:'unit-timeout',profilePath:profile,files,requiredBindings:[{entryId:'fixture',service:'timeoutFixture'}],isolatedServices:['timeoutFixture'],deadlineMs:30000}]}).await();
 await ctx.plugin(RunOwner).await();
 const run=await ctx.runOwner.start('unit-timeout',f.ownerId);run.beginMeasurement();
 t.after(async()=>{
  if(run.phase==='retained')await run.retryExport(async()=>[await referenceFile(join(f.source,'worker-result.json'))]);
  await ctx.fiber.dispose();
 });
 return {ctx,run,owned,cleanup};
};
const hooksFor=(f,retained)=>{
 let facts,settled=false;
 return {
  closeMeasurement:async()=>{facts=await f.read();throw new Error('observed native worker deadline: '+facts.worker.diagnostic)},
  captureLastState:async()=>{assert.ok(facts);const p=join(retained,'state-availability.json');await json(p,{available:facts.lastState.available,scope:'no READY state promoted to final state'});return [await referenceFile(p)]},
  drainRecorders:async()=>{assert.ok(facts);assert.equal(facts.worker.processes_reaped,true);settled=true;return [await referenceFile(join(f.source,'worker-result.json'))]},
  exportEvidence:async()=>{assert.equal(settled,true);const refs=[];for(const name of await readdir(f.source)){const p=join(retained,name);await copyFile(join(f.source,name),p,constants.COPYFILE_EXCL);refs.push(await referenceFile(p))}return refs},
 };
};
test('public RunOwner.finish returns error and verifies cleanup after available-only diagnostic export',async t=>{
 const f=await fixture(t),o=await ownedRun(f,t),retained=join(f.root,'retained');await mkdir(retained);
 const before=await bytes(f.source),completion=await o.run.finish(hooksFor(f,retained));
 assert.equal(completion.status,'error');assert.ok(completion.errors.some(value=>value.includes('observed native worker deadline')));
 assert.ok(completion.resourceOutcomes.every(row=>row.attempted&&row.released&&row.evidenceRefs.length&&!row.cleanupError));
 assert.ok(isDisposed(o.run.fiber));await assert.rejects(readFile(o.owned),{code:'ENOENT'});
 for(const name of ['controller-result.json','last-native-state.json','measurement.json'])await assert.rejects(readFile(join(retained,name)),{code:'ENOENT'});
 assert.equal(JSON.parse(await readFile(join(retained,'worker-result.json'),'utf8')).evidence_exported_before_stop,false);
 assert.deepEqual(await bytes(f.source),before);
});
test('public RunOwner.finish retains incomplete export without performing owned cleanup',async t=>{
 const f=await fixture(t),o=await ownedRun(f,t),retained=join(f.root,'retained');await mkdir(retained);
 await writeFile(join(retained,'cancel'),'existing destination is protected');
 const before=await bytes(f.source),completion=await o.run.finish(hooksFor(f,retained));
 assert.equal(completion.status,'incomplete');assert.ok(completion.resourceOutcomes.every(row=>!row.attempted&&!row.released));
 assert.equal(await readFile(o.owned,'utf8'),'owned unit resource');await assert.rejects(readFile(o.cleanup),{code:'ENOENT'});
 assert.equal(await readFile(join(retained,'cancel'),'utf8'),'existing destination is protected');assert.deepEqual(await bytes(f.source),before);
});
test('public RunOwner.finish cannot clean up after malformed optional native bytes',async t=>{
 const f=await fixture(t),o=await ownedRun(f,t),retained=join(f.root,'retained');await mkdir(retained);
 await writeFile(join(f.source,'controller-result.json'),'{');
 const before=await bytes(f.source),completion=await o.run.finish(hooksFor(f,retained));
 assert.equal(completion.status,'incomplete');assert.ok(completion.resourceOutcomes.every(row=>!row.attempted&&!row.released));
 assert.equal(await readFile(o.owned,'utf8'),'owned unit resource');assert.deepEqual(await bytes(f.source),before);
});
