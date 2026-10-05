import assert from 'node:assert/strict';
import Docker from 'dockerode';
import {ComposeExecution,EngineMetadata} from '@robotics-runtime/infra-host';
import {createHash,randomUUID} from 'node:crypto';
import {mkdtemp,readFile,writeFile,chmod,mkdir} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {pathToFileURL,fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {Context,Jobs,Admission,RunOwner,referenceFile,isDisposed} from '@robotics-runtime/host';

const root=resolve(fileURLToPath(new URL('../..',import.meta.url)));
const volumeRoot=process.env.PX4_VOLUME_ROOT;
const image=process.env.PX4_WORKER_IMAGE;
assert(volumeRoot?.startsWith('/')&&image?.includes('@sha256:'),'exact native inputs required');
const output=join(root,'artifacts/px4/native-'+randomUUID());
await mkdir(output,{recursive:true});
const directory=await mkdtemp(join(root,'host/.tools/run-profile-'));
const config={composeExecutable:'/home/dev/src/rr-c-infra-20261004/host/.tools/docker-compose',
  socketPath:'/run/user/1001/rr-c13-podman.sock',composeFiles:[join(root,'compose.px4.yaml'),join(root,'compose.px4.podman.yaml')],cwd:root,
  workerImage:image,runVolume:'rr-c13-px4-data-20261004',outputRoot:join(volumeRoot,'output/px4'),grpcPort:50113,deadlineMs:120000};
const modulePath=join(directory,'px4.mjs'), sdkPath=join(directory,'mavsdk.mjs'), profilePath=join(directory,'cordis.json');
await writeFile(modulePath,"export {default} from "+JSON.stringify(pathToFileURL(join(root,'host/dist/src/plugins/px4-provider/index.js')).href)+";\n");
await writeFile(sdkPath,"export {Mavsdk as default} from '@robotics-runtime/host';\n");
await writeFile(profilePath,JSON.stringify([{id:'px4',name:'./px4.mjs',config},
  {id:'mavsdk',name:'./mavsdk.mjs',config:{endpoint:'127.0.0.1:50113',deadlineMs:60000}}]));
const closure=[profilePath,modulePath,sdkPath,join(root,'host/dist/src/plugins/px4-provider/index.js'),
  join(root,'host/dist/src/compose-execution.js'),join(root,'host/dist/src/engine-metadata.js')];
for(const path of closure)await chmod(path,0o444);
const files=await Promise.all(closure.map(async path=>({path,sha256:createHash('sha256').update(await readFile(path)).digest('hex')})));
const descriptor={id:'stock-px4-x500-jetty',profilePath,files,requiredBindings:[{entryId:'px4',service:'px4'}],
  isolatedServices:['px4','mavsdk'],deadlineMs:150000};
const ctx=new Context();
await ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:1048576});
await ctx.plugin(Admission,{profiles:[descriptor]});
await ctx.plugin(RunOwner);
const owner='c13-'+randomUUID();
let run;let foreign;
const save=async(name,value)=>{const path=join(output,name);await writeFile(path,JSON.stringify(value,null,2)+'\n');return referenceFile(path)};
try{
  run=await ctx.runOwner.start(descriptor.id,owner);
  const px4=run.context.get('px4'),sdk=run.context.get('mavsdk');
  const observedEngine=await EngineMetadata.connect({socketPath:config.socketPath,operationMinApi:'1.24',operationMaxApi:'1.53'});
  const engineClient=new Docker({socketPath:config.socketPath,version:'v'+observedEngine.facts.clientApi});
  foreign=await engineClient.createContainer({name:'rr-c13-foreign-'+randomUUID(),Image:image,Entrypoint:['/bin/sleep'],Cmd:['240'],User:'1000:1000',
    Labels:{'org.robotics.runtime.run-id':'foreign-'+owner,'com.docker.compose.project':'rr-c13-foreign'},
    HostConfig:{NetworkMode:'none',Init:true,ReadonlyRootfs:true,Memory:134217728}});
  await foreign.start();
  const finite=new ComposeExecution(ctx.jobs,{executable:config.composeExecutable,socketPath:config.socketPath,projectName:px4.project,files:config.composeFiles,cwd:root,
    timeoutMs:10000,maxBufferBytes:1048576,env:{ROBOTICS_PX4_IMAGE:image,ROBOTICS_RUN_VOLUME:config.runVolume,ROBOTICS_RUN_ID:owner,ROBOTICS_PX4_SCOPE:px4.output.split('/').at(-1),ROBOTICS_PX4_GRPC_PORT:'50113'}});
  const missing=await finite.run(['exec','-T','px4-native','/usr/bin/python3','-B','/opt/robotics/px4/probe.py','--mode','ready','--model','deliberately-missing-model',
    '--owner-id',owner,'--output','/run/robotics/output/px4/'+px4.output.split('/').at(-1)+'/missing-model.json']);
  assert.equal(missing.ok,false,'native Scene presence must reject an absent model');
  await save('missing-model-job.json',missing);
  assert.equal(JSON.parse(await readFile(join(px4.output,'missing-model.json'),'utf8')).ready,false);

  const readiness={transport:sdk.transportReady,core:await sdk.observeConnectionState(),model:await px4.probe('ready','model-before.json',1,AbortSignal.timeout(5000))};
  let health;const healthEnd=performance.now()+45000;
  do{
    health=await sdk.observeHealth();
    if(health.health?.is_armable&&health.health?.is_global_position_ok&&health.health?.is_home_position_ok&&health.health?.is_local_position_ok)break;
    if(performance.now()>=healthEnd)throw new Error('actual native vehicle health did not become armable');
    await delay(250);
  }while(true);
  await save('readiness.json',{owner_id:owner,scope:'CPU stock PX4/Gazebo source simulation only',readiness,health});
  const signal=AbortSignal.timeout(60000);
  run.beginMeasurement();
  const poses=px4.probe('observe','takeoff-native-pose.json',25,signal);
  poses.catch(()=>{});
  const unary=(invoke)=>new Promise((resolve,reject)=>invoke({deadline:Date.now()+10000},(error,value)=>error?reject(error):resolve(value)));
  const arm=await unary((options,callback)=>sdk.clients.action.arm({},options,callback));
  assert.equal(arm.action_result?.result,'RESULT_SUCCESS','native Action.arm result must report success');
  const takeoff=await unary((options,callback)=>sdk.clients.action.takeoff({},options,callback));
  assert.equal(takeoff.action_result?.result,'RESULT_SUCCESS','native Action.takeoff result must report success');
  const positions=[];const effectEnd=performance.now()+20000;
  do{
    const value=await sdk.first(sdk.clients.telemetry.subscribePosition({}, {deadline:Date.now()+5000}),signal);
    positions.push(value);
    if(value.position?.relative_altitude_m>=1.2)break;
    if(performance.now()>=effectEnd)throw new Error('native telemetry did not observe takeoff effect');
    await delay(100);
  }while(true);
  const native=await poses;
  assert(native.poses.length>2,'native Gz pose stream required');
  const height=native.poses.map(p=>p.z_m);
  const delta=Math.max(...height)-Math.min(...height);
  assert(delta>=1.2,'Gz stock physics must corroborate observed ascent');
  const flight=await save('flight-observations.json',{owner_id:owner,arm,takeoff,positions,native_pose_delta_m:delta,
    scope:'stock simulated x500 only; no hardware/Spiral/full mission qualification'});
  const completion=await run.finish({
    closeMeasurement:async s=>{s.throwIfAborted();await px4.drainRecorders(s);return [await save('measurement-close.json',{owner_id:owner,last_position:positions.at(-1)})]},
    captureLastState:s=>px4.captureLastState(s),
    drainRecorders:s=>px4.drainRecorders(s),
    exportEvidence:async s=>[flight,...await px4.exportEvidence(s),await referenceFile(join(output,'readiness.json'))],
  });
  await save('run-completion.json',completion);
  const foreignAfter=await foreign.inspect();assert.equal(foreignAfter.State.Running,true,'owned cleanup must preserve the foreign source fixture');await save('foreign-untouched.json',{id:foreignAfter.Id,labels:foreignAfter.Config.Labels,running:foreignAfter.State.Running});
  assert.equal(completion.status,'passed','lifecycle completion must independently pass');
  assert(isDisposed(run.fiber),'actual native Fiber must be DISPOSED');
  assert(completion.resourceOutcomes.every(v=>v.released),'native Engine cleanup must release all owned resources');
  console.log(JSON.stringify({passed:true,owner_id:owner,worker_image:image,native_pose_delta_m:delta,completion_status:completion.status,provider_output:px4.output}));
}catch(error){
  await save('failure.json',{owner_id:owner,error:String(error),run:run?.phase,retained_run:!!(run||error?.run)});
  // Export readiness/diagnostics before any explicit cleanup of a failed source attempt.
  const retained=run??error?.run;
  if(retained){
    try{await retained.retryExport(async signal=>{const provider=retained.context.get('px4');return [await referenceFile(join(output,'failure.json')),...(provider?await provider.diagnosticEvidence(signal):[])];})}catch{}
  }
  console.error(error);process.exitCode=1;
}finally{
  if(foreign)await foreign.remove({force:true});
  await ctx.fiber.dispose();
}
