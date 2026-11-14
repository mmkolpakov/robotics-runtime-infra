import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, readFile, rm, symlink, writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Px4Native} from '../src/plugins/px4-provider/index.js';
import {Context,referenceFile} from '@robotics-runtime/host';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';

const cid='a'.repeat(64), eid='b'.repeat(64);
const ids={source_system_id:245,source_component_id:190,target_system_id:1,target_component_id:1};

async function setup(t:test.TestContext, inspect:Record<string,unknown>, startStatus=200, onStart?:()=>Promise<void>) {
  const directory=await mkdtemp(join(tmpdir(),'px4-docker-unit-')), socketPath=join(directory,'engine.sock');
  const calls:string[]=[],requests:string[]=[],facts:Array<{name:string;value:any}>=[];
  const server=createServer((req,res)=>{
    const path=req.url ?? '';calls.push(req.method+' '+path);
    if(path.endsWith('/containers/'+cid+'/exec')){
      let body='';req.on('data',chunk=>{body+=String(chunk)});
      req.on('end',()=>{requests.push(body);res.writeHead(201,{'content-type':'application/json'});res.end(JSON.stringify({Id:eid}))});
    }else if(path.endsWith('/exec/'+eid+'/start')){
      if(startStatus===-1){res.writeHead(200,{'content-type':'application/vnd.docker.raw-stream'});res.write('pending')}
      else if(startStatus===-2){res.writeHead(200,{'content-type':'application/vnd.docker.raw-stream'});res.end(Buffer.alloc(524289))}
      else if(onStart){void onStart().then(()=>{res.writeHead(startStatus,{'content-type':'application/vnd.docker.raw-stream'});res.end('done')}).catch(()=>{res.writeHead(500);res.end('failed')})}
      else{res.writeHead(startStatus,{'content-type':'application/vnd.docker.raw-stream'});res.end(startStatus===200?'done':'failed')}
    }else if(path.endsWith('/exec/'+eid+'/json')){
      res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify(inspect));
    }else {res.writeHead(404);res.end()}
  });
  await new Promise<void>(resolve=>server.listen(socketPath,resolve));
  t.after(async()=>{await new Promise<void>((resolve,reject)=>server.close(error=>error?reject(error):resolve()));await rm(directory,{recursive:true,force:true})});
  const provider:any=Object.create(Px4Native.prototype);
  Object.assign(provider,{config:{mode:'native-sdk-v2',socketPath},loggerStarted:true,loggerClosed:false,
    primaryId:cid,engine:{facts:{clientApi:'1.41'}},ownerId:'run-1',workerArchive:'/run/robotics/archive',deadline:120000,
    workerState:'not-started',refs:[]});
  provider.currentActor=async()=>({container:{Id:cid}});
  provider.processFact=async()=>({facts:{px4_process:{pid:2,start_ticks:'12',executable_sha256:'c'.repeat(64),instance:0}},
    ref:{uri:'file:///process.json',sha256:'d'.repeat(64),size_bytes:1}});
  provider.nativeFact=async(name:string,value:unknown)=>{facts.push({name,value});const ref={uri:'file:///'+name,sha256:'e'.repeat(64),size_bytes:1};provider.refs.push(ref);return ref};
  return {provider,calls,requests,facts};
}

test('one native exec is settled only after start, stream end and matching inspect',async t=>{
  const {provider,calls,requests}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:0});
  await provider.executeNative('land',ids,new AbortController().signal);
  assert.equal(provider.workerState,'settled');
  assert.deepEqual(JSON.parse(requests[0]!).Cmd.slice(0,6),['/usr/bin/timeout','--signal=TERM','--kill-after=5s','120s','/opt/px4-native-venv/bin/python','-B']);
  assert.equal(calls.filter(x=>x.includes('/containers/')&&x.endsWith('/exec')).length,1);
  assert.equal(calls.filter(x=>x.endsWith('/start')).length,1);
  assert.equal(calls.filter(x=>x.endsWith('/json')).length,1);
  await assert.rejects(provider.executeNative('land',ids,new AbortController().signal),/already invoked/);
});

