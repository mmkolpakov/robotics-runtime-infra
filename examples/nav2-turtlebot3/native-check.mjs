import {createHash, randomUUID} from 'node:crypto';
import {chmod, mkdir, readFile, writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {Context, Jobs, isDisposed} from '@robotics-runtime/host';
import {admitContext} from './admit-context.mjs';
import {assertOwned, recoverCreated, createdId, nativeWaitExit, admitAndStart, removeUnstartedOwned} from './native-identity.mjs';

// Bounded published-host consumer. Application observations and core policy remain separate.
const output=resolve(process.argv[2]);
const root=resolve(process.argv[3]);
const image=process.argv[4];
const mode=process.argv[5]??'success';
const contextPath=process.argv[6], scenarioPath=process.argv[7], contractsExecutable=process.argv[8];
if(!contextPath||!scenarioPath||!contractsExecutable)throw new Error('public issued context, scenario and contracts CLI required');
if(!['success','cancel','timeout','server-failure'].includes(mode))throw new Error('closed native case required');
if(!/^sha256:[a-f0-9]{64}$/.test(image))throw new Error('immutable image identity required');
await mkdir(output,{recursive:true,mode:0o700});
const worker=await readFile(root+'/workload.py');
const workerSha=createHash('sha256').update(worker).digest('hex');
await writeFile(output+'/workload.py',worker,{flag:'wx'});
await chmod(output+'/workload.py',0o444);
const recorderSource=await readFile(root+'/record-topics.py');
await writeFile(output+'/record-topics.py',recorderSource,{flag:'wx'});
await chmod(output+'/record-topics.py',0o444);
const middlewareSource=await readFile(root+'/fastdds.xml');
const middlewareSha=createHash('sha256').update(middlewareSource).digest('hex');
await writeFile(output+'/fastdds.xml',middlewareSource,{flag:'wx',mode:0o444});
const owner='nav2-'+randomUUID();
const name=owner;
const ctx=new Context();
const fiber=ctx.plugin(Jobs,{timeoutMs:240000,maxBufferBytes:1048576});
await fiber.await();
const jobs=ctx.jobs;
const events=[];
let runId;
const exactOwner=native=>assertOwned(native,{cid,image,owner,name});
const command=async(op,args,timeoutMs=15000)=>{
  const result=await jobs.run({executable:'/usr/bin/podman',args,timeoutMs,maxBufferBytes:1048576,env:{PATH:'/usr/bin:/bin',HOME:process.env.HOME},extendEnv:false});
  events.push({op,ok:result.ok,exitCode:result.exitCode,signal:result.signal,timedOut:result.timedOut,canceled:result.canceled,durationMs:result.durationMs});
  await writeFile(output+'/native-'+op+'.stdout',result.stdout);
  await writeFile(output+'/native-'+op+'.stderr',result.stderr);
  if(!result.ok)throw Object.assign(new Error('native operation refused: '+op),{cause:result});
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
  const admitted=await admitContext(jobs,{contextPath,scenarioPath,schemaPath:root+'/nav2.schema.json',contractsExecutable,output,domainId:'nav2',mode});
  if(admitted.scenario.data_plane_policy.middleware_configuration_sha256!==middlewareSha)throw new Error('foreign middleware configuration');
  runId=admitted.runId;
  await writeFile(output+'/context-admission.json',JSON.stringify(admitted,null,2));
  acquisitionAttempted=true;
  const createRaw=await command('create',['create','--name',name,'--stop-signal','SIGINT','--network','none','--ipc','private','--label','org.example.nav2.owner='+owner,'--env','ROS_DOMAIN_ID=191','--env','FASTRTPS_DEFAULT_PROFILES_FILE=/consumer/fastdds.xml','--env','RMW_FASTRTPS_USE_QOS_FROM_XML=1','--volume',output+'/workload.py:/consumer/workload.py:ro','--volume',output+'/record-topics.py:/consumer/record-topics.py:ro','--volume',output+'/scenario.json:/consumer/scenario.json:ro','--volume',output+'/fastdds.xml:/consumer/fastdds.xml:ro','--volume',output+':/evidence',image]);
  await writeFile(output+'/native-create.stdout',createRaw);
  cid=createdId(createRaw);
  const acquired=await admitAndStart(command,{cid,image,owner,name});
  await writeFile(output+'/native-acquired.json',JSON.stringify(acquired));
  // BasicNavigator sets the initial AMCL pose before waiting for full activation.
  // Waiting for the navigation stack here could depend on that initialization.
  await writeFile(output+'/native-before.json',await command('inspect-before',['inspect',cid]));
  workerSettled=false;
  const prepared=await jobs.run({executable:'/usr/bin/podman',
    args:['exec',cid,'/ros_entrypoint.sh','/opt/consumer/bin/python','/consumer/workload.py',
      '--scenario','/consumer/scenario.json','--case',mode,'--run-id',runId,'--domain-id','nav2','--output','/evidence/prepare','--prepare-only'],
    timeoutMs:180000,maxBufferBytes:1048576,env:{PATH:'/usr/bin:/bin',HOME:process.env.HOME},extendEnv:false});
  events.push({op:'actual-prepare-worker',ok:prepared.ok,exitCode:prepared.exitCode,signal:prepared.signal,
    timedOut:prepared.timedOut,canceled:prepared.canceled,durationMs:prepared.durationMs});
  await writeFile(output+'/prepare-job.json',JSON.stringify({ok:prepared.ok,exitCode:prepared.exitCode,signal:prepared.signal,
    timedOut:prepared.timedOut,canceled:prepared.canceled,durationMs:prepared.durationMs}));
  await writeFile(output+'/prepare.log',prepared.stdout+prepared.stderr);
  workerSettled=await proveWorkerAbsent('prepare',prepared);
  if(!prepared.ok||!workerSettled)throw new Error('actual Nav2 preparation or settlement refused');
  recorder=jobs.run({executable:'/usr/bin/podman',
    args:['exec',cid,'/ros_entrypoint.sh','/opt/consumer/bin/python','/consumer/record-topics.py',
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
  const workerArgs=['exec',cid,'/ros_entrypoint.sh','/opt/consumer/bin/python','/consumer/workload.py',
    '--scenario','/consumer/scenario.json','--case',mode,'--run-id',runId,'--domain-id','nav2','--output','/evidence/'+mode,'--already-initialized'];
  await writeFile(output+'/worker-source-before.json',JSON.stringify({sha256:workerSha,argv:workerArgs}));
  workerSettled=false;
  const result=await jobs.run({executable:'/usr/bin/podman',args:workerArgs,timeoutMs:180000,maxBufferBytes:1048576,env:{PATH:'/usr/bin:/bin',HOME:process.env.HOME},extendEnv:false});
  events.push({op:'actual-'+mode+'-worker',ok:result.ok,exitCode:result.exitCode,signal:result.signal,timedOut:result.timedOut,canceled:result.canceled,durationMs:result.durationMs});
  await writeFile(output+'/worker.log',result.stdout+result.stderr);
  workerSettled=await proveWorkerAbsent(mode,result);
  const after=createHash('sha256').update(await readFile(output+'/workload.py')).digest('hex');
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
      await writeFile(output+'/cleanup.json',JSON.stringify({owner,containerId:cid,remaining:[],removedBeforeStart:unstarted}));
    }catch(error){failure??=error;await writeFile(output+'/cleanup-failure.json',JSON.stringify({name:error.name,message:error.message}));}
  }
  if(workerSettled&&(!recorder||recorderSettled)){await fiber.dispose();await fiber.await();}
  else if(acquisitionAttempted) await writeFile(output+'/native-quarantine.json',JSON.stringify({owner,name,cid,image,
    workerSettled,recorderSettled,reason:'native producer quiescence is unproven; no destructive cleanup admitted'}));
  await writeFile(output+'/jobs-events.json',JSON.stringify(events,null,2));
  await writeFile(output+'/host-boundary.json',JSON.stringify({node:process.version,publicPackage:'@robotics-runtime/host',pluginDisposed:isDisposed(fiber),nativeQualification:false}));
}
if(failure)throw failure;
const raw=await readFile(output+'/'+mode+'/workload.json');
await writeFile(output+'/checkpoint.json',JSON.stringify({scope:'Actual Nav2 consumer observation; core policy evaluation is separate',runId,owner,image,case:mode,workloadSha256:createHash('sha256').update(raw).digest('hex')},null,2));
