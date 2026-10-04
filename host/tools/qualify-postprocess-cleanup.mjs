import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir,copyFile,readdir,stat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {join} from 'node:path';
import {Context,Jobs,RunResources,referenceFile} from '@robotics-runtime/host';
import {EngineMetadata} from '../dist/src/index.js';
import Inputs from '../dist/src/plugins/legacy-finalization/inputs.js';
import Finalizer from '../dist/src/plugins/legacy-finalization/index.js';
const [root,socket,executable,image,volume,output]=process.argv.slice(2);
const runId=JSON.parse(await readFile(root+'/test/qualification/fixtures/acceptance-run.json','utf8')).run_id;
const ctx=new Context();await ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:1048576}).await();
await ctx.plugin(RunResources,runId).await();await ctx.plugin(Inputs).await();
const issuer=ctx.get('legacyFinalizationInputs');
const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
await mkdir(output,{recursive:true});
for(const mode of ['package-failure','cancel-active-worker']){
 const target='/retained/postprocess-'+mode+'-'+Date.now();await mkdir(target,{recursive:true});
 for(const file of await readdir(root+'/test/qualification/fixtures')) if((await stat(root+'/test/qualification/fixtures/'+file)).isFile()) await copyFile(root+'/test/qualification/fixtures/'+file,join(target,file));
 const specs=JSON.parse(await readFile(target+'/single-artifacts.json','utf8')).artifacts;
 const args=specs.flatMap(s=>['--artifact',s.kind+':'+s.subject_name+'='+target+'/'+s.file]);
 const argsPath=target+'/inputs.json';await writeFile(argsPath,JSON.stringify(args));
 const primary=target+'/runtime-manifest.json';const before=createHash('sha256').update(await readFile(primary)).digest('hex');
 const projectName='rr-postprocess-'+Date.now();
 const options={executable,socketPath:socket,projectName:projectName+'-source',files:[root+'/compose.legacy-retained.yaml'],cwd:root,timeoutMs:120000,
 env:{LEGACY_FINALIZER_IMAGE:image,ROBOTICS_RUN_ID:runId,ROBOTICS_RETAINED_VOLUME:volume}};
 const post={...options,projectName,files:[root+'/compose.legacy-retained.yaml',root+'/compose.legacy-finalization.podman.yaml']};
 issuer.issue({runId,compose:options,postprocessCompose:post,artifactDirectory:target+'/phases',retainedDirectory:target,measurementCompletePath:target+'/unused-marker',
 startupRefs:[await referenceFile(primary)],requirements:{},sourceContainerId:'a'.repeat(64),
 observerService:'unused',instrumentServices:[],recorderServices:[],collectorService:'unused',stepperService:'unused',simulationService:'unused',coordinatorService:'legacy-coordinator',
 lastStateWorkerPath:'/unused',exportWorkerPath:'/opt/robotics/finalizer/workers/export_retained.py',inventoryWorkerPath:'/opt/robotics/finalizer/workers/collect_inventory.py',
 inventoryPlanPath:target+'/unused',qualificationInputsWorkerPath:argsPath,qualificationInputsHostPath:argsPath,exportPlanPath:target+'/unused-export',
 helperRoot:mode==='package-failure'?'/missing-helper':'/opt/robotics/finalizer',retainedWorkerRoot:target,contractPythonPath:'/opt/contracts/bin/python',
 scenarioPath:target+'/acceptance-scenario.yaml',runContextPath:target+'/acceptance-run.json',resultPath:target+'/acceptance-result.json',aggregatePath:target+'/derived-aggregate.json',
 evidenceRoot:'/unused',foundationLogPath:target+'/unused-foundation',observerLogPath:target+'/unused-observer',timeoutMs:120000});
 const fiber=ctx.plugin(Finalizer);await fiber.await();const finalizer=ctx.get('legacyFinalization');
 // Caller-issued repository fixture: this tests only acquired postprocessing cleanup.
 // It makes no common-host validation or live source-owner claim.
 const completion={runId,status:'passed',phases:[],errors:[],evidenceRefs:[],resourceOutcomes:[{id:'fixture-source',ownerId:runId,attempted:true,released:true,evidenceRefs:[await referenceFile(primary)]}]};
 const abort=new AbortController();const pending=finalizer.qualifyAfterCleanup(completion,abort.signal);
 let saw;
 if(mode==='cancel-active-worker'){
  const deadline=performance.now()+10000;
  while(performance.now()<deadline){
   const owned=await engine.remainingOwned(runId);
   const active=owned.containers.find(v=>v.Labels?.['com.docker.compose.project']===projectName && v.State==='running');
   if(active){saw={id:active.Id,command:active.Command};abort.abort(new Error('native postprocess cancellation'));break}
   await new Promise(resolve=>setTimeout(resolve,20));
  }
  assert.ok(saw,'cancel negative requires an actually running acquired worker');
 }
 await assert.rejects(pending);
 const remaining=await engine.remainingOwned(runId);
 assert.equal(remaining.containers.filter(v=>v.Labels?.['com.docker.compose.project']===projectName).length,0);
 assert.equal(remaining.networks.filter(v=>v.Labels?.['com.docker.compose.project']===projectName).length,0);
 assert.equal(createHash('sha256').update(await readFile(primary)).digest('hex'),before);
 await writeFile(output+'/'+mode+'.json',JSON.stringify({passed:true,scope:'caller-issued repository fixture; acquired postprocess resources only',projectName,saw,retainedDirectory:target,rawInputUnchanged:true,remaining},null,2));
 await fiber.dispose();issuer.release(runId);
}
await ctx.fiber.dispose();console.log(JSON.stringify({passed:true,scope:'native postprocessing failure/cancel cleanup; no live acceptance claim'}));
