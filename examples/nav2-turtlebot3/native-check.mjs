import {createHash, randomUUID} from 'node:crypto';
import {chmod, mkdir, readFile, writeFile, copyFile, access} from 'node:fs/promises';
import {resolve, isAbsolute} from 'node:path';
import {fileURLToPath} from 'node:url';
import {assertOwned, recoverCreated, createdId, nativeWaitExit, admitAndStart, removeUnstartedOwned, canonicalConfigId} from './native-identity.mjs';


export async function runNative(options, jobs) {
const {output: outputRoot, root, imageReference, requirements, python, mode='success'} = options;
if (![outputRoot,root,requirements,python].every(isAbsolute)) throw new Error('absolute input paths and Python executable required');
if (!['success','cancel','timeout','server-failure'].includes(mode)) throw new Error('closed native case required');
if (!/^(?:[^\s@]+@)?sha256:[a-f0-9]{64}$/.test(imageReference)) throw new Error('immutable RepoDigest required');
await mkdir(outputRoot,{mode:0o700});
const output=resolve(outputRoot,'capture'), snapshot=resolve(outputRoot,'source'), prepared=resolve(outputRoot,'inputs');
await mkdir(output,{mode:0o700});
await mkdir(snapshot,{mode:0o700});
for (const file of ['workload.py','make-scenario.py','record-topics.py','fastdds.xml','check-sdk-wheels.py','inputs.lock.json','Dockerfile','native_simulation.launch.py','nav2.schema.json','finalize.py']) {
  await copyFile(resolve(root,file),resolve(snapshot,file));
  await chmod(resolve(snapshot,file),0o444);
}
await copyFile(requirements,resolve(snapshot,'requirements.json'));
await chmod(resolve(snapshot,'requirements.json'),0o444);
const worker=await readFile(snapshot+'/workload.py');
const workerSha=createHash('sha256').update(worker).digest('hex');
const owner='nav2-'+randomUUID(), name=owner;
let image, admitted, composition;
const startedAt=new Date().toISOString();
const events=[];
let runId;
const exactOwner=native=>assertOwned(native,{cid,image,owner,name});
const command=async(op,args,timeoutMs=15000)=>{
  const result=await jobs.run({executable:'/usr/bin/podman',args,timeoutMs,maxBufferBytes:8*1048576,env:{PATH:'/usr/bin:/bin',HOME:process.env.HOME},extendEnv:false});
  events.push({op,ok:result.ok,exitCode:result.exitCode,signal:result.signal,timedOut:result.timedOut,canceled:result.canceled,durationMs:result.durationMs});
  await writeFile(output+'/native-'+op+'.stdout',result.stdout);
  await writeFile(output+'/native-'+op+'.stderr',result.stderr);
  if(!result.ok)throw Object.assign(new Error('native operation refused: '+op),{cause:result});
  return result.stdout;
};
const hostCommand=async(op,args)=>{
  const result=await jobs.run({executable:python,args:['-I',...args],timeoutMs:60000,maxBufferBytes:8*1048576,
    env:{PATH:'/usr/bin:/bin',HOME:process.env.HOME},extendEnv:false});
  events.push({op,ok:result.ok,exitCode:result.exitCode});
  await writeFile(output+'/'+op+'.stdout',result.stdout);
  await writeFile(output+'/'+op+'.stderr',result.stderr);
  if(!result.ok)throw new Error('native inputs refused: '+op);
  return result.stdout;
};
const proveWorkerAbsent=async(directory,result)=>{
  if(result.timedOut||result.canceled||result.signal||![0,1,2].includes(result.exitCode))return false;
  try{
    const fact=JSON.parse(await readFile(output+'/'+directory+'/worker-process.json','utf8'));
    if(fact.run_id!==runId||fact.domain_id!=='nav2'||fact.source_sha256!==workerSha||
       !Number.isSafeInteger(fact.pid)||fact.pid<=0)return false;
    const raw=await command('worker-'+directory+'-absent',['exec',cid,'/usr/bin/python3','-c',
      'import os,sys;print(os.path.exists("/proc/"+sys.argv[1]))',String(fact.pid)]);
    return raw.trim()==='False';
  }catch{return false;}
};
let cid;
let acquisitionAttempted=false;
let failure;
let recorder;
let recorderSettled=false;
let workerSettled=true;
try{

  const inspection=JSON.parse(await command('image-inspect',['image','inspect',imageReference]));
  if (!Array.isArray(inspection)||inspection.length!==1) throw new Error('one selected image required');
  const selected=inspection[0];
  image=canonicalConfigId(selected.Id);
  if (!/^sha256:[a-f0-9]{64}$/.test(image)||!(imageReference===image||selected.RepoDigests?.includes(imageReference))) throw new Error('RepoDigest/Config ID binding differs');
  if (JSON.stringify(selected.Config.Entrypoint)!==JSON.stringify(['/ros_entrypoint.sh'])) throw new Error('selected ROS entrypoint differs');
  const factRaw=await command('image-preflight',['run','--rm','--read-only','--network','none','--memory','268435456','--cpus','1','--pids-limit','128',
    '--volume',snapshot+':/consumer/source:ro','--entrypoint','/ros_entrypoint.sh',image,
    '/opt/consumer/bin/python','-I','/consumer/source/make-scenario.py','--inspect-image'],60000);
  const preflight={image_reference:imageReference,image:selected,facts:JSON.parse(factRaw)};
  await writeFile(outputRoot+'/native-preflight.json',JSON.stringify(preflight));
  await hostCommand('prepare-inputs',[snapshot+'/make-scenario.py','--native-preflight',outputRoot+'/native-preflight.json',
    '--image-reference',imageReference,'--image-id',image,'--requirements',snapshot+'/requirements.json','--output',prepared]);
  admitted=JSON.parse(await hostCommand('validate-inputs',[snapshot+'/make-scenario.py','--validate-prepared',prepared,'--image-id',image,'--case',mode]));

  runId=admitted.run_id;
  await writeFile(output+'/context-admission.json',JSON.stringify(admitted,null,2));
  acquisitionAttempted=true;

  const overrides={
    container:'podman',ROS_DOMAIN_ID:'191',ROBOTICS_RUN_ID:runId,ROBOTICS_DOMAIN_ID:'nav2',
    FASTRTPS_DEFAULT_PROFILES_FILE:'/consumer/source/fastdds.xml',RMW_FASTRTPS_USE_QOS_FROM_XML:'1',
    RMW_IMPLEMENTATION:'rmw_fastrtps_cpp',LIBGL_ALWAYS_SOFTWARE:'1',HOME:'/tmp',NAV2_IMAGE_CONFIG_ID:image,
  };
  const inherited=Object.fromEntries((selected.Config.Env??[]).map(value=>{const i=value.indexOf('=');return [value.slice(0,i),value.slice(i+1)]}));
  const env=Object.entries({...inherited,...overrides}).map(([key,value])=>key+'='+value);
  composition={
    command:admitted.launch,entrypoint:['/ros_entrypoint.sh'],env,
    mounts:[
      {source:snapshot,destination:'/consumer/source',readOnly:true,type:'bind'},
      {source:prepared,destination:'/consumer/inputs',readOnly:true,type:'bind'},
      {source:output,destination:'/evidence',readOnly:false,type:'bind'},
    ],
    hostConfig:{NetworkMode:'none',IpcMode:'private',Privileged:false,ReadonlyRootfs:false,Memory:2147483648,PidsLimit:512},
  };
  const createRaw=await command('create',['create','--name',name,'--stop-signal','SIGINT','--network','none','--ipc','private',
    '--memory','2147483648','--cpus','2','--pids-limit','512','--label','org.example.nav2.owner='+owner,
    ...Object.entries(overrides).flatMap(([key,value])=>['--env',key+'='+value]),
    '--volume',snapshot+':/consumer/source:ro','--volume',prepared+':/consumer/inputs:ro',
    '--volume',output+':/evidence',image,...admitted.launch]);
  await writeFile(output+'/native-create.stdout',createRaw);
  cid=createdId(createRaw);
  const acquired=await admitAndStart(command,{cid,image,owner,name,composition});
  await writeFile(output+'/native-acquired.json',JSON.stringify(acquired));
  // BasicNavigator sets the initial AMCL pose before waiting for full activation.
  // Waiting for the navigation stack here could depend on that initialization.
  await writeFile(output+'/native-before.json',await command('inspect-before',['inspect',cid]));
  workerSettled=false;
  const preparation=await jobs.run({executable:'/usr/bin/podman',
    args:['exec',cid,'/ros_entrypoint.sh','/opt/consumer/bin/python','/consumer/source/workload.py',
      '--scenario','/consumer/inputs/scenario.json','--prepared','/consumer/inputs','--image-id',image,'--case',mode,...workerConfiguration(admitted.configuration),'--run-id',runId,'--domain-id','nav2','--output','/evidence/prepare','--prepare-only'],
    timeoutMs:180000,maxBufferBytes:1048576,env:{PATH:'/usr/bin:/bin',HOME:process.env.HOME},extendEnv:false});
  events.push({op:'actual-prepare-worker',ok:preparation.ok,exitCode:preparation.exitCode,signal:preparation.signal,
    timedOut:preparation.timedOut,canceled:preparation.canceled,durationMs:preparation.durationMs});
  await writeFile(output+'/prepare-job.json',JSON.stringify({ok:preparation.ok,exitCode:preparation.exitCode,signal:preparation.signal,
    timedOut:preparation.timedOut,canceled:preparation.canceled,durationMs:preparation.durationMs}));
  await writeFile(output+'/prepare.log',preparation.stdout+preparation.stderr);
  workerSettled=await proveWorkerAbsent('prepare',preparation);
  if(!preparation.ok||!workerSettled)throw new Error('actual Nav2 preparation or settlement refused');
  recorder=jobs.run({executable:'/usr/bin/podman',
    args:['exec',cid,'/ros_entrypoint.sh','/opt/consumer/bin/python','/consumer/source/record-topics.py',
      '--output','/evidence/bag','--facts-dir','/evidence/recorder-facts','--run-id',runId,
      '--domain-id','nav2','--startup-timeout-sec','20','--max-lifetime-sec','180'],
    timeoutMs:210000,maxBufferBytes:1048576,env:{PATH:'/usr/bin:/bin',HOME:process.env.HOME},extendEnv:false});
  let earlyResult;
  recorder.then(result=>{earlyResult=result;});
  const readyDeadline=performance.now()+25000;
  while(true){
    if(performance.now()>=readyDeadline)throw new Error('recorder readiness deadline');
    if(earlyResult)throw new Error('recorder exited before readiness');
    try{
      const ready=JSON.parse(await readFile(output+'/recorder-facts/ready.json','utf8'));
      if(ready.run_id!==runId||ready.domain_id!=='nav2')throw new Error('foreign recorder readiness');
      break;
    }catch(error){if(error.code!=='ENOENT')throw error;}
    await new Promise(resolve=>setTimeout(resolve,100));
  }
  const workerArgs=['exec',cid,'/ros_entrypoint.sh','/opt/consumer/bin/python','/consumer/source/workload.py',
    '--scenario','/consumer/inputs/scenario.json','--prepared','/consumer/inputs','--image-id',image,'--case',mode,...workerConfiguration(admitted.configuration),'--run-id',runId,'--domain-id','nav2','--output','/evidence/'+mode,'--already-initialized'];
  await writeFile(output+'/worker-source-before.json',JSON.stringify({sha256:workerSha,argv:workerArgs}));
  workerSettled=false;
  const result=await jobs.run({executable:'/usr/bin/podman',args:workerArgs,timeoutMs:180000,maxBufferBytes:1048576,env:{PATH:'/usr/bin:/bin',HOME:process.env.HOME},extendEnv:false});
  events.push({op:'actual-'+mode+'-worker',ok:result.ok,exitCode:result.exitCode,signal:result.signal,timedOut:result.timedOut,canceled:result.canceled,durationMs:result.durationMs});
  await writeFile(output+'/worker.log',result.stdout+result.stderr);
  workerSettled=await proveWorkerAbsent(mode,result);
  const after=createHash('sha256').update(await readFile(snapshot+'/workload.py')).digest('hex');
  await writeFile(output+'/worker-source-after.json',JSON.stringify({sha256:after}));
  if(after!==workerSha)throw new Error('immutable native workload snapshot changed');
  if(!result.ok||!workerSettled)throw new Error('actual Nav2 case worker or settlement refused');
}catch(error){failure=error;await writeFile(output+'/failure.json',JSON.stringify({name:error.name,message:error.message}));}
finally{
  // A lost create response cannot establish absence of native effects.
  if(!cid&&acquisitionAttempted){
    try{
      const recovered=await recoverCreated(command,{image,owner,name});
      if(recovered){
        cid=recovered.Id;
        await writeFile(output+'/recovered-acquisition.json',JSON.stringify({id:cid,owner,name,image}));
      }
    }catch(error){failure??=error;await writeFile(output+'/acquisition-quarantine.json',JSON.stringify({name:error.name,message:error.message}));}
  }
  if(recorder&&cid){
    try{
      await writeFile(output+'/recorder-facts/stop.json',JSON.stringify({run_id:runId,domain_id:'nav2'})+'\n',{flag:'wx'});
      const result=await recorder;
      await writeFile(output+'/recorder.log',result.stdout+result.stderr);
      const state=JSON.parse(await readFile(output+'/recorder-facts/capture-state.json','utf8'));
      if(state.run_id!==runId||state.domain_id!=='nav2'||!Number.isSafeInteger(state.pid)||state.pid<=0||
         !state.finished_monotonic_ns||result.timedOut||result.canceled||result.signal||![0,1].includes(result.exitCode))
        throw new Error('native recorder settlement is unproven');
      const absent=await command('recorder-process-absent',['exec',cid,'/usr/bin/python3','-c',
        'import os,sys;print(os.path.exists("/proc/"+sys.argv[1]))',String(state.pid)]);
      if(absent.trim()!=='False')throw new Error('native recorder process still present');
      recorderSettled=true;
      await writeFile(output+'/recorder-job.json',JSON.stringify({ok:result.ok,exitCode:result.exitCode,
        timedOut:result.timedOut,canceled:result.canceled,durationMs:result.durationMs}));
      if(!result.ok||state.capture_status!=='complete'||state.closure_confirmed!==true)
        throw new Error('native bag did not close successfully');
    }catch(error){failure??=error;await writeFile(output+'/recorder-drain-refusal.json',JSON.stringify({name:error.name,message:error.message}));}
  }
  if(cid&&workerSettled&&(!recorder||recorderSettled)){
    try{
      const native=JSON.parse(await command('inspect-owner',['inspect',cid]))[0];
      exactOwner(native);
      await writeFile(output+'/native-last.json',JSON.stringify(native));
      const unstarted=await removeUnstartedOwned(command,native,{cid,image,owner,name});
      if(!unstarted){
      try{const logs=await command('logs',['logs','--tail','1000',cid]);await writeFile(output+'/simulation.log',logs)}catch(error){failure??=error;await writeFile(output+'/diagnostic-capture-failure.json',JSON.stringify({name:error.name,message:error.message}))}
      await command('stop',['stop','--time','20',cid],30000);
      const waitRaw=await command('wait',['wait',cid],30000);
      await writeFile(output+'/native-wait.stdout',waitRaw);
      const wait=nativeWaitExit(waitRaw);
      const stopped=exactOwner(JSON.parse(await command('inspect-stopped',['inspect',cid]))[0]);
      await writeFile(output+'/native-stopped.json',JSON.stringify({native:stopped,waitExitCode:Number(wait)}));
      if(stopped.State.Running)throw new Error('native actor is still running');
      if(stopped.State.OOMKilled || stopped.State.ExitCode!==0 || Number(wait)!==0){
        failure??=new Error('native actor did not settle successfully');
        await writeFile(output+'/native-settlement-refusal.json',JSON.stringify({exitCode:stopped.State.ExitCode,waitExitCode:Number(wait),oomKilled:stopped.State.OOMKilled}));
      }
      try{await command('terminal-logs',['logs','--tail','1000',cid])}catch(error){failure??=error;await writeFile(output+'/terminal-diagnostic-failure.json',JSON.stringify({name:error.name,message:error.message}))}
      await command('remove',['rm',cid]);
      }
      const left=(await command('remaining',['ps','--all','--quiet','--filter','label=org.example.nav2.owner='+owner])).trim();
      if(left)throw new Error('owned native container remains');
      await writeFile(output+'/cleanup.json',JSON.stringify({owner,containerId:cid,remaining:[],removedBeforeStart:unstarted,worker_settled:workerSettled,recorder_settled:recorderSettled}));
    }catch(error){failure??=error;await writeFile(output+'/cleanup-failure.json',JSON.stringify({name:error.name,message:error.message}));}
  }
  if(!(workerSettled&&(!recorder||recorderSettled))&&acquisitionAttempted) await writeFile(output+'/native-quarantine.json',JSON.stringify({owner,name,cid,image,
    workerSettled,recorderSettled,reason:'native producer quiescence is unproven; no destructive cleanup admitted'}));
  await writeFile(output+'/jobs-events.json',JSON.stringify(events,null,2));
  await writeFile(output+'/host-boundary.json',JSON.stringify({node:process.version,publicPackage:'@robotics-runtime/host',nativeQualification:false}));
}

await writeFile(output+'/native-run.json',JSON.stringify({started_at:startedAt,finished_at:new Date().toISOString()}));
if (admitted&&recorderSettled&&workerSettled) {
  try {
    const inputs=await hostCommand('finalize-inputs',[snapshot+'/finalize.py','--prepared',prepared,'--capture',output,'--from-native']);
    await writeFile(outputRoot+'/evaluation-inputs.json',inputs);
  } catch(error) {failure??=error;}
}
if(failure)throw failure;
const raw=await readFile(output+'/'+mode+'/workload.json');

await writeFile(output+'/checkpoint.json',JSON.stringify({scope:'Actual Nav2 consumer observation; core policy evaluation is separate',runId,owner,image,case:mode,workloadSha256:createHash('sha256').update(raw).digest('hex')},null,2));

return {runId,owner,image,case:mode,prepared,output,evaluationInputs:outputRoot+'/evaluation-inputs.json'};
}

