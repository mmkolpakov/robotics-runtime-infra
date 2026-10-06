import assert from 'node:assert/strict';
import {createHash,randomUUID} from 'node:crypto';
import {constants,createReadStream} from 'node:fs';
import {readFile,writeFile,mkdir,readdir,stat,copyFile} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {join} from 'node:path';
import {setTimeout as pause} from 'node:timers/promises';
import {Context,Jobs,Admission,RunOwner,RunResources,isDisposed,referenceFile} from '@robotics-runtime/host';
import {ComposeExecution,EngineMetadata} from '@robotics-runtime/infra-host';
import WebotsNative from '@robotics-runtime/infra-host/plugins/webots';
const identity=JSON.parse(await readFile('/app/identity.json','utf8'));
const sourceVolume=process.env.C18_SOURCE_VOLUME,retainedVolume=process.env.C18_RETAINED_VOLUME;
const workerComposeFiles=identity.deployment.composeFiles.map(name=>'/app/'+name);
assert.equal(sourceVolume,identity.sourceVolume);assert.equal(retainedVolume,identity.retainedVolume);
assert.equal(process.getuid(),1000);assert.equal(process.getgid(),1000);
assert.equal(process.version,'v24.21.0');
const origins=Object.fromEntries(['@robotics-runtime/host','@robotics-runtime/infra-host','@robotics-runtime/infra-host/plugins/webots'].map(name=>[name,import.meta.resolve(name)]));
assert.ok(Object.values(origins).every(path=>path.startsWith('file:///app/node_modules/')));
const read=async path=>JSON.parse(await readFile(path,'utf8'));
const save=async(path,value)=>{await mkdir(join(path,'..'),{recursive:true});await writeFile(path,JSON.stringify(value,null,2)+'\n');return referenceFile(path)};
const allFiles=async root=>{const files=[];for(const row of await readdir(root,{withFileTypes:true})){const p=join(root,row.name);if(row.isDirectory())files.push(...await allFiles(p));else if(row.isFile())files.push(p)}return files};
const closure=await allFiles('/app/node_modules');
const pin=async path=>({path,sha256:(await referenceFile(path)).sha256});
const profile=async(path,id='webots')=>({id,profilePath:path,files:await Promise.all([...closure,path,...workerComposeFiles].map(pin)),requiredBindings:[{entryId:'webots',service:'webots'}],isolatedServices:['webots'],deadlineMs:120000});
// The outer dispatcher outlives the run: native cleanup still needs Jobs after Include unload.
// Putting Jobs in this run's profile would cancel its own cleanup commands during disposal.
const ctx=new Context();await ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:4*1024*1024}).await();
const engine=await EngineMetadata.connect({socketPath:'/engine.sock',operationMinApi:'1.24',operationMaxApi:'1.53'});
const parentMaps=await engine.rootlessParentMaps();
const namespace={uidMap:await readFile('/proc/self/uid_map','utf8'),gidMap:await readFile('/proc/self/gid_map','utf8'),parentMaps};
const kernelMapping=(map,id)=>{for(const line of map.trim().split('\n')){const [inside,parent,count]=line.trim().split(/\s+/).map(Number);if(id>=inside&&id<inside+count)return parent+id-inside}throw new Error('native namespace mapping missing')};
assert.equal(kernelMapping(namespace.uidMap,1000),0);assert.equal(kernelMapping(namespace.gidMap,1000),0);
assert.equal(parentMaps.uidMap.find(row=>row.container_id===0).host_id,1001);
assert.equal(parentMaps.gidMap.find(row=>row.container_id===0).host_id,1001);
const socket=await stat('/engine.sock');assert.equal(socket.mode&0o777,0o600);
const init={pid:1,comm:await readFile('/proc/1/comm','utf8'),sha256:(await referenceFile('/proc/1/exe')).sha256};
assert.equal(init.sha256,'43e9b836ca7631672f12d0610cd574875b62d236dfd62e3b86751f35862e5eba');
const noPython=await ctx.jobs.run({executable:'/usr/bin/env',args:['python3','--version'],timeoutMs:1000});assert.equal(noPython.ok,false);
for(const path of ['/opt/ros','/usr/local/webots','/opt/contracts']) await assert.rejects(stat(path),{code:'ENOENT'});
await save('/retained/installation.json',{identity,origins,node:process.version,uid:process.getuid(),gid:process.getgid(),namespace,init,noPython,engine:engine.facts});
const admitted=await profile('/app/profiles/webots.yml');
await ctx.plugin(Admission,{profiles:[admitted,{...await profile('/app/profiles/missing-provider.yml','missing-provider'),deadlineMs:1000}]}).await();
await ctx.plugin(RunOwner).await();
const missingId=randomUUID();
await assert.rejects(ctx.runOwner.start('missing-provider',missingId));
assert.equal((await engine.remainingOwned(missingId)).containers.length,0);
const rejectedAdmission=new Context();const bad={...admitted,id:'tampered',files:admitted.files.map((row,index)=>index===0?{...row,sha256:'0'.repeat(64)}:row)};
await rejectedAdmission.plugin(Admission,{profiles:[bad]}).await();await assert.rejects(rejectedAdmission.admission.admit('tampered'));await rejectedAdmission.fiber.dispose();
let run;try {run=await ctx.runOwner.start('webots',randomUUID())} catch(error) {await save('/retained/startup-error.json',{diagnostic:String(error),completion:error.completion,capturedErrors:error.run?.capturedErrors});throw error;}
const provider=run.context.get('webots');
const immutableWorker=provider.config.workerImage;
assert.throws(()=>{provider.config.workerImage='foreign'},TypeError);assert.equal(provider.config.workerImage,immutableWorker);
const pre=await read(join(provider.output,'ready.json'));assert.equal(pre.initial_state.time_seconds,0);
run.beginMeasurement();
const measured=await provider.measure(AbortSignal.timeout(120000));
assert.equal(measured.status,'completed');
const native=await read(join(provider.output,'controller-result.json'));assert.equal(native.time.native_unit,'seconds');assert.equal(native.time.representation,'float64');assert.equal(native.reset.observed,true);
const compose=new ComposeExecution(ctx.jobs,{executable:'/usr/local/bin/docker-compose',socketPath:'/engine.sock',projectName:provider.project,files:workerComposeFiles,cwd:'/app',timeoutMs:120000,maxBufferBytes:4*1024*1024,env:{ROBOTICS_WEBOTS_IMAGE:identity.workerImage,ROBOTICS_RUN_VOLUME:sourceVolume,ROBOTICS_RETAINED_VOLUME:retainedVolume,ROBOTICS_RUN_ID:provider.ownerId,ROBOTICS_WEBOTS_SCOPE:provider.output.split('/').at(-1),ROBOTICS_WEBOTS_MODE:'physics-only',ROBOTICS_NODE_IMAGE:identity.nodeImage}});
const phaseRoot='/retained/phases';
const completion=await run.finish({
 closeMeasurement:async()=>[await save(phaseRoot+'/close.json',{measurementCompleted:true,marker:await read(join(provider.output,'measure')),nativeFiniteEpisode:measured})],
 captureLastState:async()=>{const state=await read(join(provider.output,'last-native-state.json'));assert.equal(state.time_seconds,native.last_native_state.time_seconds);await copyFile(join(provider.output,'last-native-state.json'),'/retained/last-native-state.json');return [await referenceFile('/retained/last-native-state.json')]},
 drainRecorders:async()=>{assert.ok(measured.children.every(row=>row.reaped&&row.group_absent));return [await save(phaseRoot+'/native-children-drained.json',{children:measured.children,scope:'native worker process groups; no ROS recorder selected'})]},
 exportEvidence:async signal=>{const refs=await provider.exportEvidence(signal);const doc=await compose.run(['run','--rm','--no-deps','--entrypoint','/opt/contracts/bin/python','webots-documents','/opt/c18/document-checks.py','--native',provider.output,'--output','/retained/documents-live','--run-id','run-'+provider.ownerId,'--execution-subject-digest',identity.workerImage.split('@')[1]],signal);await save('/retained/document-job.json',doc);assert.equal(doc.ok,true,doc.stderr);return [...refs,...await Promise.all((await allFiles('/retained/documents-live')).map(referenceFile))]},
});
await save('/retained/completion.json',completion);assert.equal(completion.status,'passed',JSON.stringify(completion));assert.ok(isDisposed(run.fiber));
const projectAfter=await engine.projectOwnership({runId:provider.ownerId,projectName:provider.project});assert.equal(projectAfter.status,'complete');assert.equal(projectAfter.inventory.containers.length,0);
await save('/retained/positive.json',{runId:provider.ownerId,project:provider.project,native,completion,projectAfter});
// Wrong scene is rejected by the existing native launcher before it spawns Webots.
const negativeOwner='rr-webots-negative-'+randomUUID();
const negativeProject='rr-webots-neg-'+randomUUID().slice(0,8);
const negative=new ComposeExecution(ctx.jobs,{executable:'/usr/local/bin/docker-compose',socketPath:'/engine.sock',projectName:negativeProject,files:workerComposeFiles,cwd:'/app',timeoutMs:30000,env:{ROBOTICS_WEBOTS_IMAGE:identity.workerImage,ROBOTICS_RUN_VOLUME:sourceVolume,ROBOTICS_RETAINED_VOLUME:retainedVolume,ROBOTICS_RUN_ID:negativeOwner,ROBOTICS_WEBOTS_SCOPE:negativeOwner,ROBOTICS_WEBOTS_MODE:'physics-only',ROBOTICS_NODE_IMAGE:identity.nodeImage}});
const wrongScene=await negative.run(['run','--rm','--no-deps','webots-native','run','--output','/run/robotics/output/wrong-scene','--owner-id',negativeOwner,'--expected-world-sha256','0'.repeat(64)]);assert.equal(wrongScene.ok,false);assert.match(wrongScene.stderr,/bytes differ/);await assert.rejects(stat('/run/robotics/output/wrong-scene/webots.log'),{code:'ENOENT'});
await save('/retained/wrong-scene.json',wrongScene);
const negativeInventory=await engine.projectOwnership({runId:negativeOwner,projectName:negativeProject});assert.equal(negativeInventory.status,'complete');assert.equal(negativeInventory.inventory.containers.length,0);await save('/retained/negative-cleanup.json',negativeInventory);
// A foreign signal must leave the measurement gate absent; an owned cancel retains native last state.
const cancelCtx=new Context();await cancelCtx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:1048576}).await();await cancelCtx.plugin(RunResources,'rr-webots-cancel-'+randomUUID()).await();
const cancelFiber=cancelCtx.plugin(WebotsNative,{composeExecutable:'/usr/local/bin/docker-compose',socketPath:'/engine.sock',composeFiles:[...workerComposeFiles],cwd:'/app',workerImage:identity.workerImage,runVolume:sourceVolume,outputRoot:'/run/robotics/output/webots',artifactDirectory:'/retained/cancel',mode:'physics-only'});await cancelFiber.await();const cancelProvider=cancelCtx.get('webots');await cancelProvider.ready(AbortSignal.timeout(120000));
const cancelCompose=new ComposeExecution(cancelCtx.jobs,{executable:'/usr/local/bin/docker-compose',socketPath:'/engine.sock',projectName:cancelProvider.project,files:workerComposeFiles,cwd:'/app',timeoutMs:30000,env:{ROBOTICS_WEBOTS_IMAGE:identity.workerImage,ROBOTICS_RUN_VOLUME:sourceVolume,ROBOTICS_RETAINED_VOLUME:retainedVolume,ROBOTICS_RUN_ID:cancelProvider.ownerId,ROBOTICS_WEBOTS_SCOPE:cancelProvider.output.split('/').at(-1),ROBOTICS_WEBOTS_MODE:'physics-only',ROBOTICS_NODE_IMAGE:identity.nodeImage}});
const foreignSignal=await cancelCompose.run(['run','--rm','--no-deps','webots-signal','cancel','--output',cancelProvider.output,'--owner-id','foreign-owner']);assert.equal(foreignSignal.ok,false);assert.match(foreignSignal.stderr,/another owner/);await assert.rejects(stat(join(cancelProvider.output,'cancel')),{code:'ENOENT'});
const ownCancel=await cancelCompose.run(['run','--rm','--no-deps','webots-signal','cancel','--output',cancelProvider.output,'--owner-id',cancelProvider.ownerId]);assert.equal(ownCancel.ok,true);
const end=performance.now()+30000;let cancelResult;for(;;){try{cancelResult=await read(join(cancelProvider.output,'worker-result.json'));break}catch(error){if(error.code!=='ENOENT'||performance.now()>end)throw error;await pause(25)}}
assert.equal(cancelResult.status,'canceled');assert.equal(cancelResult.processes_reaped,true);assert.equal(cancelResult.evidence_exported_before_stop,true);assert.equal((await read(join(cancelProvider.output,'controller-result.json'))).samples.length,0);
await copyFile(join(cancelProvider.output,'controller-result.json'),'/retained/cancel-controller-result.json');await copyFile(join(cancelProvider.output,'last-native-state.json'),'/retained/cancel-last-native-state.json');
await save('/retained/cancel.json',{foreignSignal,ownCancel,cancelResult});
const foreign=await cancelCompose.run(['run','--rm','--detach','--no-deps','foreign-fixture']);assert.equal(foreign.ok,true,foreign.stderr);
const foreignId=foreign.stdout.trim().split('\n').at(-1);assert.match(foreignId,/^[a-f0-9]{64}$/);
const beforeForeign=await engine.projectOwnership({runId:cancelProvider.ownerId,projectName:cancelProvider.project});assert.equal(beforeForeign.status,'incomplete');
const beforeIds=beforeForeign.inventory.containers.map(row=>row.Id).sort();assert.ok(beforeIds.includes(foreignId));
await cancelFiber.dispose();
const refusedCleanup=await cancelCtx.runResources.verify(30000);assert.ok(refusedCleanup.some(row=>row.cleanupError?.includes('effects refused')&&!row.released));
const afterForeign=await engine.projectOwnership({runId:cancelProvider.ownerId,projectName:cancelProvider.project});assert.deepEqual(afterForeign.inventory.containers.map(row=>row.Id).sort(),beforeIds);
await save('/retained/foreign-orphan-refusal.json',{foreignId,beforeForeign,refusedCleanup,afterForeign,unchangedIds:true});
const foreignEnd=performance.now()+45000;let allowed;
for(;;){allowed=await engine.projectOwnership({runId:cancelProvider.ownerId,projectName:cancelProvider.project});if(allowed.status==='complete')break;if(performance.now()>foreignEnd)throw new Error('bounded foreign fixture did not expire');await pause(250)}
await save('/retained/cancel-cleanup-before-remedial.json',allowed);
const remedial=await cancelCompose.run(['down','--remove-orphans']);assert.equal(remedial.ok,true,remedial.stderr);
const cancelAfter=await engine.projectOwnership({runId:cancelProvider.ownerId,projectName:cancelProvider.project});assert.equal(cancelAfter.status,'complete');assert.equal(cancelAfter.inventory.containers.length,0);
await save('/retained/cancel-cleanup.json',{scope:'diagnostic cleanup after bounded foreign fixture expired; prior provider refusal preserved',remedial,cancelAfter});
await cancelCtx.fiber.dispose();

