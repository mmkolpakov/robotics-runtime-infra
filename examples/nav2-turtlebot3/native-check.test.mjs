import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {mkdtemp, mkdir, writeFile, rm, readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve, dirname} from 'node:path';
import assert from 'node:assert/strict';
import test from 'node:test';
import {runNative} from './native-check.mjs';

const root=dirname(fileURLToPath(import.meta.url));
const image='sha256:'+'a'.repeat(64), reference='localhost/nav2@sha256:'+'b'.repeat(64), cid='c'.repeat(64);
const configuration={goal:{x:1,y:-0.5},action_budget_sec:120,application_timeout_sec:2,max_final_pose_error_m:0.35,min_displacement_m:0.5,max_observation_age_sec:2,odometry_frame:'odom',required_tf_edges:[['map','odom']],readiness:{}};
const result=(stdout='')=>({ok:true,exitCode:0,stdout,stderr:'',signal:null,timedOut:false,canceled:false});

test('missing inputs refuse before loading the optional host package or acquiring actors',()=>{
  const executed=spawnSync(process.execPath,[resolve(root,'native-check.mjs')],{encoding:'utf8'});
  assert.notEqual(executed.status,0);
  assert.match(executed.stderr,/usage:/);
  assert.doesNotMatch(executed.stderr,/ERR_MODULE_NOT_FOUND/);
});

