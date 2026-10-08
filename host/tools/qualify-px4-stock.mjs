import assert from 'node:assert/strict';
import {createHash,randomUUID} from 'node:crypto';
import {mkdtemp,readFile,writeFile,chmod,mkdir,readdir,lstat} from 'node:fs/promises';
import {isAbsolute,join,resolve,dirname} from 'node:path';
import {pathToFileURL,fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';

const root=resolve(fileURLToPath(new URL('../..',import.meta.url)));
export function externalCase(argv) {
  if(!argv.length)return null;
  assert(argv.length===2&&argv[0]==='--external-case','use --external-case CASE');
  assert(['land','unarmed-refusal','application-deadline'].includes(argv[1]),'unknown external flight case');
  return argv[1];
}
export function externalOperator(config,px4,server,owner,project,podman) {
  assert(isAbsolute(podman),'absolute operator Podman executable required');
  for(const [facts,service] of [[px4,'px4-native'],[server,'mavsdk-native']]){
    assert.equal(facts.status,'complete','producer admission is incomplete');
    assert.match(facts.container?.Id,/^[a-f0-9]{64}$/);
    const labels=facts.container.Config?.Labels;
    assert.equal(labels?.['org.robotics.runtime.run-id'],owner);
    assert.equal(labels?.['com.docker.compose.project'],project);
    assert.equal(labels?.['com.docker.compose.service'],service);
  }
  assert.notEqual(px4.container.Id,server.container.Id);
  return {podmanExecutable:podman,px4Id:px4.container.Id,serverId:server.container.Id,
    ownerId:owner,project,runVolume:config.runVolume,grpcPort:config.grpcPort};
}
export async function captureConsumerFailure(invoke,recordRefusal) {
  try{await invoke();return null}
  catch(error){
    try{await recordRefusal(error)}catch{}
    return error;
  }
}
export async function finishAfterConsumer(run,hooks,firstError,recordLater,checkCompletion) {
  try{
    const completion=await run.finish(hooks);
    if(checkCompletion)await checkCompletion(completion);
    if(!firstError)return completion;
  }
  catch(error){
    if(firstError){
      try{await recordLater(error)}catch{}
      throw firstError;
    }
    throw error;
  }
  throw firstError;
}
async function main() {
const selected=externalCase(process.argv.slice(2));
const operatorPodman=process.env.PX4_PODMAN_EXECUTABLE??'/usr/bin/podman';
if(selected)assert(isAbsolute(operatorPodman),'absolute operator Podman executable required');
const {default:Docker}=await import('dockerode');
const {ComposeExecution,EngineMetadata}=await import('@robotics-runtime/infra-host');
const {Context,Jobs,Admission,RunOwner,referenceFile,isDisposed}=await import('@robotics-runtime/host');
const volumeRoot=process.env.PX4_VOLUME_ROOT;
const image=process.env.PX4_WORKER_IMAGE;
const composeExecutable=process.env.PX4_COMPOSE_EXECUTABLE;
const socketPath=process.env.PX4_ENGINE_SOCKET;
const runVolume=process.env.PX4_RUN_VOLUME;
const grpcPort=Number(process.env.PX4_GRPC_PORT??'50113');
assert([volumeRoot,composeExecutable,socketPath].every(v=>typeof v==='string'&&isAbsolute(v)),
  'absolute volume root, Compose executable and Engine socket required');
assert(typeof runVolume==='string'&&/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/.test(runVolume),'named retained volume required');
assert(/^.+@sha256:[a-f0-9]{64}$/.test(image??''),'immutable native image required');
assert(Number.isSafeInteger(grpcPort)&&grpcPort>=1024&&grpcPort<=65535,'unprivileged local gRPC port required');
const output=join(root,'artifacts/px4/native-'+randomUUID());
await mkdir(output,{recursive:true});
const directory=await mkdtemp(join(root,'host/.tools/run-profile-'));
const config={composeExecutable,socketPath,composeFiles:[join(root,'compose.px4.yaml'),join(root,'compose.px4.podman.yaml')],cwd:root,
  workerImage:image,runVolume,outputRoot:join(volumeRoot,'output/px4'),grpcPort,deadlineMs:120000};
const modulePath=join(directory,'px4.mjs'), sdkPath=join(directory,'mavsdk.mjs'), profilePath=join(directory,'cordis.json');
await writeFile(modulePath,"export {default} from "+JSON.stringify(pathToFileURL(join(root,'host/dist/src/plugins/px4-provider/index.js')).href)+";\n");
await writeFile(sdkPath,"export {Mavsdk as default} from '@robotics-runtime/host';\n");
await writeFile(profilePath,JSON.stringify([{id:'px4',name:'./px4.mjs',config},
  {id:'mavsdk',name:'./mavsdk.mjs',config:{endpoint:'127.0.0.1:'+grpcPort,deadlineMs:60000}}]));
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
const controllerPaths=selected?['src/run.mjs','src/flight.mjs','src/admission.mjs','src/operator-input.mjs',
  'input-pins.json','package.json','package-lock.json'].map(name=>join(root,'examples/px4-x500',name)):[];
const controllerInputs=await Promise.all(controllerPaths.map(path=>referenceFile(path)));

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
    timeoutMs:10000,maxBufferBytes:1048576,env:{ROBOTICS_PX4_IMAGE:image,ROBOTICS_RUN_VOLUME:config.runVolume,ROBOTICS_RUN_ID:owner,ROBOTICS_PX4_SCOPE:px4.output.split('/').at(-1),ROBOTICS_PX4_GRPC_PORT:String(grpcPort)}});
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
  let flight;let consumerError;let positions=[];let poseDelta;
  if(selected){
    const inputRefs=[...controllerInputs];const controllerRefs=[];
    let poses;let job;let jobFailure;
    consumerError=await captureConsumerFailure(async()=>{
    const podman=operatorPodman;
    const p=JSON.parse(await readFile(join(px4.output,'px4-native-engine.json'),'utf8'));
    const m=JSON.parse(await readFile(join(px4.output,'mavsdk-native-engine.json'),'utf8'));
    const operator=externalOperator(config,p,m,owner,px4.project,podman);
    const operatorPath=join(output,'external-operator.json');
    await writeFile(operatorPath,JSON.stringify(operator)+'\n',{flag:'wx',mode:0o400});
    inputRefs.push(await referenceFile(operatorPath));
    const controllerOutput=join(output,'controller-'+selected);
    const entry=join(root,'examples/px4-x500/src/run.mjs');
    for(const expected of inputRefs){
      const actual=await referenceFile(fileURLToPath(expected.uri));
      assert(actual.sha256===expected.sha256&&actual.size_bytes===expected.size_bytes,'external source changed before dispatch');
    }
    poses=px4.probe('observe','external-native-pose.json',25,signal);poses.catch(()=>{});
    job=await ctx.jobs.run({executable:process.execPath,args:[entry,selected,operatorPath,controllerOutput],
      cwd:dirname(dirname(entry)),timeoutMs:60000,maxBufferBytes:1048576,cancelSignal:signal,
      extendEnv:false,env:{PATH:dirname(process.execPath)+':/usr/bin:/bin'}});
    jobFailure=job.ok?null:new Error(job.diagnostic??('external controller exit '+job.exitCode+' signal '+job.signal));
    try{
    const jobRef=await save('external-controller-job.json',job);
    inputRefs.push(jobRef);
      const names=await readdir(controllerOutput);
      for(const name of names){
        assert(/^[0-9]{4,}-[a-z0-9-]+\.json$/.test(name),'unexpected controller output');
        const file=join(controllerOutput,name);const facts=await lstat(file);
        assert(facts.isFile()&&!facts.isSymbolicLink(),'unsafe controller evidence');
        controllerRefs.push(await referenceFile(file));
      }
      const resultNames=names.filter(name=>name.endsWith('-controller-result.json'));
      assert.equal(resultNames.length,1,'one terminal controller result required');
      const result=JSON.parse(await readFile(join(controllerOutput,resultNames[0]),'utf8'));
      assert(job.ok&&result.complete&&result.outcome?.case===selected,'external controller failed or incomplete');
      const native=await poses;
      assert(native.poses.length>2,'native Gz pose stream required');
      const heights=native.poses.map(pose=>pose.z_m);
      const delta=Math.max(...heights)-Math.min(...heights);poseDelta=delta;
      assert(selected==='unarmed-refusal'?delta<=0.2:delta>=1.2,'native physics does not match external case');
      flight=await save('flight-observations.json',{owner_id:owner,case:selected,
        controller:result,native_pose_delta_m:delta,scope:'stock simulated x500 external policy only'});
    }catch(error){throw jobFailure??error}
    },async error=>{
      try{
        flight=await save('external-controller-refusal.json',{owner_id:owner,case:selected,error:String(error),...(job?{job}:{})});
      }finally{if(poses){try{await poses}catch{}}}
    });
    inputRefs.push(...controllerRefs);
    const retainedFlight=flight;
    flight={...retainedFlight,externalRefs:inputRefs};
  }else{
  const poses=px4.probe('observe','takeoff-native-pose.json',25,signal);
  poses.catch(()=>{});
  const unary=(invoke)=>new Promise((resolve,reject)=>invoke({deadline:Date.now()+10000},(error,value)=>error?reject(error):resolve(value)));
  const arm=await unary((options,callback)=>sdk.clients.action.arm({},options,callback));
  assert.equal(arm.action_result?.result,'RESULT_SUCCESS','native Action.arm result must report success');
  const takeoff=await unary((options,callback)=>sdk.clients.action.takeoff({},options,callback));
  assert.equal(takeoff.action_result?.result,'RESULT_SUCCESS','native Action.takeoff result must report success');
  positions=[];const effectEnd=performance.now()+20000;
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
  const delta=Math.max(...height)-Math.min(...height);poseDelta=delta;
  assert(delta>=1.2,'Gz stock physics must corroborate observed ascent');
  flight=await save('flight-observations.json',{owner_id:owner,arm,takeoff,positions,native_pose_delta_m:delta,
    scope:'stock simulated x500 only; no hardware, application-specific airframe or full mission qualification'});
  }
  const completion=await finishAfterConsumer(run,{
    closeMeasurement:async s=>{s.throwIfAborted();await px4.drainRecorders(s);return [await save('measurement-close.json',{owner_id:owner,last_position:positions.at(-1)})]},
    captureLastState:s=>px4.captureLastState(s),
    drainRecorders:s=>px4.drainRecorders(s),
    exportEvidence:async s=>{const {externalRefs,...flightRef}=flight??{};return [...(flightRef.uri?[flightRef]:[]),...(externalRefs??[]),...await px4.exportEvidence(s),await referenceFile(join(output,'readiness.json'))]},
  },consumerError,error=>save('producer-finish-refusal.json',{owner_id:owner,error:String(error)}),async completion=>{
  await save('run-completion.json',completion);
  const foreignAfter=await foreign.inspect();assert.equal(foreignAfter.State.Running,true,'owned cleanup must preserve the foreign source fixture');await save('foreign-untouched.json',{id:foreignAfter.Id,labels:foreignAfter.Config.Labels,running:foreignAfter.State.Running});
  assert.equal(completion.status,'passed','lifecycle completion must independently pass');
  assert(isDisposed(run.fiber),'actual native Fiber must be DISPOSED');
  assert(completion.resourceOutcomes.every(v=>v.released),'native Engine cleanup must release all owned resources');
  });
  console.log(JSON.stringify({passed:true,owner_id:owner,worker_image:image,native_pose_delta_m:poseDelta,case:selected??'stock-takeoff',completion_status:completion.status,provider_output:px4.output,qualification_output:output}));
}catch(error){
  try{await save('failure.json',{owner_id:owner,error:String(error),run:run?.phase,retained_run:!!(run||error?.run)})}
  catch(later){console.error('failed to retain failure.json:',later)}

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

}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))await main();