test('running or foreign exec remains unresolved and cannot close or export',async t=>{
  for(const observed of [{ID:eid,ContainerID:cid,Running:true,ExitCode:null},{ID:eid,ContainerID:cid,Running:false,ExitCode:null},{ID:eid,ContainerID:'f'.repeat(64),Running:false,ExitCode:0}]){
    const {provider}=await setup(t,observed);
    await assert.rejects(provider.executeNative('land',ids,new AbortController().signal),/settlement/);
    assert.equal(provider.workerState,'unresolved');
    await assert.rejects(provider.closeNativeMeasurement(new AbortController().signal),/settlement/);
    await assert.rejects(provider.exportEvidence(new AbortController().signal),/settlement or logger closure/);
  }
});

test('failed start is not interpreted as settled',async t=>{
  const {provider,calls}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:0},500);
  await assert.rejects(provider.executeNative('land',ids,new AbortController().signal));
  assert.equal(provider.workerState,'unresolved');
  assert.equal(calls.filter(x=>x.endsWith('/json')).length,0);
});


test('logger failure prevents export even after native worker settles',async t=>{
  const {provider}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:0});
  provider.workerState='settled';
  provider.loggerCommand=async(command:string)=>({result:command==='stop'
    ? {ok:false,exitCode:1,stdout:'timeout, forcing stop',stderr:'',timedOut:false,canceled:false}
    : {ok:false,exitCode:1,stdout:'not running\n',stderr:'',timedOut:false,canceled:false}});
  await assert.rejects(provider.drainRecorders(new AbortController().signal),/shutdown is unverified/);
  assert.equal(provider.loggerClosed,false);
  await assert.rejects(provider.exportEvidence(new AbortController().signal),/settlement or logger closure/);
  await assert.rejects(provider.captureLastState(new AbortController().signal),/logger closure/);
});

test('successful logger shutdown is accepted only with actual inactive status',async t=>{
  const {provider}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:0});
  provider.workerState='settled';
  const calls:string[]=[];
  provider.loggerCommand=async(command:string)=>{
    calls.push(command);
    return {result:command==='stop'
      ? {ok:true,exitCode:0,stdout:'',stderr:'',timedOut:false,canceled:false}
      : {ok:false,exitCode:255,stdout:'INFO  [logger] not running\n',stderr:'',timedOut:false,canceled:false}};
  };
  await provider.drainRecorders(new AbortController().signal);
  await provider.drainRecorders(new AbortController().signal);
  assert.equal(provider.loggerClosed,true);
  assert.deepEqual(calls,['stop','status']);
});


test('aborted attached stream does not claim remote settlement or permit export',async t=>{
  const {provider,calls,facts}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:0},-1);
  await assert.rejects(provider.executeNative('land',ids,AbortSignal.timeout(100)));
  assert.equal(provider.workerState,'unresolved');
  const partial=facts.find(item=>item.name==='native-worker-output-partial.json')?.value;
  assert.equal(partial.complete,false);assert.equal(partial.error_category,'canceled');
  assert.equal(Buffer.from(partial.output_base64,'base64').toString(),'pending');
  assert.equal(calls.filter(x=>x.endsWith('/json')).length,0);
  await assert.rejects(provider.exportEvidence(new AbortController().signal),/settlement or logger closure/);
});


