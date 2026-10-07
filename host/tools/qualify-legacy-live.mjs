import assert from 'node:assert/strict';
import {mkdir,readFile,writeFile,readdir,copyFile,chmod,stat,access} from 'node:fs/promises';
import {join,isAbsolute} from 'node:path';
import {constants,createReadStream} from 'node:fs';
import {createHash} from 'node:crypto';
import {pathToFileURL,fileURLToPath} from 'node:url';
export function legacyLiveParameters(argv){
 assert.equal(argv.length,12,'legacy live source CLI requires its twelve positional arguments');
 const [root,socket,executable,runId,sourceVolume,retainedVolume,simulationImage,simulationReference,coordinatorImage,evidenceImage,output,sourceRevision]=argv;
 assert.match(simulationImage,/^(?:sha256:)?[a-f0-9]{64}$/);
 return {root,socket,executable,runId,sourceVolume,retainedVolume,simulationImage:simulationImage.startsWith('sha256:')?simulationImage:'sha256:'+simulationImage,simulationReference,coordinatorImage,evidenceImage,output,sourceRevision};
}
export function validateLegacyLiveFixture(parameters,fixture={}){
 const {root,socket,executable,runId,sourceVolume,retainedVolume,simulationImage,simulationReference,coordinatorImage,evidenceImage,output,sourceRevision}=parameters;
 assert.ok([root,socket,executable,output].every(value=>typeof value==='string'&&isAbsolute(value)),'absolute legacy live paths required');
 assert.match(runId,/^run-[a-f0-9-]{36}$/);
 assert.match(sourceRevision,/^[a-f0-9]{40}$/);
 assert.ok(sourceVolume!==retainedVolume,'separate source and retained volumes required');
 assert.ok([sourceVolume,retainedVolume].every(value=>typeof value==='string'&&/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/.test(value)),'explicit storage identities required');
 assert.match(simulationImage,/^(?:sha256:)?[a-f0-9]{64}$/);
 assert.match(simulationReference,/^[^\s@]+@sha256:[a-f0-9]{64}$/);
 assert.ok([coordinatorImage,evidenceImage].every(value=>typeof value==='string'&&/^(?:(?:sha256:)?[a-f0-9]{64}|[^\s@]+@sha256:[a-f0-9]{64})$/.test(value)),'immutable helper image bindings required');
 const copy=structuredClone(fixture);
 if(copy.engineProfile!==undefined){
  const selected=copy.engineProfile;
  assert.ok(selected&&typeof selected==='object'&&!Array.isArray(selected)&&Object.keys(selected).length===2&&Object.keys(selected).every(key=>['engine','expectedUsernsMode'].includes(key)),'explicit fixture engine profile required');
  assert.ok(['podman','docker'].includes(selected.engine),'unsupported fixture engine profile');
  assert.equal(selected.expectedUsernsMode,selected.engine==='docker'?'':'private','fixture engine namespace expectation differs');
  assert.ok(copy.profile&&copy.hostRequirement,'engine profile requires installed host admission');
  assert.equal(copy.hostRequirement.hostConfig?.UsernsMode,selected.expectedUsernsMode,'installed host namespace expectation differs');
  if(selected.engine==='docker')assert.ok(Number.isSafeInteger(copy.socketGid)&&copy.socketGid>=0,'actual Docker socket group required');
 }
 if(copy.composeEnvironment!==undefined){
  const env=copy.composeEnvironment;
  assert.ok(env&&typeof env==='object'&&!Array.isArray(env),'fixture Compose environment must be an object');
  assert.ok(Object.keys(env).every(key=>key==='COMPOSE_PARALLEL_LIMIT'),'fixture Compose environment cannot override reserved bindings');
  if(env.COMPOSE_PARALLEL_LIMIT!==undefined)assert.ok(typeof env.COMPOSE_PARALLEL_LIMIT==='string'&&/^[1-9][0-9]*$/.test(env.COMPOSE_PARALLEL_LIMIT)&&Number.isSafeInteger(Number(env.COMPOSE_PARALLEL_LIMIT)),'fixture Compose concurrency limit must be a positive integer');
 }
 if(copy.profile){
  const profile=copy.profile;
  assert.ok(typeof profile.id==='string'&&profile.id.length>0&&isAbsolute(profile.profilePath),'explicit immutable profile required');
  assert.ok(Array.isArray(profile.files)&&profile.files.length>0&&profile.files.every(file=>isAbsolute(file.path)&&/^[a-f0-9]{64}$/.test(file.sha256)),'immutable profile file identities required');
  assert.ok(profile.files.some(file=>file.path===profile.profilePath),'immutable profile must bind its Include file');
  assert.equal(copy.finalizerPlugin,'@robotics-runtime/infra-host/plugins/legacy-finalization','installed fixture must select the existing public finalizer');
 }
 if(copy.hostRequirement){
  assert.ok(copy.profile,'installed host binding requires an immutable profile');
  const host=copy.hostRequirement;
  assert.ok(typeof host.runId==='string'&&host.runId.length>0&&typeof host.projectName==='string'&&host.projectName.length>0&&copy.hostService==='installed-host','explicit installed host ownership required');
  assert.match(host.imageDigest,/^[^\s@]+@sha256:[a-f0-9]{64}$/,'installed host requires its observed full RepoDigest');
  assert.equal(host.user,'1000:1000');
  for(const [destination,name] of [['/run/robotics',sourceVolume],['/retained',retainedVolume]]){
   const mount=host.mounts?.find(row=>row.destination===destination);
   assert.equal(mount?.volumeName,name,'installed host storage binding mismatch');assert.equal(mount?.readOnly,false);
  }
  assert.ok(copy.imageBindings,'observed helper image bindings required');
  assert.equal(copy.imageBindings.simulation.imageId.replace(/^sha256:/,''),simulationImage.replace(/^sha256:/,''),'simulation image binding mismatch');
  assert.equal(copy.imageBindings.simulation.reference,simulationReference,'simulation reference binding mismatch');
  assert.equal(copy.imageBindings.finalizer.reference,coordinatorImage,'finalizer image binding mismatch');
  assert.equal(copy.imageBindings.evidence.reference,evidenceImage,'evidence image binding mismatch');
 }
 for(const key of ['sourceHostRoot','postprocessRoot'])if(copy[key]!==undefined)assert.ok(isAbsolute(copy[key]),'absolute fixture deployment roots required');
 if(copy.deferQualification!==undefined)assert.equal(typeof copy.deferQualification,'boolean');
 return copy;
}
export function legacyLiveComposeOptions(parameters,fixture={}) {
 const {root,socket,executable,runId,sourceVolume,retainedVolume,simulationImage,simulationReference,coordinatorImage,evidenceImage,sourceRevision}=parameters;
 const projectName='rr-joint-'+runId.slice(4,20);
 const env={ROBOTICS_RUN_ID:runId,LEGACY_SOURCE_ROOT:fixture.sourceHostRoot??root,LEGACY_SOURCE_REVISION:sourceRevision,
 LEGACY_SIMULATION_IMAGE:simulationImage,LEGACY_SIMULATION_REFERENCE:simulationReference,LEGACY_SIMULATION_DIGEST:simulationReference.split('@')[1],
 LEGACY_COORDINATOR_IMAGE:coordinatorImage,LEGACY_EVIDENCE_IMAGE:evidenceImage,LEGACY_SHARED_VOLUME:sourceVolume,ROBOTICS_RETAINED_VOLUME:retainedVolume,
 ROS_DOMAIN_ID:'181',GZ_PARTITION:projectName,...fixture.composeEnvironment};
 const selectedEngine=fixture.engineProfile?.engine??'podman';
 const options={executable,socketPath:socket,projectName,cwd:root,
 files:[root+'/host/test/fixtures/legacy-live/compose.yaml',root+'/host/test/fixtures/legacy-live/evidence.yaml',...(selectedEngine==='podman'?[root+'/host/test/fixtures/legacy-live/compose.podman.yaml']:[])],env,timeoutMs:240000,maxBufferBytes:4194304};
 return options;
}
export async function prefetchLegacyImages(compose,ownedImages,job,save) {
 const result=await compose.run(['config','--images']);
 await save('runtime-image-closure',result);
 assert.equal(result.ok,true,result.diagnostic??result.stderr);
 const images=[...new Set(result.stdout.trim().split(/\s+/).filter(Boolean))];
 assert.ok(images.length,'selected runtime image closure is empty');
 const auxiliary=images.filter(image=>!ownedImages.includes(image));
 for(const image of auxiliary)assert.match(image,/^[^\s@]+@sha256:[a-f0-9]{64}$/,'auxiliary runtime image must retain its declared digest');
 await save('runtime-auxiliary-images',{ownedImages,images,auxiliary});
 for(const [index,image] of auxiliary.entries()) {
  await job('pull-runtime-auxiliary-'+index,['pull',image]);
  await job('inspect-runtime-auxiliary-'+index,['image','inspect',image]);
 }
 return auxiliary;
}
export async function retainHomeComposeQualification(compose,save,environment){
 const versionProbe=await compose.requireVersion();
 await save('home-compose-qualification',{version:versionProbe.stdout.trim(),versionProbe,environment,scope:'HOME source qualification only'});
}
export async function qualifyLegacyLive(argv,fixture={},afterMeasurement){
 if(afterMeasurement!==undefined)assert.equal(typeof afterMeasurement,'function','fixed installed measurement probe required');
 const parameters=legacyLiveParameters(argv);
 fixture=validateLegacyLiveFixture(parameters,fixture);
 const {root,socket,executable,runId,sourceVolume,retainedVolume,simulationImage,simulationReference,coordinatorImage,evidenceImage,output,sourceRevision}=parameters;
 const {Context,Jobs,Admission,RunOwner,referenceFile,isDisposed}=await import('@robotics-runtime/host');
 const {ComposeExecution,EngineMetadata}=await import('@robotics-runtime/infra-host');
 const {default:LegacyInputs}=await import('@robotics-runtime/infra-host/plugins/legacy-inputs');
 const {default:FinalInputs}=await import('@robotics-runtime/infra-host/plugins/legacy-finalization-inputs');
 const ctx=new Context();
 if(fixture.profile){
  await ctx.plugin(Admission,{profiles:[fixture.profile]}).await();
  await ctx.get('admission').admit(fixture.profile.id);
 }
assert.match(runId,/^run-[a-f0-9-]{36}$/);
const projectName='rr-joint-'+runId.slice(4,20);
await ctx.plugin(Jobs,{timeoutMs:240000,maxBufferBytes:4194304}).await();
await ctx.plugin(LegacyInputs).await();await ctx.plugin(FinalInputs).await();
await mkdir(output,{recursive:true});
const save=async(name,value)=>{const path=join(output,name+'.json');await writeFile(path,JSON.stringify(value,null,2)+'\n');return referenceFile(path)};
const selectedEngine=fixture.engineProfile?.engine??'podman';
const expectedUsernsMode=fixture.engineProfile?.expectedUsernsMode??'private';
const options=legacyLiveComposeOptions(parameters,fixture),env=options.env;
const compose=new ComposeExecution(ctx.jobs,options);
const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
if(fixture.hostRequirement){
 if(fixture.engineProfile){
  const components=engine.facts.versionResponse.Components;
  const actualEngine=Array.isArray(components)&&components.some(row=>row?.Name==='Podman Engine')?'podman':
   Array.isArray(components)&&components.some(row=>row?.Name==='Engine')?'docker':undefined;
  assert.equal(actualEngine,selectedEngine,'selected fixture engine differs from actual native version metadata');
  await save('installed-engine-profile',{profile:fixture.engineProfile,engine:engine.facts});
 }
 const inventory=await engine.remainingOwned(fixture.hostRequirement.runId);
 const host=inventory.containers.find(row=>row.Labels?.['com.docker.compose.service']===fixture.hostService);assert.ok(host,'installed host ownership not observed');
 const observed=await engine.inspect(host.Id,fixture.hostRequirement);
 assert.equal(observed.status,'complete',JSON.stringify(observed));
 if(selectedEngine==='docker')assert.deepEqual(observed.container.HostConfig?.GroupAdd,[String(fixture.socketGid)],'installed host supplemental group differs from actual socket group');
 await save('installed-host-native-metadata',observed);
 const origins=Object.fromEntries(['@robotics-runtime/host','@robotics-runtime/infra-host','@robotics-runtime/infra-host/plugins/gazebo-ros-v1'].map(name=>[name,import.meta.resolve(name)]));
 assert.ok(Object.values(origins).every(value=>value.startsWith('file:///app/node_modules/')));await save('installed-origins',origins);
 if(selectedEngine==='podman')await retainHomeComposeQualification(compose,save,fixture.composeEnvironment);
 else {
  const versionProbe=await compose.requireVersion();
  await save('docker-compose-qualification',{version:versionProbe.stdout.trim(),versionProbe,environment:fixture.composeEnvironment,scope:'Docker CI source qualification only'});
 }
}else{
 const {default:Docker}=await import('dockerode');
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
}
const finite=async(name,args,signal)=>{const result=await compose.run(args,signal);await save(name,result);assert.equal(result.ok,true,result.diagnostic??result.stderr);return result};
let run,finalizer,completion,status='failed',error;
try{
 await finite('admission',['run','--rm','--no-deps','admission']);
 const sourceRequirement={runId,projectName,imageId:simulationImage,user:'1000:1000',mounts:[{destination:'/run/robotics',readOnly:false,volumeName:sourceVolume},{destination:'/run/robotics/input',readOnly:true,volumeName:runId+'-input'}],hostConfig:{Memory:536870912,ReadonlyRootfs:false,Privileged:false,Init:true,UsernsMode:expectedUsernsMode}};
 ctx.get('legacyInputs').issue({runId,compose:options,artifactDirectory:output,observationServices:['otel-collector','evidence-sink'],
 simulationRequirement:{...sourceRequirement,hostConfig:{...sourceRequirement.hostConfig,IpcMode:'shareable'}},stepperRequirement:sourceRequirement,
 admittedDescriptionPath:'/run/robotics/input/product/ros_ws/src/robotics_runtime_infra/description/neutral_robot.urdf',
 entityWorkerPath:'/run/robotics/input/helpers/check-entity.py',clockWorkerPath:'/run/robotics/input/helpers/observe-clock-owner.py',readinessWorkerPath:'/run/robotics/input/helpers/observe-robot-ready.py',
 preClockReadyJobs:[
 {id:'native-provider-capture',args:['exec','-T','simulation','robotics-entrypoint','python3','/run/robotics/input/helpers/capture-provider.py','--output','/run/robotics/provider','--image-id',simulationImage]},
 {id:'provider-manifest',args:['run','--rm','--no-deps','legacy-coordinator','/opt/contracts/bin/python','/source/host/workers/legacy-live/prepare-runtime.py','--source','/source','--data','/run/robotics','--native-metadata',output,'--run-id',runId,'--project',projectName,'--subject-digest',env.LEGACY_SIMULATION_DIGEST]},
 ]});
 let profile=fixture.profile,finalizerPlugin=fixture.finalizerPlugin;
 if(!profile){
 const profileRoot=join(root,'host/.tools/joint-profiles',runId),closure=join(profileRoot,'infra'),files=[];
 const copy=async(from,to)=>{await mkdir(to,{recursive:true});for(const entry of await readdir(from,{withFileTypes:true})){if(entry.isDirectory())await copy(join(from,entry.name),join(to,entry.name));else if(entry.name.endsWith('.js')){const path=join(to,entry.name);await copyFile(join(from,entry.name),path);await chmod(path,0o444);files.push({path,sha256:createHash('sha256').update(await readFile(path)).digest('hex')})}}};
 await copy(root+'/host/dist/src',closure);
 const profilePath=profileRoot+'/cordis.yml';await writeFile(profilePath,JSON.stringify([{id:'gazebo',name:pathToFileURL(closure+'/plugins/gazebo-ros-v1/index.js').href}],null,2));await chmod(profilePath,0o444);
 files.push({path:profilePath,sha256:createHash('sha256').update(await readFile(profilePath)).digest('hex')});
 profile={id:'joint-live-source',profilePath,files,requiredBindings:[{entryId:'gazebo',service:'gazeboRosV1'}],isolatedServices:['gazeboRosV1','legacyFinalization'],deadlineMs:240000};
 finalizerPlugin=pathToFileURL(closure+'/plugins/legacy-finalization/index.js').href;
 }
 await save('immutable-profile',profile);if(!fixture.profile)await ctx.plugin(Admission,{profiles:[profile]}).await();await ctx.plugin(RunOwner).await();
 run=await ctx.get('runOwner').start(profile.id,runId);
 const snapshot=run.context.get('gazeboRosV1').snapshot();await save('readiness-snapshot',snapshot);
 assert.equal(run.phase,'ready');
 const sharedRequirement={...sourceRequirement,networkNamespaceContainerId:snapshot.simulationContainerId};
 const requirements={simulation:sourceRequirement,'simulation-stepper':sharedRequirement,'acceptance-observer':sharedRequirement,
 'runtime-probe-publisher':sharedRequirement,'runtime-metrics':sharedRequirement,recorder:sharedRequirement,
 'otel-collector':{...sharedRequirement,imageId:'sha256:971344cab87ed2f0cafc2db1d081e5534cc6ba21b33e8d931be3c87dd84fafef',hostConfig:{Memory:268435456,ReadonlyRootfs:true,Privileged:false,UsernsMode:expectedUsernsMode}}};
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
 const postOptions={...options,projectName:projectName+'-post',cwd:fixture.postprocessRoot??root,files:[(fixture.postprocessRoot??root)+'/compose.legacy-retained.yaml',...(selectedEngine==='podman'?[(fixture.postprocessRoot??root)+'/compose.legacy-finalization.podman.yaml']:[])],
 env:{LEGACY_FINALIZER_IMAGE:coordinatorImage,ROBOTICS_RUN_ID:runId,ROBOTICS_RETAINED_VOLUME:retainedVolume}};
 const plan={runId,compose:options,postprocessCompose:postOptions,artifactDirectory:control+'/phases',retainedDirectory:retained,measurementCompletePath:'/run/robotics/measurement-complete',startupRefs:snapshot.readyRefs,requirements,sourceContainerId:snapshot.simulationContainerId,
 observerService:'acceptance-observer',instrumentServices:['runtime-probe-publisher','runtime-metrics'],recorderServices:['recorder'],collectorService:'otel-collector',stepperService:'simulation-stepper',simulationService:'simulation',coordinatorService:'legacy-coordinator',exportCoordinatorService:'legacy-export',
 lastStateWorkerPath:'/run/robotics/input/helpers/capture-last-state.py',exportWorkerPath:'/opt/robotics/finalizer/workers/export_retained.py',inventoryWorkerPath:'/opt/robotics/finalizer/workers/collect_inventory.py',inventoryPlanPath:control+'/inventory.json',exportPlanPath:control+'/export.json',qualificationInputsWorkerPath:control+'/args.json',qualificationInputsHostPath:control+'/args.json',
 helperRoot:'/opt/robotics/finalizer',retainedWorkerRoot:retained,contractPythonPath:'/opt/contracts/bin/python',
 scenarioPath:retained+'/payloads/scenario.yaml',runContextPath:retained+'/payloads/acceptance-run.json',resultPath:retained+'/payloads/results/acceptance-result.json',aggregatePath:retained+'/acceptance-aggregate.json',evidenceRoot:'/run/robotics/evidence',
 foundationLogPath:'/run/robotics/logs/foundation.log',observerLogPath:'/run/robotics/logs/observer.log',timeoutMs:240000};ctx.get('legacyFinalizationInputs').issue(plan);
 const Module=await import(finalizerPlugin);const fiber=run.context.plugin(Module.default);await fiber.await();finalizer=run.context.get('legacyFinalization');
 run.beginMeasurement();await save('measurement-open',{afterReadiness:true,phase:run.phase});
 await finalizer.beginMeasurement(AbortSignal.timeout(240000));
 if(afterMeasurement){
  const result=await afterMeasurement({run,finalizer,engine,compose,parameters,options,requirements,plan,save});
  assert.equal(result.scope,'installed native ROS interrupted measurement; diagnostic export only');
  await save('joint-result',result);return result;
 }
 completion=await run.finish(finalizer.hooks);await save('completion',completion);
 assert.equal(completion.status,'passed',JSON.stringify(completion.errors));assert.ok(isDisposed(run.fiber));
 const retainedRefs=new Map(completion.evidenceRefs.map(ref=>[ref.uri,ref]));
 for(const outcome of completion.resourceOutcomes)for(const ref of outcome.evidenceRefs??[])retainedRefs.set(ref.uri,ref);
 for(const ref of retainedRefs.values()){const path=fileURLToPath(ref.uri);assert.ok(path.startsWith('/retained/'),'completion ref outside retained lifetime: '+path);const digest=createHash('sha256');for await(const chunk of createReadStream(path))digest.update(chunk);assert.equal(digest.digest('hex'),ref.sha256);assert.equal((await stat(path)).size,ref.size_bytes)}
 await save('completion-retention-audit',{uniqueRefs:retainedRefs.size,allRefsInsideRetained:true,allHashesAndSizesVerified:true});
 if(fixture.deferQualification){
  const result=JSON.parse(await readFile(retained+'/payloads/results/acceptance-result.json','utf8'));assert.equal(result.status,'passed');assert.equal(result.evaluation_mode,'live');
  await writeFile(control+'/live-completion.json',JSON.stringify(completion,null,2)+'\n');
  await writeFile(control+'/finalization-plan.json',JSON.stringify(plan,null,2)+'\n');
  await save('finalization-plan',plan);
  const before={};
  for(const path of await retainedFiles('/retained')){const digest=createHash('sha256');for await(const chunk of createReadStream(path))digest.update(chunk);before[path]={sha256:digest.digest('hex'),size_bytes:(await stat(path)).size}}
  await writeFile(control+'/before-source-teardown.json',JSON.stringify(before,null,2)+'\n');
 }else{
 const qualified=await finalizer.qualifyAfterCleanup(completion,AbortSignal.timeout(240000));await save('qualified-references',qualified);
 const result=JSON.parse(await readFile(retained+'/payloads/results/acceptance-result.json','utf8'));assert.equal(result.status,'passed');assert.equal(result.evaluation_mode,'live');
 const aggregate=JSON.parse(await readFile(retained+'/acceptance-aggregate.json','utf8'));assert.equal(aggregate.per_domain_aggregate,'passed');assert.equal(aggregate.cross_domain_e2e.status,'unevaluated');
 }
 status='passed';
}catch(failure){run=failure.run??run;error=String(failure);await save('failure',{error,phase:run?.phase});if(run&&!completion&&finalizer){completion=await run.finish(finalizer.hooks);await save('completion',completion)}}
await save('joint-result',{status,error,runId,sourceVolume,retainedVolume,scope:fixture.deferQualification?'installed ROS live/export/cleanup; aggregate and portable qualification remain pending actual host-source teardown':'live neutral source profile; released readiness/equivalence gate remains separate'});
return {status,error,runId};
}

async function retainedFiles(root){
 const files=[];for(const row of await readdir(root,{withFileTypes:true})){const path=join(root,row.name);if(row.isDirectory())files.push(...await retainedFiles(path));else if(row.isFile())files.push(path)}return files;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const result=await qualifyLegacyLive(process.argv.slice(2));console.log(JSON.stringify(result));if(result.status!=='passed')process.exitCode=1;
}