async function fixture(t,{mode='success',badInput=false,badImage=false,badActor=false,badEntrypoint=false,local=false,bareImage=false,lostCreate=false,storageExit=1,storageTimeout=false,workerBeforeReady=false,recorderBeforeReady=false,foreignRecorder=false,malformedRecorder=false,workerAfterReady=false,unsettledWorker=false}={}) {
  const directory=await mkdtemp(resolve(tmpdir(),'nav2-driver-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const output=resolve(directory,'run'), requirements=resolve(directory,'requirements.json'), capture=resolve(output,'capture');
  await writeFile(requirements,'{}');
  const calls=[];
  let actor,started=false,removed=false,releaseWorker;
  const recorderReady=new Promise(resolve=>{releaseWorker=resolve;});
  const packageImage={Id:bareImage?image.slice(7):image,RepoDigests:badImage?[]:[reference],Config:{Entrypoint:['/ros_entrypoint.sh'],Env:['PATH=/usr/bin:/bin'],StopSignal:'SIGINT'}};
  const jobs={timeoutMs:240000,async run(request){
    const a=request.args;
    calls.push({executable:request.executable,args:a});
    if(request.executable==='/fixture/python'){
      if(a.includes('--native-preflight')){await mkdir(resolve(output,'inputs'));return result('{}');}
      if(a.includes('--validate-prepared')){
        if(badInput&&!a.includes('--complete-capture')) return {...result(),ok:false,exitCode:2,stderr:'input mismatch'};
        return result(JSON.stringify({run_id:'run-fixture',domain_id:'nav2',configuration,image_id:image,image_reference:reference,launch:['ros2','launch','/opt/sdk-policy/native_simulation.launch.py']}));
      }
      return result(JSON.stringify({run_id:'run-fixture'}));
    }
    assert.equal(request.executable,'/usr/bin/podman');
    if(a[0]==='image') return result(JSON.stringify([packageImage]));
    if(a[0]==='run') return result('{}');
    if(a[0]==='create'){
      if(lostCreate)return {...result(),ok:false,exitCode:0,timedOut:true};
      const env=[],mounts=[];
      for(let i=0;i<a.length;i++){
        if(a[i]==='--env')env.push(a[i+1]);
        if(a[i]==='--volume'){const [source,destination,option]=a[i+1].split(':');mounts.push({Source:source,Destination:destination,RW:option!=='ro',Type:'bind'});}
      }
      const overrides=new Map(env.map(value=>[value.slice(0,value.indexOf('=')),value]));
      actor={Id:cid,Image:image,Name:'/'+a[a.indexOf('--name')+1],Config:{
        Labels:{'org.example.nav2.owner':a[a.indexOf('--label')+1].split('=')[1]},
        StopSignal:'SIGINT',Entrypoint:badEntrypoint?'/bin/sh':'/ros_entrypoint.sh',
        Cmd:a.slice(a.indexOf(image)+1),Env:[...packageImage.Config.Env.filter(x=>!overrides.has(x.split('=')[0])),...env]},
        Mounts:mounts,HostConfig:{NetworkMode:'none',IpcMode:'private',Privileged:false,ReadonlyRootfs:false,Memory:2147483648,PidsLimit:512},
        State:{Running:false,Pid:0,Status:'created',ExitCode:0,OOMKilled:false}};
      if(badActor)actor.Config.Env.push('FOREIGN=value');
      return result(cid+'\n');
    }
    if(a[0]==='inspect')return result(JSON.stringify([actor]));
    if(a[0]==='start'){started=true;actor.State={Running:true,Pid:100,Status:'running',ExitCode:0,OOMKilled:false};return result(cid);}
    if(a[0]==='exec'){
      if(a.includes('/usr/bin/python3'))return result('False\n');
      const {createHash}=await import('node:crypto');
      if(a.includes('/consumer/source/record-topics.py')){
        await mkdir(resolve(capture,'recorder-facts'),{recursive:true});
        if(!recorderBeforeReady){
          const recorder=await readFile(resolve(output,'source/record-topics.py'));
          await writeFile(resolve(capture,'recorder-facts/ready.json'),malformedRecorder?'[]':JSON.stringify({
            run_id:foreignRecorder?'run-foreign':'run-fixture',domain_id:'nav2',pid:201,
            source_sha256:createHash('sha256').update(recorder).digest('hex'),ready_monotonic_ns:2,
          }));
        }
        if(!unsettledWorker)releaseWorker(!recorderBeforeReady&&!foreignRecorder&&!malformedRecorder);
        if(recorderBeforeReady){
          await writeFile(resolve(capture,'recorder-facts/capture-state.json'),JSON.stringify({
            run_id:'run-fixture',domain_id:'nav2',pid:201,finished_monotonic_ns:10,
            capture_status:'incomplete',closure_confirmed:false,
          }));
          return {...result(),ok:false,exitCode:1,stderr:'recorder failed before readiness'};
        }
        const requestPath=resolve(capture,'recorder-facts/stop.json');
        const deadline=performance.now()+2000;
        while(true){
          try{await readFile(requestPath);break;}
          catch(error){if(error.code!=='ENOENT'||performance.now()>=deadline)throw error;}
          await new Promise(resolve=>setTimeout(resolve,5));
        }
        await writeFile(resolve(capture,'recorder-facts/capture-state.json'),JSON.stringify({
          run_id:'run-fixture',domain_id:'nav2',pid:201,finished_monotonic_ns:10,
          capture_status:'complete',closure_confirmed:true,
        }));
        return result();
      }
      assert.ok(a.includes('--wait-for-recorder'));
      await mkdir(resolve(capture,mode),{recursive:true});
      const worker=await readFile(resolve(output,'source/workload.py'));
      const workerFact={run_id:'run-fixture',domain_id:'nav2',pid:200,
        source_sha256:createHash('sha256').update(worker).digest('hex')};
      await writeFile(resolve(capture,mode,'worker-process.json'),JSON.stringify(workerFact));
      if(workerBeforeReady)return {...result(),ok:false,exitCode:1,stderr:'worker failed before readiness'};
      await writeFile(resolve(capture,mode,'native-ready.json'),JSON.stringify({
        ...workerFact,ready_monotonic_ns:1,
      }));
      if(unsettledWorker){
        if(!request.cancelSignal.aborted)
          await new Promise(resolve=>request.cancelSignal.addEventListener('abort',resolve,{once:true}));
        return {...result(),ok:false,exitCode:undefined,canceled:true,signal:'SIGTERM'};
      }
      const recording=await recorderReady;
      await writeFile(resolve(capture,mode,'workload.json'),JSON.stringify({run_id:'run-fixture',case:mode,goal_issued:recording}));
      if(!recording||workerAfterReady)return {...result(),ok:false,exitCode:1,stderr:'worker refused'};
      return result();
    }
    if(a[0]==='logs')return result();
    if(a[0]==='stop'){actor.State={Running:false,Pid:0,Status:'exited',ExitCode:0,OOMKilled:false};return result();}
    if(a[0]==='wait')return result('0\n');
    if(a[0]==='rm'){removed=true;return result(cid);}
    if(a[0]==='ps')return result();
    if(a[0]==='container')return {...result(),ok:storageExit===0,exitCode:storageExit,timedOut:storageTimeout};
    throw new Error('unexpected operation '+JSON.stringify(a));
  }};
  const promise=runNative({output,root,imageReference:local?image:reference,requirements,python:'/fixture/python',mode},jobs);
  return {promise,calls,get started(){return started;},get removed(){return removed;},output};
}

for(const mode of ['success','cancel','timeout','server-failure']){
  test('admitted '+mode+' uses owned lifecycle, settles producers and finalizes current inputs',async t=>{
    const f=await fixture(t,{mode});
    await f.promise;
    assert.equal(f.calls.filter(c=>c.args[0]==='create').length,1);
    assert.equal(f.calls.filter(c=>c.args[0]==='start').length,1);
    const workers=f.calls.filter(c=>c.args.includes('/consumer/source/workload.py'));
    assert.equal(workers.length,1);
    assert.ok(workers[0].args.includes('--wait-for-recorder'));
    const workerIndex=f.calls.indexOf(workers[0]);
    const recorderIndex=f.calls.findIndex(c=>c.args.includes('/consumer/source/record-topics.py'));
    assert.ok(workerIndex>=0&&recorderIndex>workerIndex);
    assert.equal(f.started,true);
    assert.equal(f.removed,true);
    assert.ok(f.calls.some(c=>c.args.includes('--from-native')));
    assert.ok(f.calls.some(c=>c.args.some(a=>a.endsWith('/finalize.py'))));
  });
}
for(const fault of ['workerBeforeReady','recorderBeforeReady','foreignRecorder','malformedRecorder','workerAfterReady']){
  test(fault+' settles the one owned worker before removing the actor',async t=>{
    const f=await fixture(t,{[fault]:true});
    await assert.rejects(f.promise);
    assert.equal(f.calls.filter(c=>c.args.includes('/consumer/source/workload.py')).length,1);
    if(fault==='workerBeforeReady')assert.ok(!f.calls.some(c=>c.args.includes('/consumer/source/record-topics.py')));
    assert.ok(f.calls.some(c=>c.args.includes('/usr/bin/python3')&&c.args.at(-1)==='200'));
    assert.equal(f.removed,true);
    if(['recorderBeforeReady','foreignRecorder','malformedRecorder'].includes(fault)){
      const report=JSON.parse(await readFile(resolve(f.output,'capture/success/workload.json'),'utf8'));
      assert.equal(report.goal_issued,false);
    }
  });
}

test('recorder failure cancels the worker and retains the actor when settlement is unproven',async t=>{
  const f=await fixture(t,{recorderBeforeReady:true,unsettledWorker:true});
  await assert.rejects(f.promise,/recorder exited before readiness/);
  assert.equal(f.removed,false);
  const detail=JSON.parse(await readFile(resolve(f.output,'capture/native-quarantine.json'),'utf8'));
  assert.equal(detail.workerSettled,false);
  assert.equal(detail.recorderSettled,true);
});

test('Podman bare image Config ID preserves the exact image binding and raw preflight',async t=>{
  const f=await fixture(t,{bareImage:true});
  await f.promise;
  const preflight=JSON.parse(await readFile(resolve(f.output,'native-preflight.json'),'utf8'));
  assert.equal(preflight.image.Id,image.slice(7));
  assert.equal(f.started,true);
  assert.equal(f.removed,true);
});
test('local Config ID supports the same isolated path without a registry publication',async t=>{
  const f=await fixture(t,{local:true});
  await f.promise;
  assert.equal(f.started,true);
});
for(const flag of ['badInput','badImage']){
  test(flag+' refuses before simulator create or start',async t=>{
    const f=await fixture(t,{[flag]:true});
    await assert.rejects(f.promise);
    assert.equal(f.calls.filter(c=>['create','start'].includes(c.args[0])).length,0);
  });
}
test('an altered acquired environment refuses start and removes only the owned unstarted actor',async t=>{
  const f=await fixture(t,{badActor:true});
  await assert.rejects(f.promise,/environment differs/);
  assert.equal(f.started,false);
  assert.equal(f.removed,true);
});

test('Podman container entrypoint string is distinct from the image entrypoint array',async t=>{
  const f=await fixture(t);
  await f.promise;
  const preflight=JSON.parse(await readFile(resolve(f.output,'native-preflight.json'),'utf8'));
  const acquired=JSON.parse(await readFile(resolve(f.output,'capture/native-acquired.json'),'utf8'));
  assert.deepEqual(preflight.image.Config.Entrypoint,['/ros_entrypoint.sh']);
  assert.equal(acquired.Config.Entrypoint,'/ros_entrypoint.sh');
  assert.equal(f.started,true);
});
test('an altered acquired entrypoint refuses start and removes only the owned unstarted actor',async t=>{
  const f=await fixture(t,{badEntrypoint:true});
  await assert.rejects(f.promise,/entrypoint/);
  assert.equal(f.started,false);
  assert.equal(f.removed,true);
});

for(const storageExit of [0,1,125]){
  test('lost create probes exact external storage with exit '+storageExit,async t=>{
    const f=await fixture(t,{lostCreate:true,storageExit});
    await assert.rejects(f.promise,/native operation refused: create/);
    assert.equal(f.started,false);
    const probe=f.calls.find(c=>c.args[0]==='container');
    assert.ok(probe);
    assert.deepEqual(probe.args.slice(0,3),['container','exists','--external']);
    assert.ok(probe.args[3].startsWith('nav2-'));
    assert.equal(f.calls.some(c=>c.args[0]==='rm'),false);
    const quarantine=resolve(f.output,'capture/acquisition-quarantine.json');
    if(storageExit===1)await assert.rejects(readFile(quarantine),{code:'ENOENT'});
    else assert.ok((await readFile(quarantine,'utf8')).length>0);
  });
}
test('timed out external storage lookup cannot establish absence',async t=>{
  const f=await fixture(t,{lostCreate:true,storageExit:1,storageTimeout:true});
  await assert.rejects(f.promise);
  assert.equal(f.started,false);
  assert.ok((await readFile(resolve(f.output,'capture/acquisition-quarantine.json'),'utf8')).length>0);
});