test('original native binding points inside the same archive at the retained ULog and parent facts',async t=>{
  const base=await mkdtemp(join(tmpdir(),'px4-custody-unit-'));
  t.after(()=>rm(base,{recursive:true,force:true}));
  const archiveRoot=join(base,'archive'),capture=join(archiveRoot,'capture'),parent=join(archiveRoot,'parent-facts');
  const output=join(base,'provider-output');
  await mkdir(parent,{recursive:true});await mkdir(join(output,'rootfs/log'),{recursive:true});
  const original=Buffer.from('synthetic log bytes');await writeFile(join(output,'rootfs/log/flight.ulg'),original);
  const {provider}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:0},200,async()=>{await mkdir(capture)});
  provider.archiveRoot=archiveRoot;provider.workerArchive='/run/robotics/archive';provider.output=output;provider.loggerStarted=false;
  delete provider.nativeFact;
  provider.currentActor=async()=>({container:{Id:cid,Image:'sha256:'+'f'.repeat(64),RestartCount:0,
    State:{Running:true,StartedAt:'time'},Config:{Labels:{'org.robotics.runtime.run-id':'run-1','com.docker.compose.project':'rr-px4-'+ 'a'.repeat(24)}}},image:{Id:'sha256:'+'f'.repeat(64)}});
  provider.processFact=async(name:string)=>{
    const path=join(parent,'process-'+name+'.json');
    const facts={owner_id:'run-1',container_id:cid,captured_unix_ns:'1000000',
      px4_process:{pid:2,start_ticks:'12',executable:'/opt/px4/build/px4_sitl_default/bin/px4',executable_sha256:'c'.repeat(64),instance:0}};
    await writeFile(path,JSON.stringify(facts),{flag:'wx'});return {facts,ref:await referenceFile(path)};
  };
  provider.loggerCommand=async(command:string,role:string)=>{
    const result=command==='on'?{ok:true,exitCode:0,stdout:'',stderr:'',timedOut:false,canceled:false}
      :command==='stop'?{ok:true,exitCode:0,stdout:'',stderr:'',timedOut:false,canceled:false}
      :role==='before-case'?{ok:true,exitCode:0,stdout:'INFO  [logger] Running in mode: all\nINFO  [logger] Number of subscriptions: 1 (8 bytes)\nINFO  [logger] Full File Logging Running:\nINFO  [logger] Log file: ./log/flight.ulg\n',stderr:'',timedOut:false,canceled:false}
      :{ok:false,exitCode:255,stdout:'not running\n',stderr:'',timedOut:false,canceled:false};
    return {owner_id:'run-1',container_id:cid,role,started_unix_ns:'1000000',finished_unix_ns:'2000000',
      invocation:{executable:'/opt/px4/build/px4_sitl_default/bin/px4-logger',argv:['--instance','0',command]},result};
  };
  provider.compose={run:async()=>{
    const retained=join(capture,'retained-native-logs');await mkdir(retained);
    await writeFile(join(retained,'flight.ulg'),original);
    await writeFile(join(retained,'export-manifest.json'),JSON.stringify({version:1,runId:'run-1',status:'complete',startedUnixNs:'2000000',
      entries:[{name:'flight.ulg',relativePath:'flight.ulg',sha256:createHash('sha256').update(original).digest('hex'),size_bytes:original.length}]}));
    return {ok:true};
  }};
  await provider.startNativeLogger(new AbortController().signal);
  await provider.executeNative('land',ids,new AbortController().signal);
  await provider.closeNativeMeasurement(new AbortController().signal);
  await provider.exportEvidence(new AbortController().signal);
  const binding=JSON.parse(await readFile(join(capture,'native-evidence.json'),'utf8'));
  assert.equal(binding.run_id,'run-1');
  assert.deepEqual(await readFile(fileURLToPath(binding.value.ulog.uri)),original);
  const after=JSON.parse(await readFile(fileURLToPath(binding.value.custody.actor_after.uri),'utf8'));
  const created=JSON.parse(await readFile(fileURLToPath(after.exec_record.uri),'utf8'));
  const settled=JSON.parse(await readFile(fileURLToPath(after.exec_result.uri),'utf8'));
  assert.equal(created.exec_id,eid);assert.equal(settled.exec_id,eid);
  assert.equal(settled.inspect.ContainerID,cid);assert.equal(settled.inspect.Running,false);assert.equal(settled.inspect.ExitCode,0);
  for(const ref of Object.values(binding.value.custody) as Array<{uri:string;sha256:string;size_bytes:number;media_type:string}>){
    const path=fileURLToPath(ref.uri);
    assert.ok(path.startsWith(parent+'/')||path.startsWith(capture+'/'));
    const bytes=await readFile(path);assert.equal(createHash('sha256').update(bytes).digest('hex'),ref.sha256);
    assert.equal(bytes.length,ref.size_bytes);
  }
});


