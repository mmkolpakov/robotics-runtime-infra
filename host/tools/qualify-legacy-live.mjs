import assert from 'node:assert/strict';
import {mkdir,readFile,writeFile,readdir,copyFile,chmod,stat,access} from 'node:fs/promises';
import {join} from 'node:path';
import {constants} from 'node:fs';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import Docker from 'dockerode';
import {Context,Jobs,Admission,RunOwner,referenceFile} from '@robotics-runtime/host';
import {ComposeExecution,EngineMetadata,isNativeFiberDisposed} from '../dist/src/index.js';
import LegacyInputs from '../dist/src/plugins/gazebo-ros-v1/inputs.js';
import FinalInputs from '../dist/src/plugins/legacy-finalization/inputs.js';
const [root,socket,executable,runId,sourceVolume,retainedVolume,simulationImage,simulationReference,coordinatorImage,evidenceImage,output,sourceRevision]=process.argv.slice(2);
assert.match(runId,/^run-[a-f0-9-]{36}$/);
const projectName='rr-joint-'+runId.slice(4,20);
const ctx=new Context();await ctx.plugin(Jobs,{timeoutMs:240000,maxBufferBytes:4194304}).await();
await ctx.plugin(LegacyInputs).await();await ctx.plugin(FinalInputs).await();
await mkdir(output,{recursive:true});
const save=async(name,value)=>{const path=join(output,name+'.json');await writeFile(path,JSON.stringify(value,null,2)+'\n');return referenceFile(path)};
const env={ROBOTICS_RUN_ID:runId,LEGACY_SOURCE_ROOT:root,LEGACY_SOURCE_REVISION:sourceRevision,
 LEGACY_SIMULATION_IMAGE:simulationImage,LEGACY_SIMULATION_REFERENCE:simulationReference,LEGACY_SIMULATION_DIGEST:simulationReference.split('@')[1],
 LEGACY_COORDINATOR_IMAGE:coordinatorImage,LEGACY_EVIDENCE_IMAGE:evidenceImage,LEGACY_SHARED_VOLUME:sourceVolume,ROBOTICS_RETAINED_VOLUME:retainedVolume,
 ROS_DOMAIN_ID:'181',GZ_PARTITION:projectName};
const options={executable,socketPath:socket,projectName,cwd:root,
 files:[root+'/host/test/fixtures/legacy-live/compose.yaml',root+'/host/test/fixtures/legacy-live/evidence.yaml'],env,timeoutMs:240000,maxBufferBytes:4194304};