function workerConfiguration(config) {
  return ['--goal-x',String(config.goal.x),'--goal-y',String(config.goal.y),
    '--action-budget-sec',String(config.action_budget_sec),'--application-timeout-sec',String(config.application_timeout_sec),
    '--max-pose-error-m',String(config.max_final_pose_error_m),'--min-displacement-m',String(config.min_displacement_m),
    '--max-observation-age-sec',String(config.max_observation_age_sec),'--odometry-frame',config.odometry_frame,
    ...config.required_tf_edges.flatMap(pair=>['--required-tf-edge',...pair])];
}

if (process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [output,root,imageReference,mode,requirements,python]=process.argv.slice(2);
  if (![output,root,imageReference,mode,requirements,python].every(Boolean))
    throw new Error('usage: native-check.mjs OUTPUT SOURCE REPODIGEST CASE REQUIREMENTS PYTHON');
  const {Context,Jobs}=await import('@robotics-runtime/host');
  const context=new Context(),fiber=context.plugin(Jobs,{timeoutMs:240000,maxBufferBytes:8*1048576});
  await fiber.await();
  try { console.log(JSON.stringify(await runNative({output,root,imageReference,mode,requirements,python},context.jobs))); }
  finally { await fiber.dispose(); await fiber.await(); }
}