test('unknown profile mode refuses rather than falling back to legacy',()=>{
  const context=new Context();
  assert.throws(()=>new Px4Native(context,{mode:'unknown',composeExecutable:'/bin/docker-compose',
    socketPath:'/tmp/engine.sock',composeFiles:['/tmp/compose.yaml'],cwd:'/tmp',
    workerImage:'example@sha256:'+'c'.repeat(64),runVolume:'run',outputRoot:'/tmp',
  } as any),/unknown PX4 provider mode/);
});


test('native cleanup refuses foreign project ownership without sending down',async()=>{
  const context=new Context();let resource:any;
  context.provide('runResources',{ownerId:'run-1',track:(value:unknown)=>{resource=value}} as any);
  context.provide('jobs',{run:async()=>({ok:true})} as any);
  const provider:any=new Px4Native(context,{mode:'native-sdk-v2',initSha256:'1'.repeat(64),composeExecutable:'/bin/compose',
    socketPath:'/tmp/engine.sock',composeFiles:['/tmp/compose.yaml'],cwd:'/tmp',
    workerImage:'example@sha256:'+'c'.repeat(64),runVolume:'run',outputRoot:'/tmp',
    archiveRoot:'/tmp/archive'});
  let down=0;
  provider.workerState='settled';provider.loggerClosed=true;
  provider.engine={projectOwnership:async()=>({status:'incomplete'})};
  provider.compose={run:async()=>{down++;return {ok:true}}};
  await assert.rejects(resource.cleanup(),/project ownership is incomplete/);
  assert.equal(down,0);
});


test('actor evidence retains user and allowed mounts without environment, rejecting extra mounts',()=>{
  const provider:any=Object.create(Px4Native.prototype);
  Object.assign(provider,{ownerId:'run-1',project:'rr-px4-'+ 'd'.repeat(24),output:'/tmp/scope',config:{runVolume:'run-volume'}});
  const container={Id:cid,Image:'sha256:'+'c'.repeat(64),RestartCount:0,
    State:{Running:true,OOMKilled:false,StartedAt:'time'},
    Config:{User:'1000:1000',Env:['SECRET=hidden','GZ_PARTITION=scope'],Entrypoint:['/opt/px4/build/px4_sitl_default/bin/px4'],
      Cmd:['-d','/opt/px4/build/px4_sitl_default/etc','-i','0','-w','/run/robotics/output/px4/scope/rootfs'],
      Labels:{'org.robotics.runtime.run-id':'run-1','com.docker.compose.project':provider.project}},
    HostConfig:{Init:true,ReadonlyRootfs:true,Memory:4294967296,Privileged:false,PidsLimit:256,CapAdd:[] as string[],
      CapDrop:['ALL'],SecurityOpt:['no-new-privileges'],Tmpfs:{'/tmp':'rw,mode=1777,size=512m'}},
    Mounts:[{Type:'volume',Destination:'/run/robotics',Name:'run-volume',RW:true,Source:'/private/path'}]};
  const observation={status:'complete',container,image:{Id:container.Image,Config:{Env:['SECRET=hidden']}}};
  const safe=provider.actorFacts(observation,cid);
  assert.equal(safe.container.Config.User,'1000:1000');
  assert.deepEqual(safe.container.Mounts,[{Type:'volume',Destination:'/run/robotics',Name:'run-volume',RW:true}]);
  assert.ok(!JSON.stringify(safe).includes('SECRET'));
  assert.ok(!JSON.stringify(safe).includes('/private/path'));
  container.Config.Env.push('LD_PRELOAD=/secret/preload.so');
  assert.throws(()=>provider.actorFacts(observation,cid),/^Error: native actor environment differs$/);
  container.Config.Env.pop();
  container.Config.Env.push('GZ_PARTITION=foreign');
  assert.throws(()=>provider.actorFacts(observation,cid),/^Error: native actor environment differs$/);
  container.Config.Env.pop();
  container.Config.Env.push('container=podman','HOSTNAME='+cid.slice(0,12));
  Object.assign(container.Config,{Hostname:cid.slice(0,12)});
  assert.ok(!JSON.stringify(provider.actorFacts(observation,cid)).includes('SECRET'));
  container.Config.Env.splice(-2);
  container.HostConfig.CapDrop=['CAP_CHOWN','CAP_DAC_OVERRIDE','CAP_FOWNER','CAP_FSETID','CAP_KILL','CAP_NET_BIND_SERVICE','CAP_SETFCAP','CAP_SETGID','CAP_SETPCAP','CAP_SETUID','CAP_SYS_CHROOT'];
  assert.equal(provider.actorFacts(observation,cid).container.Config.User,'1000:1000');
  container.HostConfig.CapDrop=['ALL'];
  container.HostConfig.Privileged=true;
  assert.throws(()=>provider.actorFacts(observation,cid),/actor identity is incomplete/);
  container.HostConfig.Privileged=false;container.HostConfig.PidsLimit=255;
  assert.throws(()=>provider.actorFacts(observation,cid),/actor identity is incomplete/);
  container.HostConfig.PidsLimit=256;container.HostConfig.CapAdd=['SYS_ADMIN'];
  assert.throws(()=>provider.actorFacts(observation,cid),/actor identity is incomplete/);
  container.HostConfig.CapAdd=[];container.HostConfig.CapDrop=['CHOWN'];
  assert.throws(()=>provider.actorFacts(observation,cid),/actor identity is incomplete/);
  container.HostConfig.CapDrop=['ALL'];container.HostConfig.SecurityOpt=[];
  assert.throws(()=>provider.actorFacts(observation,cid),/actor identity is incomplete/);
  container.HostConfig.SecurityOpt=['no-new-privileges'];container.HostConfig.Tmpfs['/tmp']='rw,mode=1777,size=1m';
  assert.throws(()=>provider.actorFacts(observation,cid),/actor identity is incomplete/);
  container.HostConfig.Tmpfs['/tmp']='rw,mode=1777,size=512m';container.Config.Cmd[3]='1';
  assert.throws(()=>provider.actorFacts(observation,cid),/actor identity is incomplete/);
  container.Config.Cmd[3]='0';container.Mounts.push({Type:'bind',Destination:'/foreign',Name:'',RW:true,Source:'/other'});
  assert.throws(()=>provider.actorFacts(observation,cid),/actor identity is incomplete/);
});


