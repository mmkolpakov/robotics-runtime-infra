import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir,readdir,stat} from 'node:fs/promises';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {Context,Jobs,Admission,RunOwner,RunStartupError,referenceFile} from '@robotics-runtime/host';
import {ComposeExecution,EngineMetadata} from '@robotics-runtime/infra-host';
import LegacyInputs from '@robotics-runtime/infra-host/plugins/legacy-inputs';
import Docker from 'dockerode';
import {legacyLiveParameters,legacyLiveComposeOptions,validateLegacyLiveFixture} from './qualify-legacy-live.mjs';

const [mode,...argv]=process.argv.slice(2);
assert.ok(['startup-cancel','foreign-cleanup'].includes(mode));
const parameters=legacyLiveParameters(argv),identity=JSON.parse(await readFile('/app/identity.json','utf8'));
const {runId,sourceVolume,retainedVolume,simulationImage,simulationReference,coordinatorImage,evidenceImage,output}=parameters;
assert.equal(parameters.sourceRevision,identity.deploymentRevision);
assert.equal(sourceVolume,identity.sourceVolume);assert.equal(retainedVolume,identity.retainedVolume);
const allFiles=async root=>{const files=[];for(const row of await readdir(root,{withFileTypes:true})){const path=join(root,row.name);if(row.isDirectory())files.push(...await allFiles(path));else if(row.isFile())files.push(path)}return files};
const files=await Promise.all([...await allFiles('/app'),...await allFiles('/inputs')].map(async path=>({path,sha256:(await referenceFile(path)).sha256})));
const profile={id:'installed-ros-negative-'+mode,profilePath:'/app/profiles/ros.yml',files,requiredBindings:[{entryId:'gazebo',service:'gazeboRosV1'}],isolatedServices:['gazeboRosV1','legacyFinalization'],deadlineMs:60000};
const fixture=validateLegacyLiveFixture(parameters,{
 profile,engineProfile:identity.engineProfile,socketGid:(await stat('/engine.sock')).gid,finalizerPlugin:'@robotics-runtime/infra-host/plugins/legacy-finalization',
 sourceHostRoot:process.env.C18_DEPLOYMENT_HOST_ROOT,composeEnvironment:{COMPOSE_PARALLEL_LIMIT:'1'},imageBindings:identity.observedImages,hostService:'installed-host',
 hostRequirement:{runId:process.env.C18_HOST_OWNER,projectName:process.env.C18_HOST_PROJECT,imageDigest:process.env.C18_NODE_IMAGE,user:'1000:1000',
 mounts:[{destination:'/run/robotics',readOnly:false,volumeName:sourceVolume},{destination:'/retained',readOnly:false,volumeName:retainedVolume}],
 hostConfig:{Init:true,ReadonlyRootfs:true,NetworkMode:'none',Memory:1073741824,UsernsMode:identity.engineProfile.expectedUsernsMode}}
});
await mkdir(output,{recursive:true});
const save=async(name,value)=>{const path=join(output,name+'.json');await writeFile(path,JSON.stringify(value,null,2)+'\n');return referenceFile(path)};
const engine=await EngineMetadata.connect({socketPath:parameters.socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
const native=new Docker({socketPath:parameters.socket,version:'v'+engine.facts.clientApi});
const actualEngine=engine.facts.versionResponse.Components?.some(row=>row.Name==='Podman Engine')?'podman':'docker';
assert.equal(actualEngine,identity.engineProfile.engine);await save('engine',engine.facts);
const hosts=await engine.remainingOwned(fixture.hostRequirement.runId),host=hosts.containers.find(row=>row.Labels?.['com.docker.compose.service']==='installed-host');
assert.ok(host);const hostMetadata=await engine.inspect(host.Id,fixture.hostRequirement);assert.equal(hostMetadata.status,'complete');await save('installed-host-native-metadata',hostMetadata);
const origins=Object.fromEntries(['@robotics-runtime/host','@robotics-runtime/infra-host','@robotics-runtime/infra-host/plugins/gazebo-ros-v1'].map(name=>[name,import.meta.resolve(name)]));
assert.ok(Object.values(origins).every(uri=>uri.startsWith('file:///app/node_modules/')));await save('installed-origins',origins);
const ctx=new Context();await ctx.plugin(Jobs,{timeoutMs:240000,maxBufferBytes:4194304}).await();await ctx.plugin(Admission,{profiles:[profile]}).await();await ctx.plugin(LegacyInputs).await();
const options=legacyLiveComposeOptions(parameters,fixture),compose=new ComposeExecution(ctx.jobs,options),projectName=options.projectName;
const job=async(name,args,signal)=>{const result=await compose.run(args,signal);await save(name,result);assert.equal(result.ok,true,result.diagnostic??result.stderr);return result};
await job('admission',['run','--rm','--no-deps','admission']);
const sourceRequirement={runId,projectName,imageId:simulationImage,user:'1000:1000',mounts:[{destination:'/run/robotics',readOnly:false,volumeName:sourceVolume},{destination:'/run/robotics/input',readOnly:true,volumeName:runId+'-input'}],
 hostConfig:{Memory:536870912,ReadonlyRootfs:false,Privileged:false,Init:true,UsernsMode:identity.engineProfile.expectedUsernsMode}};
ctx.get('legacyInputs').issue({runId,compose:options,artifactDirectory:output,observationServices:['otel-collector','evidence-sink'],
 simulationRequirement:{...sourceRequirement,hostConfig:{...sourceRequirement.hostConfig,IpcMode:'shareable'}},stepperRequirement:sourceRequirement,
 admittedDescriptionPath:'/run/robotics/input/product/ros_ws/src/robotics_runtime_infra/description/neutral_robot.urdf',
 entityWorkerPath:'/run/robotics/input/helpers/check-entity.py',clockWorkerPath:'/run/robotics/input/helpers/observe-clock-owner.py',readinessWorkerPath:'/run/robotics/input/helpers/observe-robot-ready.py',
 preClockReadyJobs:[
 {id:'native-provider-capture',args:['exec','-T','simulation','robotics-entrypoint','python3','/run/robotics/input/helpers/capture-provider.py','--output','/run/robotics/provider','--image-id',simulationImage]},
 {id:'provider-manifest',args:['run','--rm','--no-deps','legacy-coordinator','/opt/contracts/bin/python','/source/host/workers/legacy-live/prepare-runtime.py','--source','/source','--data','/run/robotics','--native-metadata',output,'--run-id',runId,'--project',projectName,'--subject-digest',simulationReference.split('@')[1]]}
 ]});
await ctx.plugin(RunOwner).await();const cancel=new AbortController();
let stopObservation=false;
const acquisition=(async()=>{const deadline=Date.now()+30000;while(Date.now()<deadline&&!stopObservation){const actual=await engine.remainingOwned(runId);const sim=actual.containers.find(row=>row.Labels?.['com.docker.compose.service']==='simulation');if(sim){await save('native-acquisition-before-interruption',actual);cancel.abort(new Error('installed native cancellation acceptance'));return sim.Id}await new Promise(resolve=>setTimeout(resolve,100))}assert.fail('native simulation acquisition was not observed before interruption')})();
let failure;
try{await ctx.get('runOwner').start(profile.id,runId,{cancelSignal:cancel.signal});assert.fail('negative run became ready')}catch(error){failure=error}finally{stopObservation=true}
const acquiredId=await acquisition;
assert.ok(failure instanceof RunStartupError,String(failure));assert.match(failure.message,/installed native cancellation acceptance/);
const run=failure.run;await save('interrupted-completion',failure.completion);
assert.ok(!run.phases.some(row=>['ready','measuring'].includes(row.phase)));
assert.notEqual(failure.completion.status,'passed');
assert.ok(failure.completion.resourceOutcomes.every(row=>!row.attempted&&!row.released));
const retained=await engine.remainingOwned(runId);assert.ok(retained.containers.some(row=>row.Id===acquiredId));await save('native-resources-retained-before-export',retained);
// The installed native job result is written only after Jobs observes actual process exit.
let producerReceipt;const settleDeadline=Date.now()+30000;
while(Date.now()<settleDeadline){const names=(await readdir(output)).filter(name=>/^\d+-application-start\.json$/.test(name));
 for(const name of names){const row=JSON.parse(await readFile(join(output,name),'utf8'));if(row.canceled===true||row.timedOut===true){producerReceipt={path:join(output,name),result:row};break}}if(producerReceipt)break;await new Promise(resolve=>setTimeout(resolve,100))}
assert.ok(producerReceipt,'actual interrupted application-start native job settlement absent');
assert.ok(producerReceipt.result.canceled);assert.ok(producerReceipt.result.diagnostic.includes('up --detach --no-build --wait --wait-timeout 120 simulation otel-collector evidence-sink'));
await save('native-producer-settlement',{...producerReceipt,provider:import.meta.resolve('@robotics-runtime/infra-host/plugins/gazebo-ros-v1'),command:['up','--detach','--no-build','--wait','--wait-timeout','120','simulation','otel-collector','evidence-sink']});
await run.context.get('gazeboRosV1').ready(AbortSignal.timeout(30000)).then(()=>assert.fail('interrupted producer became ready'),()=>{});
const owner={runId,projectName,networkNamespaceContainerId:acquiredId};
const before=await engine.projectOwnership(owner);await save('ownership-before-export',before);assert.equal(before.status,'complete',JSON.stringify(before));
let foreign;
if(mode==='foreign-cleanup'){
 foreign=await native.createContainer({name:'rr-c18-foreign-'+runId.slice(4,12),Image:identity.nodeBase,Cmd:['node','-e','setInterval(()=>{},1000)'],User:'1000:1000',
 Labels:{'com.docker.compose.project':projectName,'com.docker.compose.service':'foreign-witness','org.robotics.runtime.run-id':'foreign-'+runId},HostConfig:{NetworkMode:'none',ReadonlyRootfs:true}});
 await foreign.start();await save('foreign-before-cleanup',await foreign.inspect());
 const contaminated=await engine.projectOwnership(owner);await save('foreign-project-ownership',contaminated);assert.notEqual(contaminated.status,'complete');
}
const target='/retained/failed-source-'+runId;
const exportEvidence=async signal=>{
 await job('diagnostic-source-export',['run','--rm','--no-deps','legacy-coordinator','/opt/contracts/bin/python','/source/host/workers/legacy-live/export-startup-failure.py','--source','/run/robotics','--destination',target,'--run-id',runId],signal);
 const manifest=JSON.parse(await readFile(target+'/export-manifest.json','utf8'));assert.equal(manifest.status,'complete');assert.equal(manifest.runId,runId);assert.ok(manifest.entries.length);
 const refs=[await referenceFile(target+'/export-manifest.json')];
 for(const entry of manifest.entries){const ref=await referenceFile(target+'/'+entry.relativePath);assert.equal(ref.sha256,entry.sha256);assert.equal(ref.size_bytes,entry.size_bytes);refs.push(ref)}
 refs.push(await save('host-verified-export',{runId,target,entries:manifest.entries.length,allHashesAndSizesVerified:true}));return refs;
};
assert.equal(run.phase,'retained');const completion=await run.retryExport(exportEvidence);await save('completion',completion);assert.notEqual(completion.status,'passed');
assert.ok(completion.phases.some(row=>row.phase==='exporting-evidence'&&row.status==='passed'));
if(foreign){
 assert.ok(completion.resourceOutcomes.some(row=>row.cleanupError?.includes('refused foreign or unbound')));
 assert.ok(completion.resourceOutcomes.every(row=>!row.released));
 const after=await foreign.inspect();await save('foreign-after-refused-cleanup',after);assert.equal(after.Id,foreign.id);assert.equal(after.State.Running,true);
 const remaining=await engine.remainingOwned(runId);assert.ok(remaining.containers.some(row=>row.Id===acquiredId));await save('owned-after-refused-cleanup',remaining);
 // Remove only this fixture's exact foreign ID, then use the same native ownership guard for recovery.
 assert.equal(after.Config.Labels['org.robotics.runtime.run-id'],'foreign-'+runId);await foreign.stop();await foreign.remove();
 const recovered=await engine.projectOwnership(owner);await save('recovery-ownership-before-effects',recovered);assert.equal(recovered.status,'complete');
 await job('controlled-recovery-teardown',['down','--volumes','--remove-orphans']);
}else assert.ok(completion.resourceOutcomes.length&&completion.resourceOutcomes.every(row=>row.attempted&&row.released&&row.evidenceRefs.length&&!row.cleanupError),JSON.stringify(completion));
const remaining=await engine.remainingOwned(runId);await save('native-empty-after-cleanup',remaining);assert.equal(remaining.containers.length,0);assert.equal(remaining.networks.length,0);assert.ok(remaining.volumes.Volumes===null||remaining.volumes.Volumes.length===0);
const projectAfter=await engine.projectOwnership(owner);await save('project-after-cleanup',projectAfter);assert.equal(projectAfter.status,'complete');
const refs=new Map(completion.evidenceRefs.map(ref=>[ref.uri,ref]));for(const row of completion.resourceOutcomes)for(const ref of row.evidenceRefs)refs.set(ref.uri,ref);
for(const ref of refs.values()){const path=fileURLToPath(ref.uri);assert.ok(path.startsWith('/retained/'));const actual=await referenceFile(path);assert.deepEqual(actual,ref)}
const report={status:'passed',scope:'installed native ROS startup cancellation and cleanup; diagnostic export only',mode,runId,engine:actualEngine,noReadyOrMeasurement:true,interruptedStatus:failure.completion.status,completionStatus:completion.status,nativeResourcesReleased:true,foreignResourcePreserved:mode==='foreign-cleanup'?true:undefined,retainedReferencesVerified:refs.size};
await save('negative-report',report);console.log(JSON.stringify(report));await ctx.fiber.dispose();
