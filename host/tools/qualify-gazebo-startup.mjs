import {mkdir,writeFile,readFile,readdir,copyFile,chmod} from 'node:fs/promises';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {Context,Jobs,Admission,RunOwner,referenceFile} from '@robotics-runtime/host';
import {ComposeExecution,EngineMetadata,isNativeFiberDisposed} from '../dist/src/index.js';
import LegacyInputs from '../dist/src/plugins/gazebo-ros-v1/inputs.js';
const [root,socket,output,simulationImage,coordinatorImage]=process.argv.slice(2);
const runId='rr-c09-'+Date.now(),projectName=runId;
const ctx=new Context();
const jobs=ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:4*1024*1024});await jobs.await();
const inputsFiber=ctx.plugin(LegacyInputs);await inputsFiber.await();
const options={executable:root+'/host/.tools/docker-compose',socketPath:socket,projectName,files:[root+'/host/test/fixtures/legacy-source/compose.yaml'],cwd:root,timeoutMs:120000,env:{ROBOTICS_RUN_ID:runId,LEGACY_SIMULATION_IMAGE:simulationImage,LEGACY_COORDINATOR_IMAGE:coordinatorImage,LEGACY_SOURCE_ROOT:root,ROS_DOMAIN_ID:'179',GZ_PARTITION:runId}};
const compose=new ComposeExecution(ctx.jobs,options);await mkdir(output,{recursive:true});
let diagnosticsRetained=false,exportSequence=0;
const save=async(name,value)=>{const path=join(output,name+'.json');await writeFile(path,JSON.stringify(value,null,2)+'\n');return referenceFile(path)};
const finite=async(name,args,signal)=>{const value=await compose.run(args,signal);const ref=await save(name,value);if(!value.ok)throw new Error(name+': '+value.diagnostic);return {value,ref}};
const exportDiagnostics=async(signal)=>{
 await finite('pre-cleanup-logs-'+(++exportSequence),['logs','--no-color'],signal);
 const refs=[];for(const file of await readdir(output))if(file.endsWith('.json'))refs.push(await referenceFile(join(output,file)));
 if(!refs.length)throw new Error('no retained diagnostic bytes');diagnosticsRetained=true;return refs;
};
const completionHooks={
  closeMeasurement:async()=>[await save('measurement-close',{closed:true,scope:'bounded native Clock observation only; no application recorder/evaluator'})],
  captureLastState:async(signal)=>{await finite('freeze-periodic-writer',['stop','--timeout','20','simulation-stepper'],signal);const {value,ref}=await finite('native-last-state',['exec','-T','simulation','robotics-entrypoint','python3','/run/robotics/input/helpers/capture-last-state.py'],signal);const fact=JSON.parse(value.stdout);if(fact.result_ok!==true||fact.reset_performed!==false||typeof fact.clock_ns!=='string')throw new Error('native last state was not successful and lossless');return [ref]},
  drainRecorders:async()=>{const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});return [await save('startup-role-inventory',await engine.remainingOwned(runId))]},
  exportEvidence:exportDiagnostics,
};
let admissionFiber,ownerFiber,run,completion;let status='failed';let failure;
try {
 const packageFact=await finite('public-worker-packages',['run','--rm','--no-deps','admission','-c','import importlib.metadata as m,json;print(json.dumps({\"contracts\":m.version(\"robotics-runtime-contracts\"),\"harness\":m.version(\"robotics-acceptance-harness\")}))']);
 const versions=JSON.parse(packageFact.value.stdout);if(versions.contracts!=='0.18.2'||versions.harness!=='0.19.1')throw new Error('actual public worker package identity mismatch');
 const negative=await compose.run(['run','--rm','--no-deps','admission','/source/host/workers/legacy/prepare-source.py','--source','/source','--destination','/run/robotics/input','--wrong-digest']);await save('wrong-digest',negative);
 if(negative.exitCode!==65 || !negative.stdout.includes('scenario robot-description digest must select one retained manifest'))throw new Error('wrong digest did not fail before producers');
 await finite('admission',['run','--rm','--no-deps','admission']);
 const baseRequirement={runId,projectName,imageId:simulationImage,user:'1000:1000',mounts:[{destination:'/run/robotics',readOnly:false,volumeName:runId+'-data'},{destination:'/run/robotics/input',readOnly:true,volumeName:runId+'-input'}],hostConfig:{Memory:536870912,ReadonlyRootfs:false,Privileged:false,Init:true,UsernsMode:'private'}};
 ctx.legacyInputs.issue({runId,compose:options,artifactDirectory:output,observationServices:[],simulationRequirement:{...baseRequirement,hostConfig:{...baseRequirement.hostConfig,IpcMode:'shareable'}},stepperRequirement:baseRequirement,admittedDescriptionPath:'/run/robotics/input/product/ros_ws/src/robotics_runtime_infra/description/neutral_robot.urdf',entityWorkerPath:'/run/robotics/input/helpers/check-entity.py',clockWorkerPath:'/run/robotics/input/helpers/observe-clock-owner.py',readinessWorkerPath:'/run/robotics/input/helpers/observe-robot-ready.py'});
 // Only the trusted bootstrap writes this immutable native Include profile.
 const profileRoot=join(root,'host/.tools/run-profiles',runId),closureRoot=join(profileRoot,'infra');const files=[];
 const copyClosure=async(from,to)=>{await mkdir(to,{recursive:true});for(const entry of await readdir(from,{withFileTypes:true})){if(entry.isDirectory())await copyClosure(join(from,entry.name),join(to,entry.name));else if(entry.name.endsWith('.js')){const path=join(to,entry.name);await copyFile(join(from,entry.name),path);await chmod(path,0o444);files.push({path,sha256:createHash('sha256').update(await readFile(path)).digest('hex')})}}};
 await copyClosure(join(root,'host/dist/src'),closureRoot);
 const profilePath=join(profileRoot,'cordis.yml');await writeFile(profilePath,JSON.stringify([{id:'gazebo',name:pathToFileURL(join(closureRoot,'plugins/gazebo-ros-v1/index.js')).href}],null,2)+'\n');await chmod(profilePath,0o444);files.push({path:profilePath,sha256:createHash('sha256').update(await readFile(profilePath)).digest('hex')});
 const profile={id:'legacy-source',profilePath,files,requiredBindings:[{entryId:'gazebo',service:'gazeboRosV1'}],isolatedServices:['gazeboRosV1'],deadlineMs:180000};await save('immutable-profile-closure',profile);
 admissionFiber=ctx.plugin(Admission,{profiles:[profile]});await admissionFiber.await();ownerFiber=ctx.plugin(RunOwner);await ownerFiber.await();
 run=await ctx.runOwner.start('legacy-source',runId);
 await save('startup-ready',{phase:run.phase,evidenceRefs:run.evidenceRefs});await save('startup-snapshot',run.context.get('gazeboRosV1').snapshot());
 // A real bounded native observation window starts only after backend readiness.
 // This qualification acquires no application recorder or evaluator.
 run.beginMeasurement();await save('measurement-open',{opened:true,afterBackendReady:true,scope:'bounded native Clock observation only'});
 await finite('measurement-native-clock',['exec','-T','simulation','robotics-entrypoint','python3','/run/robotics/input/helpers/observe-clock-owner.py']);
 completion=await run.finish(completionHooks);
 await save('owner-completion',completion);
 if(completion.status!=='passed'||!isNativeFiberDisposed(run.fiber)||completion.resourceOutcomes.some(item=>!item.released))throw new Error('native owner lifecycle/physical cleanup failed');
 status='passed';
} catch(error) {
 failure=String(error);await save('startup-error',{error:failure});run=error.run??run;
 if(run?.phase==='retained') {completion=await run.retryExport(exportDiagnostics);await save('owner-completion',completion)}
 else if(run) {completion=await run.finish(completionHooks);await save('owner-completion',completion)}
 else await exportDiagnostics();
} finally {
 // Admission may have created only the owned input volume before a profile error.
 // All diagnostic bytes have been retained before this bounded fallback teardown.
 if(diagnosticsRetained)await finite('fallback-cleanup',['down','--volumes']);
 const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});const remaining=await engine.remainingOwned(runId);await save('remaining',remaining);
 const cleanup=remaining.containers.length===0&&remaining.networks.length===0&&(remaining.volumes.Volumes===null||remaining.volumes.Volumes?.length===0);
 await save('result',{status:status==='passed'&&cleanup?'passed':'failed',cleanup,runId,failure,retainedForRecovery:!diagnosticsRetained,scope:'C09 native Admission/RunOwner source startup and final-state proof; application measurement/recording/evaluation/full B3 released gates remain open'});
 if(diagnosticsRetained){await ownerFiber?.dispose();await admissionFiber?.dispose();ctx.legacyInputs.release(runId);await inputsFiber.dispose();await jobs.dispose()}
 if(!cleanup)throw new Error('actual owned cleanup incomplete; retained diagnostics are required before teardown');
}
console.log(JSON.stringify({status,runId,failure}));
if(status!=='passed')process.exitCode=1;