test('native JSON fact is bounded, regular, confined and hashed from captured bytes',async t=>{
  const root=await mkdtemp(join(tmpdir(),'px4-fact-unit-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const provider:any=Object.create(Px4Native.prototype);provider.archiveRoot=root;
  const data=Buffer.from('{"owner_id":"run-1"}\n'),path=join(root,'fact.json');
  await writeFile(path,data);
  const observed=await provider.readNativeFact(path);
  assert.equal(observed.facts.owner_id,'run-1');
  assert.equal(observed.ref.sha256,createHash('sha256').update(data).digest('hex'));
  assert.equal(observed.ref.size_bytes,data.length);
  await writeFile(path,Buffer.alloc(1048577));
  await assert.rejects(provider.readNativeFact(path),/bounded regular/);
  await rm(path);await symlink(join(root,'target.json'),path);
  await assert.rejects(provider.readNativeFact(path));
  await rm(path);execFileSync('/usr/bin/mkfifo',[path]);
  await assert.rejects(provider.readNativeFact(path),/bounded regular/);
  await rm(path);await writeFile(path,'{not json');
  await assert.rejects(provider.readNativeFact(path));
  const foreign=await mkdtemp(join(tmpdir(),'px4-foreign-unit-'));
  t.after(()=>rm(foreign,{recursive:true,force:true}));
  await writeFile(join(foreign,'fact.json'),'{}');await symlink(foreign,join(root,'alias'));
  await assert.rejects(provider.readNativeFact(join(root,'alias','fact.json')),/not confined/);
});


test('timeout and killed worker exits remain incomplete and do not permit export',async t=>{
  for(const code of [124,125,126,127,137,2]){
    const {provider}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:code});
    await assert.rejects(provider.executeNative('land',ids,new AbortController().signal),/physical outcome is unknown/);
    assert.equal(provider.workerState,'unresolved');
    await assert.rejects(provider.exportEvidence(new AbortController().signal),/settlement or logger closure/);
  }
});


