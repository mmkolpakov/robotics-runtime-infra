import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,chmod,rm,readFile,symlink} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {referenceFile,type JobResult} from '@robotics-runtime/host';
import {createLocalAttempt,loadLocalAttempt,observeCoordinator,verifyAttemptInputs} from '../src/local-attempt.js';
const invocation='11'.repeat(16),unit='rr-attempt-11111111-1111-4111-8111-111111111111.service';
const value=(type:string,data:unknown)=>({type,data});
function jobs(state='active',changes:Record<string,unknown>={}){
 const result=(stdout:string):JobResult=>({ok:true,exitCode:0,signal:undefined,timedOut:false,canceled:false,stdout,stderr:'',diagnostic:undefined,code:undefined,durationMs:1});
 return {async run(request:{args?:readonly string[]}){
  const args=request.args??[];if(args.includes('GetUnit'))return result(JSON.stringify(value('o',['/fixed/unit'])));
  const properties=args.includes('org.freedesktop.systemd1.Unit')
   ?[value('s',unit),value('ay',Array(16).fill(17)),value('s','loaded'),value('s',state),value('s',state==='active'?'running':'failed')]
   :[value('t',30000000),value('t',2000000),value('s','control-group'),value('b',true),value('s','exec'),value('u',state==='active'?123:0),value('u',0),value('s','no')];
  if(!args.includes('org.freedesktop.systemd1.Unit'))for(const [index,data]of Object.entries(changes))properties[Number(index)]={...properties[Number(index)]!,data};
  return result(properties.map(row=>JSON.stringify(row)).join('\n'));
 }};
}
test('typed systemd invocation and finite lifetime proof refuses missing, restart and wrong ownership',async()=>{
 const expected={unit,invocationId:invocation};assert.equal((await observeCoordinator(jobs(),'/usr/bin/busctl',expected)).status,'active');
 assert.equal((await observeCoordinator(jobs('failed'),'/usr/bin/busctl',expected)).status,'quiescent');
 assert.equal((await observeCoordinator(jobs(),'/usr/bin/busctl',{...expected,invocationId:'22'.repeat(16)})).status,'unknown');
 for(const changes of [{0:18446744073709551615n.toString()},{0:600000001},{1:60000000},{2:'process'},{3:false},{4:'simple'},{7:'on-failure'}])assert.equal((await observeCoordinator(jobs('failed',changes),'/usr/bin/busctl',expected)).status,'unknown');
 const absent={async run(){return {...await jobs().run({args:[]}),ok:false,exitCode:1}}};
 assert.equal((await observeCoordinator(absent,'/usr/bin/busctl',expected)).status,'unknown');
});
test('private attempt records bind same-read bytes, remain immutable and refuse altered or symlinked controls',async t=>{
 const root=await mkdtemp(join(tmpdir(),'rr-local-attempt-'));t.after(()=>rm(root,{recursive:true,force:true}));
 const input=join(root,'compose.yaml');await writeFile(input,'services: {}\n');const source=await referenceFile(input);
 const path=join(root,'attempt.json');const ref=await createLocalAttempt(path,{runId:'run1',projectName:'owned-1',targetEnvironment:'simulation',coordinator:{unit,invocationId:invocation},admissionRefs:[source]},{jobs:jobs(),busctl:'/usr/bin/busctl'});
 const record=await loadLocalAttempt(ref);assert.equal(record.runId,'run1');assert.equal(record.coordinator.invocationId,invocation);assert.ok(Object.isFrozen(record));
 for(const mode of [0o644,0o444]){await chmod(path,mode);await assert.rejects(loadLocalAttempt(ref),/private immutable/)}await chmod(path,0o400);
 assert.equal((await readFile(path)).includes(Buffer.from('credentials')),false);
 await assert.rejects(createLocalAttempt(path,{runId:'run1',projectName:'owned-1',targetEnvironment:'simulation',coordinator:{unit,invocationId:invocation},admissionRefs:[source]},{jobs:jobs(),busctl:'/usr/bin/busctl'}),/EEXIST/);
 await writeFile(input,'changed');await assert.rejects(verifyAttemptInputs(record.admissionRefs),/changed/);
 await chmod(path,0o600);const raw=await readFile(path);const forged=Buffer.from(raw.toString().replace('owned-1','foreign'));await writeFile(path,forged);await chmod(path,0o400);
 await assert.rejects(loadLocalAttempt(ref),/identity/);
 await rm(path);await symlink(input,path);await assert.rejects(loadLocalAttempt(ref),/canonical/);
 const valid={...ref,sha256:createHash('sha256').update(raw).digest('hex'),uri:pathToFileURL(path).href};await assert.rejects(loadLocalAttempt(valid));
});
