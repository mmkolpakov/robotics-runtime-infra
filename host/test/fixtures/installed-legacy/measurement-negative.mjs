import assert from 'node:assert/strict';
import {readFile,writeFile,readdir,access} from 'node:fs/promises';
import {referenceFile} from '@robotics-runtime/host';
import Docker from 'dockerode';
export async function interruptedMeasurement(mode,{run,finalizer,engine,compose,parameters,options,requirements,plan,save}){
 assert.ok(['cancel','timeout'].includes(mode));assert.equal(run.phase,'measuring');
 assert.ok(run.phases.some(row=>row.phase==='ready'&&row.status==='passed'));
 const {runId,output}=parameters;
 const native=new Docker({socketPath:parameters.socket,version:'v'+engine.facts.clientApi});
 const owned=await engine.remainingOwned(runId);
 const observer=owned.containers.find(row=>row.Labels?.['com.docker.compose.service']===plan.observerService);assert.ok(observer);
 for(const [id,requirement] of [[observer.Id,requirements[plan.observerService]],[plan.sourceContainerId,requirements.simulation]]){
  const facts=await engine.inspect(id,requirement);assert.equal(facts.status,'complete');assert.equal(facts.container.State.Running,true);
  await save(id===observer.Id?'observer-running-before-interruption':'source-running-before-interruption',facts);
 }
 try{await access(plan.measurementCompletePath);assert.fail('measurement already completed before negative control')}catch(error){if(error.code!=='ENOENT')throw error}
 const saveJob=async(name,args,signal)=>{const result=await compose.run(args,signal);await save(name,{command:args,result});assert.equal(result.ok,true,result.diagnostic??result.stderr);return result};
 let controlReceipt,lastStateObserved=false,writerDrainSettled=false;
 const closeMeasurement=async signal=>{
  const cancel=new AbortController(),deadlineMs=2000;
  const timed=mode==='timeout'?AbortSignal.timeout(deadlineMs):cancel.signal;
  const timer=mode==='cancel'?setTimeout(()=>cancel.abort(new Error('installed measurement cancellation acceptance')),deadlineMs):undefined;
  const combined=AbortSignal.any([signal,timed]);
  const startedAt=new Date().toISOString();
  let outcome;
  try{outcome=await finalizer.hooks.closeMeasurement(combined).then(value=>({status:'fulfilled',value}),reason=>({status:'rejected',reason}))}
  finally{if(timer)clearTimeout(timer)}
  assert.equal(outcome.status,'rejected','interrupted measurement closed successfully');
  assert.equal(timed.aborted,true,'measurement failed before the selected negative control');
  const error=outcome.reason;
  assert.ok(error===combined.reason||error?.cause===combined.reason,'close producer rejection is not bound to the selected cancellation');
  controlReceipt={mode,producer:'public legacyFinalization.hooks.closeMeasurement',control:mode==='timeout'?'explicit native producer deadline signal':'explicit cancellation signal',deadlineMs,startedAt,settledAt:new Date().toISOString(),controlReason:String(timed.reason),producerError:String(error),producerSettled:true,observerId:observer.Id,sourceId:plan.sourceContainerId};
  await save('native-measurement-producer-settlement',controlReceipt);throw error;
 };
 const captureLastState=async signal=>{const refs=await finalizer.hooks.captureLastState(signal);lastStateObserved=true;return refs};
 const drainRecorders=async signal=>{
  const ownership=await engine.projectOwnership({runId,projectName:options.projectName,networkNamespaceContainerId:plan.sourceContainerId});await save('diagnostic-drain-ownership',ownership);assert.equal(ownership.status,'complete');
  const raw=await engine.readLogs(observer.Id,{runId,projectName:options.projectName},{tailLines:10000,maxBytes:1048576,deadlineMs:30000},signal);
  const rawPath=output+'/observer.docker-raw';await writeFile(rawPath,raw.bytes);
  const actual=await native.getContainer(observer.Id).inspect();assert.equal(actual.Config.Labels['org.robotics.runtime.run-id'],runId);assert.equal(actual.Config.Labels['com.docker.compose.project'],options.projectName);
  if(actual.State.Running)await native.getContainer(observer.Id).stop({t:30});
  const stopped=await native.getContainer(observer.Id).inspect();assert.equal(stopped.State.Running,false);await save('observer-stopped-after-interruption',stopped);
  await saveJob('diagnostic-writer-drain',['stop','--timeout','30',...plan.instrumentServices,...plan.recorderServices,plan.collectorService,'evidence-sink','neutral-robot'],signal);
  const inventory=await engine.remainingOwned(runId);
  for(const row of inventory.containers){
   if(row.Id===plan.sourceContainerId)continue;
   const state=await native.getContainer(row.Id).inspect();assert.equal(state.Config.Labels['org.robotics.runtime.run-id'],runId);assert.equal(state.State.Running,false,'native writer still running: '+row.Id);
  }
  await save('native-writers-settled-before-export',inventory);
  await saveJob('diagnostic-foundation-logs',['logs','--no-color'],signal);
  writerDrainSettled=true;return [await referenceFile(rawPath)];
 };
 const target='/retained/failed-source-'+runId;
 const exportEvidence=async signal=>{
  assert.ok(controlReceipt?.producerSettled,'interrupted measurement producer must settle before export');
  assert.equal(lastStateObserved,true,'actual native last-state did not succeed');assert.equal(writerDrainSettled,true,'actual native writer drain did not succeed');
  const before=await engine.remainingOwned(runId);assert.ok(before.containers.some(row=>row.Id===plan.sourceContainerId));assert.ok(run.resources.pending().every(row=>!row.attempted));await save('native-before-diagnostic-export',before);
  await saveJob('diagnostic-source-export',['run','--rm','--no-deps','legacy-coordinator','/opt/contracts/bin/python','/source/host/workers/legacy-live/export-startup-failure.py','--source','/run/robotics','--destination',target,'--run-id',runId],signal);
  const manifest=JSON.parse(await readFile(target+'/export-manifest.json','utf8'));assert.equal(manifest.status,'complete');assert.equal(manifest.runId,runId);assert.ok(manifest.entries.length);
  const refs=[await referenceFile(target+'/export-manifest.json')];
  for(const entry of manifest.entries){const ref=await referenceFile(target+'/'+entry.relativePath);assert.equal(ref.sha256,entry.sha256);assert.equal(ref.size_bytes,entry.size_bytes);refs.push(ref)}
  for(const name of await readdir(output))if(name.endsWith('.json')||name.endsWith('.docker-raw'))refs.push(await referenceFile(output+'/'+name));
  refs.push(await save('host-verified-export',{runId,target,entries:manifest.entries.length,allHashesAndSizesVerified:true}));return refs;
 };
 const completion=await run.finish({closeMeasurement,captureLastState,drainRecorders,exportEvidence});await save('completion',completion);
 assert.equal(completion.status,'error');assert.ok(controlReceipt?.producerSettled);
 assert.ok(completion.phases.some(row=>row.phase==='closing-measurement'&&row.status==='error'));
 for(const phase of ['capturing-last-state','draining-recorders','exporting-evidence'])assert.ok(completion.phases.some(row=>row.phase===phase&&row.status==='passed'),'required native stage did not pass: '+phase);
 assert.ok(completion.resourceOutcomes.length&&completion.resourceOutcomes.every(row=>row.attempted&&row.released&&row.evidenceRefs.length&&!row.cleanupError),JSON.stringify(completion));
 const remaining=await engine.remainingOwned(runId);assert.equal(remaining.containers.length,0);assert.equal(remaining.networks.length,0);assert.ok(remaining.volumes.Volumes===null||remaining.volumes.Volumes.length===0);await save('native-empty-after-cleanup',remaining);
 const report={status:'passed',scope:'installed native ROS interrupted measurement; diagnostic export only',mode,runId,engine:identityEngine(engine),readyObserved:true,measurementOpened:true,nativeObserverRunningObserved:true,noSuccessfulMeasurement:true,completionStatus:completion.status,nativeResourcesReleased:true,deadlineScope:mode==='timeout'?'explicit native closeMeasurement deadline signal; RunOwner profile deadline unchanged':undefined};
 await save('negative-report',report);return report;
}
function identityEngine(engine){return engine.facts.versionResponse.Components?.some(row=>row.Name==='Podman Engine')?'podman':'docker'}