test('fractional seconds preserve the configured millisecond deadline',async t=>{
  const {provider,requests}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:0});
  provider.deadline=1001;
  await provider.executeNative('land',ids,new AbortController().signal);
  assert.equal(JSON.parse(requests[0]!).Cmd[3],'1.001s');
});


test('oversized worker output is refused without claiming settlement',async t=>{
  const {provider,calls,facts}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:0},-2);
  await assert.rejects(provider.executeNative('land',ids,new AbortController().signal),/output exceeded bound/);
  assert.equal(provider.workerState,'unresolved');
  const partial=facts.find(item=>item.name==='native-worker-output-partial.json')?.value;
  assert.equal(partial.complete,false);assert.equal(partial.truncated,true);
  assert.equal(partial.error_category,'output_limit');assert.equal(Buffer.from(partial.output_base64,'base64').length,524288);
  assert.equal(calls.filter(x=>x.endsWith('/json')).length,0);
});


test('normal worker exit 1 is settled but remains failed and physical outcome unknown',async t=>{
  const {provider}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:1});
  await assert.rejects(provider.executeNative('land',ids,new AbortController().signal),/physical outcome is unknown/);
  assert.equal(provider.workerState,'settled');
  provider.loggerCommand=async(command:string)=>({result:command==='stop'
    ? {ok:true,exitCode:0,stdout:'',stderr:'',timedOut:false,canceled:false}
    : {ok:false,exitCode:255,stdout:'not running\n',stderr:'',timedOut:false,canceled:false}});
  await assert.rejects(provider.closeNativeMeasurement(new AbortController().signal),/physical outcome is unknown/);
  assert.equal(provider.loggerClosed,true);
});


test('native provider snapshots caller config and compose files',()=>{
  const context=new Context();
  context.provide('runResources',{ownerId:'run-1',track:()=>{}} as any);
  context.provide('jobs',{run:async()=>({ok:true})} as any);
  const config:any={mode:'native-sdk-v2',initSha256:'1'.repeat(64),composeExecutable:'/bin/compose',socketPath:'/tmp/engine.sock',
    composeFiles:['/tmp/compose.yaml'],cwd:'/tmp',workerImage:'example@sha256:'+'c'.repeat(64),
    runVolume:'run',outputRoot:'/tmp',archiveRoot:'/tmp/archive'};
  const provider:any=new Px4Native(context,config);
  config.mode='legacy-grpc';config.composeFiles[0]='/tmp/foreign.yaml';config.archiveRoot='/tmp/foreign';
  assert.equal(provider.config.mode,'native-sdk-v2');assert.deepEqual(provider.config.composeFiles,['/tmp/compose.yaml']);
  assert.equal(provider.config.archiveRoot,'/tmp/archive');
  assert.ok(Object.isFrozen(provider.config));assert.ok(Object.isFrozen(provider.config.composeFiles));
});

test('SDK identity input is captured before asynchronous process observation',async t=>{
  const {provider,facts}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:0});
  let release!:()=>void;const gate=new Promise<void>(resolve=>{release=resolve});
  const original=provider.processFact;
  provider.processFact=async(name:string,signal:AbortSignal)=>{if(name==='before')await gate;return original(name,signal)};
  const selected={...ids};
  const pending=provider.executeNative('land',selected,new AbortController().signal);
  selected.target_system_id=99;release();await pending;
  const actor=facts.find(item=>item.name==='native-actor-config.json')?.value;
  assert.equal(actor.target_system_id,1);
});


test('native init identity comes from the admitted configuration',async()=>{
  const provider:any=Object.create(Px4Native.prototype);
  provider.config={mode:'native-sdk-v2',initSha256:'1'.repeat(64)};provider.deadline=120000;
  provider.ownerId='run-1';provider.refs=[];
  provider.probe=async()=>({ready:true,owner_id:'run-1',model:'x500_0',oci_init:{sha256:'2'.repeat(64)}});
  await assert.rejects(provider.ready(new AbortController().signal),/init identity/);
  provider.probe=async()=>({ready:true,owner_id:'run-1',model:'x500_0',oci_init:{sha256:'1'.repeat(64)}});
  assert.equal((await provider.ready(new AbortController().signal)).ready,true);
});