// Observe the stock native deadline after an actual READY worker was acquired.
const timeoutRun=await ctx.runOwner.start('webots',randomUUID());
const timeoutProvider=timeoutRun.context.get('webots');
const timeoutRoot='/retained/native-timeout-'+timeoutRun.runId;
await mkdir(timeoutRoot,{recursive:false});await mkdir(timeoutRoot+'/raw',{recursive:false});
assert.equal(timeoutRun.phase,'ready');assert.ok(timeoutRun.profile.deadlineMs>=120000);
const timeoutReady=await read(join(timeoutProvider.output,'ready.json'));
const timeoutMetadata=await read(join(timeoutProvider.output,'engine-readiness.json'));
assert.equal(timeoutReady.owner_id,timeoutRun.runId);assert.equal(timeoutReady.ready,true);
assert.equal(timeoutMetadata.status,'complete');assert.ok(timeoutMetadata.image.RepoDigests.includes(identity.workerImage));
const timeoutContainerId=timeoutMetadata.container.Id;
const timeoutOwner={runId:timeoutProvider.ownerId,projectName:timeoutProvider.project};
const timeoutBefore=await engine.projectOwnership(timeoutOwner);assert.equal(timeoutBefore.status,'complete');
const timeoutRunning=timeoutBefore.containerDetails.find(row=>row.Id===timeoutContainerId);
assert.equal(timeoutRunning?.State.Running,true);
const timeoutCommand=timeoutRunning.Config.Cmd;
assert.ok(Array.isArray(timeoutCommand));const deadlineIndex=timeoutCommand.indexOf('--deadline-seconds');
assert.ok(deadlineIndex>=0);assert.equal(timeoutCommand[deadlineIndex+1],'90');
for(const marker of ['measure','cancel'])await assert.rejects(stat(join(timeoutProvider.output,marker)),{code:'ENOENT'});
const timeoutAcquiredRef=await save(timeoutRoot+'/acquired-ready.json',{ready:timeoutReady,metadata:timeoutMetadata,ownership:timeoutBefore,measureGateUnopened:true});
const timeoutEnd=performance.now()+120000,timeoutStarted=performance.now();
let timeoutWorker,timeoutController,timeoutObservationRef,timeoutSettled=false;
timeoutRun.beginMeasurement();
const timeoutCompletion=await timeoutRun.finish({
 closeMeasurement:async signal=>{
  for(;;){
   signal.throwIfAborted();
   try{timeoutWorker=await read(join(timeoutProvider.output,'worker-result.json'));break}
   catch(error){if(error.code!=='ENOENT'||performance.now()>=timeoutEnd)throw error;await pause(25,undefined,{signal})}
  }
  assert.equal(timeoutWorker.owner_id,timeoutRun.runId);assert.notEqual(timeoutWorker.status,'completed');
  timeoutController=await read(join(timeoutProvider.output,'controller-result.json'));
  assert.equal(timeoutController.owner_id,timeoutRun.runId);assert.notEqual(timeoutController.status,'completed');
  let marker;try{marker=await readFile(join(timeoutProvider.output,'cancel'),'utf8')}catch(error){if(error.code!=='ENOENT')throw error}
  const diagnostic=[timeoutWorker.diagnostic,timeoutController.diagnostic,marker].filter(Boolean).join('; ');
  assert.match(diagnostic,/deadline/);assert.ok(marker==='worker deadline'||/measurement admission deadline exceeded/.test(timeoutController.diagnostic??''));
  assert.equal(timeoutController.samples.length,0);
  await assert.rejects(stat(join(timeoutProvider.output,'measure')),{code:'ENOENT'});
  await assert.rejects(stat(join(timeoutProvider.output,'measurement.json')),{code:'ENOENT'});
  timeoutObservationRef=await save(timeoutRoot+'/native-deadline-observation.json',{diagnostic,worker:timeoutWorker,controller:timeoutController,elapsedAfterReadyMs:performance.now()-timeoutStarted,measureGateUnopened:true});
  throw new Error('observed native worker deadline: '+diagnostic);
 },
 captureLastState:async signal=>{
  signal.throwIfAborted();
  assert.ok(timeoutWorker&&timeoutController,'native deadline must settle before last-state export');
  const source=join(timeoutProvider.output,'last-native-state.json'),target=timeoutRoot+'/raw/last-native-state.json';
  const expected=await referenceFile(source);await copyFile(source,target,constants.COPYFILE_EXCL);
  const retained=await referenceFile(target);assert.equal(retained.sha256,expected.sha256);assert.equal(retained.size_bytes,expected.size_bytes);
  return [retained];
 },
 drainRecorders:async signal=>{
  assert.equal(timeoutWorker?.processes_reaped,true);assert.equal(timeoutWorker?.evidence_exported_before_stop,true);
  assert.ok(timeoutWorker.children.length>0);assert.ok(timeoutWorker.children.every(row=>row.reaped&&row.group_absent));
  let ended;
  for(;;){
   signal.throwIfAborted();
   const remaining=Math.ceil(timeoutEnd-performance.now());if(remaining<=0)throw new Error('native timed-out worker did not exit within outer deadline');
   ended=await engine.projectOwnership(timeoutOwner,{cancelSignal:signal,deadlineMs:Math.min(120000,remaining)});
   assert.equal(ended.status,'complete');
   const worker=ended.containerDetails.find(row=>row.Id===timeoutContainerId);assert.ok(worker);
   if(worker.State.Running===false&&worker.State.Status==='exited'){assert.equal(worker.State.ExitCode,1);break}
   if(performance.now()>=timeoutEnd)throw new Error('native timed-out worker did not exit within outer deadline');
   await pause(25,undefined,{signal});
  }
  timeoutSettled=true;
  return [await save(timeoutRoot+'/native-drain.json',{children:timeoutWorker.children,ended,scope:'native worker process groups and actual exited container; no ROS recorder'})];
 },
 exportEvidence:async signal=>{
  assert.equal(timeoutSettled,true,'unsettled native producer forbids diagnostic export and cleanup');
  assert.ok(timeoutObservationRef,'observed native timeout diagnostics are required');
  const refs=[timeoutAcquiredRef,timeoutObservationRef];
  for(const source of await allFiles(timeoutProvider.output)){
   signal.throwIfAborted();
   const target=join(timeoutRoot,'raw',source.slice(timeoutProvider.output.length+1));
   await mkdir(join(target,'..'),{recursive:true});const expected=await referenceFile(source);
   try{await copyFile(source,target,constants.COPYFILE_EXCL)}catch(error){if(error.code!=='EEXIST')throw error}
   const retained=await referenceFile(target);assert.equal(retained.sha256,expected.sha256);assert.equal(retained.size_bytes,expected.size_bytes);refs.push(retained);
  }
  assert.ok(refs.length);refs.push(await save(timeoutRoot+'/diagnostic-export.json',{scope:'available native timeout diagnostics only; no measurement or conformance PASS',refs}));
  return refs;
 },
});
await save(timeoutRoot+'/completion.json',timeoutCompletion);
assert.equal(timeoutCompletion.status,'error');assert.ok(timeoutCompletion.errors.some(error=>error.includes('observed native worker deadline')));
assert.ok(timeoutCompletion.resourceOutcomes.length>0);
assert.ok(timeoutCompletion.resourceOutcomes.every(row=>row.attempted&&row.released&&row.evidenceRefs.length&&!row.cleanupError));
for(const ref of timeoutCompletion.evidenceRefs){const path=fileURLToPath(ref.uri);assert.ok(path.startsWith('/retained/'));const actual=await referenceFile(path);assert.equal(actual.sha256,ref.sha256);assert.equal(actual.size_bytes,ref.size_bytes)}
const timeoutAfter=await engine.projectOwnership(timeoutOwner);assert.equal(timeoutAfter.status,'complete');
assert.equal(timeoutAfter.inventory.containers.length,0);assert.equal(timeoutAfter.inventory.networks.length,0);
await save('/retained/native-timeout.json',{scope:'stock native deadline after acquired READY; failed measurement, available-byte export and verified owned cleanup',runId:timeoutRun.runId,project:timeoutProvider.project,retainedDirectory:timeoutRoot,completion:timeoutCompletion,after:timeoutAfter,sourceRetainedUntilOuterByteAudit:true});
await ctx.fiber.dispose();
await save('/retained/result.json',{passed:true,scope:'ordinary installed HOME CPU Webots consumer; no Gazebo/ROS gate or hardware claim',identity,origins,runId:provider.ownerId,checks:['native lifecycle/time/evidence','wrong scene native rejection','wrong installed module digest admission','missing provider before acquisition','missing capability public API','tampered raw/public harness','foreign signal isolation','owned cancel no measurement pass','stock native timeout after acquired READY and diagnostic cleanup','physical project cleanup','same-project foreign orphan refuses cleanup before effects']});
console.log(JSON.stringify({passed:true,runId:provider.ownerId,retained:'/retained/result.json'}));
