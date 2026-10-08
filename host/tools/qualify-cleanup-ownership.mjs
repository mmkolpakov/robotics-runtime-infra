import assert from 'node:assert/strict';
import {Context,Jobs} from '@robotics-runtime/host';
import {ComposeExecution,EngineMetadata} from '../dist/src/index.js';
import {mkdir,writeFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
const [root,socket,image,output]=process.argv.slice(2);await mkdir(output,{recursive:true});
const runId='run-'+randomUUID(),foreignFixtureRun='run-'+randomUUID(),sentinelRun='run-'+randomUUID();
const projectName='rr-cleanup-'+randomUUID().slice(0,8),sentinelProject=projectName+'-sentinel';
const ctx=new Context(),jobs=ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:4194304});await jobs.await();
const options={executable:root+'/host/.tools/docker-compose',socketPath:socket,projectName,files:[root+'/host/test/fixtures/cleanup-ownership/compose.yaml'],cwd:root,env:{ROBOTICS_RUN_ID:runId,SOURCE_METADATA_IMAGE:image}};
const compose=new ComposeExecution(ctx.jobs,options),sentinel=new ComposeExecution(ctx.jobs,{...options,projectName:sentinelProject,env:{...options.env,ROBOTICS_RUN_ID:sentinelRun}});
let sequence=0,parentId,passed=false,failure;
const save=async(name,value)=>{await writeFile(output+'/'+String(++sequence).padStart(4,'0')+'-'+name+'.json',JSON.stringify(value,null,2)+'\n');return value};
const finite=async(name,args,executor=compose)=>{const result=await save(name,await executor.run(args));if(!result.ok)throw new Error(name+': '+result.diagnostic);return result};
const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
const owner=()=>({runId,projectName,...(parentId?{networkNamespaceContainerId:parentId}:{})});
const guardedDown=async(name,requested,executor)=>{const observed=await save(name+'-before',await engine.projectOwnership(requested));if(observed.status!=='complete')throw new Error('foreign or unbound project resource');await finite(name,['down','--volumes','--remove-orphans'],executor);const after=await save(name+'-after',await engine.projectOwnership(requested));assert.equal(after.status,'complete');assert.equal(after.inventory.containers.length,0);assert.equal(after.inventory.networks.length,0);assert.ok(after.inventory.volumes.Volumes===null||after.inventory.volumes.Volumes?.length===0);return after};
try {
 await compose.requireVersion();await finite('parent-up',['up','--detach','--no-build','--wait','parent']);parentId=(await finite('parent-id',['ps','--quiet','parent'])).stdout.trim();assert.match(parentId,/^[a-f0-9]{64}$/);
 const childId=(await finite('oneoff-create',['run','--detach','--no-deps','child','-c','sleep 1'])).stdout.trim();assert.match(childId,/^[a-f0-9]{64}$/);
 let initial;const exitDeadline=Date.now()+10000;
 do{initial=await engine.projectOwnership(owner());const child=initial.containerDetails.find(c=>c.Id===childId);if(child?.State?.Status==='exited'&&child.State.ExitCode===0)break;await new Promise(resolve=>setTimeout(resolve,50))}while(Date.now()<exitDeadline);
 await save('oneoff-exited',initial);assert.equal(initial.status,'complete');assert.equal(initial.containerDetails.find(c=>c.Id===childId)?.State?.ExitCode,0);assert.equal(initial.containerDetails.find(c=>c.Id===childId)?.State?.Running,false);
 const wrongParent=await save('namespace-negative',await engine.projectOwnership({...owner(),networkNamespaceContainerId:'f'.repeat(64)}));assert.equal(wrongParent.status,'incomplete');assert.ok(wrongParent.mismatches.some(x=>x.endsWith('namespace.expected-id')));
 const foreignId=(await finite('foreign-fixture-create',['run','--detach','--rm','--no-deps','--label','org.robotics.runtime.run-id='+foreignFixtureRun,'child','-c','sleep 20'])).stdout.trim();assert.match(foreignId,/^[a-f0-9]{64}$/);
 const poisoned=await save('foreign-fixture-before',await engine.projectOwnership(owner()));assert.equal(poisoned.status,'incomplete');assert.ok(poisoned.mismatches.some(x=>x.endsWith('org.robotics.runtime.run-id')));
 await assert.rejects(guardedDown('isolation-refused',owner(),compose),/foreign/);
 const unchanged=await save('foreign-fixture-after-refusal',await engine.projectOwnership(owner()));assert.deepEqual(unchanged.inventory.containers.map(c=>c.Id).sort(),poisoned.inventory.containers.map(c=>c.Id).sort());
 await finite('sentinel-up',['up','--detach','--no-build','--wait','parent'],sentinel);const sentinelId=(await finite('sentinel-id',['ps','--quiet','parent'],sentinel)).stdout.trim();
 // The deliberately mismatched fixture removes itself through its originally issued finite --rm command.
 // Production cleanup never overrides the failed ownership guard.
 const autoRemoveDeadline=Date.now()+30000;let current;
 do{current=await engine.projectOwnership(owner());if(!current.inventory.containers.some(c=>c.Id===foreignId))break;await new Promise(resolve=>setTimeout(resolve,250))}while(Date.now()<autoRemoveDeadline);
 assert.equal(current.status,'complete');assert.equal(current.inventory.containers.some(c=>c.Id===foreignId),false);
 await guardedDown('owned-cleanup',owner(),compose);
 const protectedProject=await save('sentinel-after-owned-cleanup',await engine.projectOwnership({runId:sentinelRun,projectName:sentinelProject}));assert.equal(protectedProject.status,'complete');assert.equal(protectedProject.containerDetails.find(c=>c.Id===sentinelId)?.State?.Running,true);
 passed=true;await save('result',{passed,runId,projectName,childId,parentId,foreignFixtureRun,foreignId,sentinelRun,sentinelProject,sentinelId,foreignSameProjectRefusedBeforeEffects:true,namespaceBindingRefused:true,completedOneoffRemoved:true,foreignProjectRetained:true,scope:'native root-issued cleanup ownership fixture; no application evaluation gate'});
} catch(error){failure=error;await save('failure',{error:String(error),stack:error?.stack})} finally {
 for(const [name,requested,executor] of [['final-own',owner(),compose],['final-sentinel',{runId:sentinelRun,projectName:sentinelProject},sentinel]])try{await guardedDown(name,requested,executor)}catch(error){await save(name+'-incomplete',{error:String(error)});passed=false}
 await jobs.dispose();await ctx.fiber.dispose();
 if(!passed)throw failure??new Error('native cleanup ownership qualification incomplete');
}
console.log(JSON.stringify({passed,runId,projectName}));