test('Compose-injected loader environment refuses before Engine connection or up',async t=>{
  const root=await mkdtemp(join(tmpdir(),'px4-compose-env-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const archive=join(root,'archive');await mkdir(archive);
  const provider:any=Object.create(Px4Native.prototype),calls:string[][]=[];
  Object.assign(provider,{config:{mode:'native-sdk-v2',outputRoot:root},archiveRoot:archive,output:join(root,'scope'),refs:[],
    compose:{requireVersion:async()=>{},run:async(args:string[])=>{calls.push(args);return {ok:true,stdout:JSON.stringify({services:{'px4-native':{environment:{GZ_PARTITION:'scope',LD_PRELOAD:'/private/library.so'}}}})}}}});
  await assert.rejects(provider.launch(),/^Error: native Compose environment differs$/);
  assert.deepEqual(calls,[['config','--format','json']]);
  assert.equal(provider.engine,undefined);
});


test('single-service Podman override preserves the stock fixed-worker UID mapping',async()=>{
  const native=await readFile(new URL('../../../compose.px4-sdk.podman.yaml',import.meta.url),'utf8');
  const legacy=await readFile(new URL('../../../compose.px4.podman.yaml',import.meta.url),'utf8');
  const mapping=(text:string)=>[...text.matchAll(/^    userns_mode: (.+)$/gm)].map(match=>match[1]);
  assert.deepEqual(mapping(native),[mapping(legacy)[0]]);
  assert.equal(mapping(native)[0],'keep-id:uid=1000,gid=1000');
  assert.match(native,/^  px4-native:$/m);assert.doesNotMatch(native,/mavsdk-native/);
});


test('ready passes the admitted provider budget and caller cancellation to one native probe',async()=>{
  const provider:any=Object.create(Px4Native.prototype),calls:any[]=[];
  provider.config={mode:'native-sdk-v2',initSha256:'1'.repeat(64)};provider.deadline=1001;
  provider.ownerId='run-1';provider.refs=[];
  provider.probe=async(...args:any[])=>{calls.push(args);return {ready:true,owner_id:'run-1',model:'x500_0',oci_init:{sha256:'1'.repeat(64)}}};
  const controller=new AbortController();await provider.ready(controller.signal);
  assert.deepEqual(calls,[['ready','gz-readiness.json',1.001,controller.signal]]);
  controller.abort(new Error('caller canceled'));await assert.rejects(provider.ready(controller.signal),/caller canceled/);
  assert.equal(calls.length,1);
});

test('only ready accepts the configured extended budget; observation remains bounded to 60 seconds',async t=>{
  const root=await mkdtemp(join(tmpdir(),'px4-probe-budget-'));t.after(()=>rm(root,{recursive:true,force:true}));
  const provider:any=Object.create(Px4Native.prototype),calls:string[][]=[];
  Object.assign(provider,{output:root,refs:[],ownerId:'run-1',compose:{run:async(args:string[])=>{
    calls.push(args);await writeFile(join(root,'ready.json'),'{"ready":false}');return {ok:true};
  }}});
  await provider.probe('ready','ready.json',120,new AbortController().signal);
  assert.equal(calls[0]![calls[0]!.indexOf('--seconds')+1],'120');
  for(const [mode,seconds] of [['ready',301],['observe',61],['last-state',61]] as const){
    await assert.rejects(provider.probe(mode,'other.json',seconds,new AbortController().signal),/finite native probe/);
  }
  assert.equal(calls.length,1);
});


const loggerRunning='INFO  [logger] Running in mode: all\nINFO  [logger] Number of subscriptions: 1 (8 bytes)\n';
const loggerInactive=loggerRunning+'INFO  [logger] Not logging\n';
const loggerActive=loggerRunning+'INFO  [logger] Full File Logging Running:\nINFO  [logger] Log file: ./log/flight.ulg\n';
const loggerResult=(stdout:string,exitCode=0)=>({ok:exitCode===0,exitCode,stdout,stderr:'',timedOut:false,canceled:false});

async function loggerStartup(t:test.TestContext,statuses:any[],deadline=1000){
  const {provider,facts}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:0});
  provider.loggerStarted=false;provider.deadline=deadline;
  const calls:string[]=[];
  provider.loggerCommand=async(command:string)=>{
    calls.push(command);
    return {result:command==='status'?statuses.shift()??loggerResult(loggerActive):loggerResult('')};
  };
  return {provider,calls,facts};
}