const compose=new ComposeExecution(ctx.jobs,options);
const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
const native=new Docker({socketPath:socket,version:'v'+engine.facts.clientApi});
for(const name of [sourceVolume,retainedVolume]){
 const actual=await native.getVolume(name).inspect();await save('host-volume-'+name,actual);
 assert.equal(actual.Labels['org.robotics.runtime.storage-owner'],'host');assert.ok(!actual.Labels['org.robotics.runtime.run-id']);
}
const host=await native.getContainer(process.env.HOSTNAME).inspect();
assert.match(host.Id,/^[a-f0-9]{64}$/);assert.equal(host.Image,'sha256:bbc51c187ec813fd7c6a49afd22c15efdfe969b8c3a9a9cd49193c8a03908984');
assert.equal(host.Config.User,'1000:1000');assert.ok(!host.Config.Labels?.['org.robotics.runtime.run-id']);
for(const [destination,name] of [['/run/robotics',sourceVolume],['/retained',retainedVolume]]){
 const actual=host.Mounts.find(m=>m.Destination===destination);assert.equal(actual?.Name,name);assert.equal(actual.RW,true);
 await access(destination,constants.R_OK|constants.W_OK);const facts=await stat(destination);await save('host-permissions-'+name,{uid:facts.uid,gid:facts.gid,mode:facts.mode & 0o7777});
}
assert.ok(!host.Mounts.some(m=>m.Name===runId+'-input'));await save('host-native-before-producers',host);
const finite=async(name,args,signal)=>{const result=await compose.run(args,signal);await save(name,result);assert.equal(result.ok,true,result.diagnostic??result.stderr);return result};
let run,finalizer,completion,status='failed',error;
try{
 await finite('admission',['run','--rm','--no-deps','admission']);
 const sourceRequirement={runId,projectName,imageId:simulationImage,user:'1000:1000',mounts:[{destination:'/run/robotics',readOnly:false,volumeName:sourceVolume},{destination:'/run/robotics/input',readOnly:true,volumeName:runId+'-input'}],hostConfig:{Memory:536870912,ReadonlyRootfs:false,Privileged:false,Init:true,UsernsMode:'private'}};
 ctx.get('legacyInputs').issue({runId,compose:options,artifactDirectory:output,observationServices:['otel-collector','evidence-sink'],
 simulationRequirement:{...sourceRequirement,hostConfig:{...sourceRequirement.hostConfig,IpcMode:'shareable'}},stepperRequirement:sourceRequirement,
 admittedDescriptionPath:'/run/robotics/input/product/ros_ws/src/robotics_runtime_infra/description/neutral_robot.urdf',
 entityWorkerPath:'/run/robotics/input/helpers/check-entity.py',clockWorkerPath:'/run/robotics/input/helpers/observe-clock-owner.py',readinessWorkerPath:'/run/robotics/input/helpers/observe-robot-ready.py',
 preClockReadyJobs:[
 {id:'native-provider-capture',args:['exec','-T','simulation','robotics-entrypoint','python3','/run/robotics/input/helpers/capture-provider.py','--output','/run/robotics/provider','--image-id',simulationImage]},
 {id:'provider-manifest',args:['run','--rm','--no-deps','legacy-coordinator','/opt/contracts/bin/python','/source/host/workers/legacy-live/prepare-runtime.py','--source','/source','--data','/run/robotics','--native-metadata',output,'--run-id',runId,'--project',projectName,'--subject-digest',env.LEGACY_SIMULATION_DIGEST]},
 ]});
 const profileRoot=join(root,'host/.tools/joint-profiles',runId),closure=join(profileRoot,'infra'),files=[];
 const copy=async(from,to)=>{await mkdir(to,{recursive:true});for(const entry of await readdir(from,{withFileTypes:true})){if(entry.isDirectory())await copy(join(from,entry.name),join(to,entry.name));else if(entry.name.endsWith('.js')){const path=join(to,entry.name);await copyFile(join(from,entry.name),path);await chmod(path,0o444);files.push({path,sha256:createHash('sha256').update(await readFile(path)).digest('hex')})}}};
 await copy(root+'/host/dist/src',closure);
 const profilePath=profileRoot+'/cordis.yml';await writeFile(profilePath,JSON.stringify([{id:'gazebo',name:pathToFileURL(closure+'/plugins/gazebo-ros-v1/index.js').href}],null,2));await chmod(profilePath,0o444);
 files.push({path:profilePath,sha256:createHash('sha256').update(await readFile(profilePath)).digest('hex')});
 const profile={id:'joint-live-source',profilePath,files,requiredBindings:[{entryId:'gazebo',service:'gazeboRosV1'}],isolatedServices:['gazeboRosV1','legacyFinalization'],deadlineMs:240000};
 await save('immutable-profile',profile);await ctx.plugin(Admission,{profiles:[profile]}).await();await ctx.plugin(RunOwner).await();
 run=await ctx.get('runOwner').start(profile.id,runId);
 const snapshot=run.context.get('gazeboRosV1').snapshot();await save('readiness-snapshot',snapshot);
 assert.equal(run.phase,'ready');
 const sharedRequirement={...sourceRequirement,networkNamespaceContainerId:snapshot.simulationContainerId};
 const requirements={simulation:sourceRequirement,'simulation-stepper':sharedRequirement,'acceptance-observer':sharedRequirement,
 'runtime-probe-publisher':sharedRequirement,'runtime-metrics':sharedRequirement,recorder:sharedRequirement,
 'otel-collector':{...sharedRequirement,imageId:'sha256:971344cab87ed2f0cafc2db1d081e5534cc6ba21b33e8d931be3c87dd84fafef',hostConfig:{Memory:268435456,ReadonlyRootfs:true,Privileged:false,UsernsMode:'private'}}};
 const retained='/retained/raw-'+runId,control='/retained/control-'+runId;
 await mkdir(control,{recursive:true});
 const bindings=[
 ['--scenario','','scenario.yaml'],['--runtime-manifest','primary','runtime-manifest.json'],['--acceptance-run','','acceptance-run.json'],['--result','primary','results/acceptance-result.json'],['--evidence-index','primary','evidence/evidence-index.json'],
 ['--evidence','metrics:metrics.otlp.jsonl','evidence/metrics.otlp.jsonl'],['--evidence','junit:junit.xml','results/junit.xml'],
 ...['fastdds-profile.xml','host-topology.json','runtime-resources.json'].map(n=>['--artifact','other_evidence:'+n,'configuration/'+n]),
 ...['qos-overrides.yaml','mcap-writer.yaml'].map(n=>['--artifact','other_evidence:capture/'+n,'configuration/capture/'+n]),
 ['--artifact','qualification_profile:providers/profile.json','provider/profile.json'],['--artifact','provider_conformance:providers/conformance.json','provider/conformance.json'],
 ['--artifact','other_evidence:providers/configuration.json','provider/configuration.json'],['--artifact','other_evidence:providers/observation.json','provider/observation.json'],['--artifact','other_evidence:providers/world.sdf','provider/world.sdf'],
 ['--artifact','other_evidence:logs/foundation.log','logs/foundation.log'],['--artifact','other_evidence:logs/observer.log','logs/observer.log'],
 ['--artifact','other_evidence:configuration/sdk-package-identity.json','configuration/sdk-package-identity.json'],
 ].map(([flag,subject,source])=>({flag,subject,source}));
 const admission=JSON.parse(await readFile('/run/robotics/configuration/robot-description-admission.json','utf8'));
 const productAndReadinessBindings=admission.files.map(f=>({flag:'--artifact',subject:'other_evidence:products/robot-description/'+f.path,source:'input/product/'+f.path}));
 const inventory={sourceRoot:'/run/robotics',destinationRoot:retained,runId,maximumBytes:67108864,bindings,productAndReadinessBindings,dataSource:'simulator',bagsDirectory:'evidence/bags',summariesDirectory:'evidence/summaries'};
 await writeFile(control+'/inventory.json',JSON.stringify(inventory,null,2));
 const postOptions={...options,projectName:projectName+'-post',files:[root+'/compose.legacy-retained.yaml',root+'/compose.legacy-finalization.podman.yaml'],
 env:{LEGACY_FINALIZER_IMAGE:coordinatorImage,ROBOTICS_RUN_ID:runId,ROBOTICS_RETAINED_VOLUME:retainedVolume}};
 ctx.get('legacyFinalizationInputs').issue({runId,compose:options,postprocessCompose:postOptions,artifactDirectory:control+'/phases',retainedDirectory:retained,measurementCompletePath:'/run/robotics/measurement-complete',startupRefs:snapshot.readyRefs,requirements,sourceContainerId:snapshot.simulationContainerId,
 observerService:'acceptance-observer',instrumentServices:['runtime-probe-publisher','runtime-metrics'],recorderServices:['recorder'],collectorService:'otel-collector',stepperService:'simulation-stepper',simulationService:'simulation',coordinatorService:'legacy-coordinator',exportCoordinatorService:'legacy-export',
 lastStateWorkerPath:'/run/robotics/input/helpers/capture-last-state.py',exportWorkerPath:'/opt/robotics/finalizer/workers/export_retained.py',inventoryWorkerPath:'/opt/robotics/finalizer/workers/collect_inventory.py',inventoryPlanPath:control+'/inventory.json',exportPlanPath:control+'/export.json',qualificationInputsWorkerPath:control+'/args.json',qualificationInputsHostPath:control+'/args.json',
 helperRoot:'/opt/robotics/finalizer',retainedWorkerRoot:retained,contractPythonPath:'/opt/contracts/bin/python',
 scenarioPath:retained+'/payloads/scenario.yaml',runContextPath:retained+'/payloads/acceptance-run.json',resultPath:retained+'/payloads/results/acceptance-result.json',aggregatePath:retained+'/acceptance-aggregate.json',evidenceRoot:'/run/robotics/evidence',
 foundationLogPath:'/run/robotics/logs/foundation.log',observerLogPath:'/run/robotics/logs/observer.log',timeoutMs:240000});
 const Module=await import(pathToFileURL(closure+'/plugins/legacy-finalization/index.js').href);const fiber=run.context.plugin(Module.default);await fiber.await();finalizer=run.context.get('legacyFinalization');
 run.beginMeasurement();await save('measurement-open',{afterReadiness:true,phase:run.phase});
 await finalizer.beginMeasurement(AbortSignal.timeout(240000));
 completion=await run.finish(finalizer.hooks);await save('completion',completion);
 assert.equal(completion.status,'passed',JSON.stringify(completion.errors));assert.ok(isNativeFiberDisposed(run.fiber));
 const qualified=await finalizer.qualifyAfterCleanup(completion,AbortSignal.timeout(240000));await save('qualified-references',qualified);
 const result=JSON.parse(await readFile(retained+'/payloads/results/acceptance-result.json','utf8'));assert.equal(result.status,'passed');assert.equal(result.evaluation_mode,'live');
 const aggregate=JSON.parse(await readFile(retained+'/acceptance-aggregate.json','utf8'));assert.equal(aggregate.per_domain_aggregate,'passed');assert.equal(aggregate.cross_domain_e2e.status,'unevaluated');
 status='passed';
}catch(failure){run=failure.run??run;error=String(failure);await save('failure',{error,phase:run?.phase});if(run&&!completion&&finalizer){completion=await run.finish(finalizer.hooks);await save('completion',completion)}}
await save('joint-result',{status,error,runId,sourceVolume,retainedVolume,scope:'live neutral source profile; released readiness/equivalence gate remains separate'});
console.log(JSON.stringify({status,error,runId}));if(status!=='passed')process.exitCode=1;
