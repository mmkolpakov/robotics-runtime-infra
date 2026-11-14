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

async function fixture(t,{mode='success',badInput=false,badImage=false,badActor=false,badEntrypoint=false,local=false,bareImage=false}={}) {
  const directory=await mkdtemp(resolve(tmpdir(),'nav2-driver-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const output=resolve(directory,'run'), requirements=resolve(directory,'requirements.json'), capture=resolve(output,'capture');
  await writeFile(requirements,'{}');
  const calls=[];
  let actor,started=false,removed=false,finishRecorder;
  const packageImage={Id:bareImage?image.slice(7):image,RepoDigests:badImage?[]:[reference],Config:{Entrypoint:['/ros_entrypoint.sh'],Env:['PATH=/usr/bin:/bin'],StopSignal:'SIGINT'}};
  const jobs={async run(request){
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
      if(a.includes('/consumer/source/record-topics.py')){
        await mkdir(resolve(capture,'recorder-facts'),{recursive:true});
        await writeFile(resolve(capture,'recorder-facts/ready.json'),JSON.stringify({run_id:'run-fixture',domain_id:'nav2'}));
        return new Promise(done=>{finishRecorder=done;});
      }
      const phase=a.includes('--prepare-only')?'prepare':mode;
      await mkdir(resolve(capture,phase),{recursive:true});
      const worker=await readFile(resolve(output,'source/workload.py'));
      const {createHash}=await import('node:crypto');
      await writeFile(resolve(capture,phase,'worker-process.json'),JSON.stringify({run_id:'run-fixture',domain_id:'nav2',pid:200,source_sha256:createHash('sha256').update(worker).digest('hex')}));
      if(phase!=='prepare'){
        await writeFile(resolve(capture,phase,'workload.json'),JSON.stringify({run_id:'run-fixture',case:mode}));
        await writeFile(resolve(capture,'recorder-facts/capture-state.json'),JSON.stringify({run_id:'run-fixture',domain_id:'nav2',pid:201,finished_monotonic_ns:10,capture_status:'complete',closure_confirmed:true}));
        finishRecorder(result());
      }
      return result();
    }
    if(a[0]==='logs')return result();
    if(a[0]==='stop'){actor.State={Running:false,Pid:0,Status:'exited',ExitCode:0,OOMKilled:false};return result();}
    if(a[0]==='wait')return result('0\n');
    if(a[0]==='rm'){removed=true;return result(cid);}
    if(a[0]==='ps')return result();
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
    assert.equal(f.started,true);
    assert.equal(f.removed,true);
    assert.ok(f.calls.some(c=>c.args.includes('--from-native')));
    assert.ok(f.calls.some(c=>c.args.some(a=>a.endsWith('/finalize.py'))));
  });
}
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