test('logger waits for its module then async full file activation with one on',async t=>{
  const {provider,calls,facts}=await loggerStartup(t,[loggerResult('INFO  [logger] not running',255),
    loggerResult(loggerInactive),loggerResult(loggerInactive),loggerResult(loggerActive)]);
  await provider.startNativeLogger(new AbortController().signal);
  assert.deepEqual(calls,['status','status','on','status','status']);
  assert.equal(provider.loggerStarted,true);assert.equal(provider.loggerPath,'./log/flight.ulg');
  assert.ok(facts.some(f=>f.name==='logger-available.json'));assert.ok(facts.some(f=>f.name==='logger-start.json'));
  await assert.rejects(provider.startNativeLogger(new AbortController().signal),/unavailable/);
  assert.equal(calls.filter(c=>c==='on').length,1);
});

test('logger only waits for the exact stock absent-module status before on',async t=>{
  for(const invalid of [loggerResult('INFO  [logger] not running',1),loggerResult('not running',255),
    loggerResult('unrecognized status'),{...loggerResult('INFO  [logger] not running',255),timedOut:true},
    {...loggerResult('INFO  [logger] not running',255),stderr:'transport failed'}]){
    const {provider,calls}=await loggerStartup(t,[invalid]);
    await assert.rejects(provider.startNativeLogger(new AbortController().signal),/status is unverified/);
    assert.deepEqual(calls,['status']);assert.equal(provider.loggerStarted,false);
  }
});

test('logger activation refuses missing path or vanished module and never replays on',async t=>{
  for(const invalid of [loggerResult(loggerRunning+'INFO  [logger] Full File Logging Running:\n'),
    loggerResult('INFO  [logger] not running',255),loggerResult('unrecognized status')]){
    const {provider,calls}=await loggerStartup(t,[loggerResult(loggerInactive),invalid]);
    await assert.rejects(provider.startNativeLogger(new AbortController().signal),/path is unavailable|status is unverified/);
    assert.equal(provider.loggerStarted,false);assert.equal(calls.filter(c=>c==='on').length,1);
    await assert.rejects(provider.startNativeLogger(new AbortController().signal),/unavailable/);
    assert.equal(calls.filter(c=>c==='on').length,1);
  }
});

test('logger caller cancellation and the single deadline prevent later on or measurement eligibility',async t=>{
  const {provider,calls}=await loggerStartup(t,Array(20).fill(loggerResult('INFO  [logger] not running',255)),1000);
  await assert.rejects(provider.startNativeLogger(AbortSignal.timeout(20)));
  assert.deepEqual(calls,['status']);assert.equal(provider.loggerStarted,false);
  const second=await loggerStartup(t,[],20);let on=false;
  second.provider.loggerCommand=async(command:string)=>{
    if(command==='on')on=true;
    else await new Promise(resolve=>setTimeout(resolve,25));
    return {result:loggerResult(loggerActive)};
  };
  await assert.rejects(second.provider.startNativeLogger(new AbortController().signal));
  assert.equal(on,false);assert.equal(second.provider.loggerStarted,false);
});


test('logger shutdown requires stock absent-module255 rather than another nonzero exit',async t=>{
  for(const exitCode of [-1,1,2,137]){
    const {provider}=await setup(t,{ID:eid,ContainerID:cid,Running:false,ExitCode:0});
    provider.workerState='settled';
    provider.loggerCommand=async(command:string)=>({result:command==='stop'
      ? loggerResult('') : loggerResult('INFO  [logger] not running',exitCode)});
    await assert.rejects(provider.drainRecorders(new AbortController().signal),/shutdown is unverified/);
    assert.equal(provider.loggerClosed,false);
  }
});
