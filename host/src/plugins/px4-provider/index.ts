import {Service,referenceFile} from '@robotics-runtime/host';
import type {ArtifactRef,Context,Mavsdk} from '@robotics-runtime/host';
import {createHash,randomUUID} from 'node:crypto';
import {constants} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {mkdir,open,readFile,readdir,lstat,realpath,writeFile} from 'node:fs/promises';
import Docker from 'dockerode';
import {finished} from 'node:stream/promises';
import {dirname,isAbsolute,join,relative,resolve} from 'node:path';
import {ComposeExecution} from '../../compose-execution.js';
import {EngineMetadata} from '../../engine-metadata.js';

export interface Px4Config {
  composeExecutable:string;socketPath:string;composeFiles:readonly string[];cwd:string;
  workerImage:string;runVolume:string;outputRoot:string;grpcPort?:number;deadlineMs?:number;
  mode?:'legacy-grpc'|'native-sdk-v2';archiveRoot?:string;
}
const record=(value:unknown):Record<string,unknown>=>{
  if(!value||typeof value!=='object'||Array.isArray(value)) throw new Error('native fact is not an object');
  return value as Record<string,unknown>;
};
async function reference(path:string):Promise<ArtifactRef>{
  return referenceFile(path);
}
declare module 'cordis' {interface Context {px4:Px4Native;}}
/** Stock firmware/physics stay in the worker; flight policy uses the public generated MAVSDK clients. */
export class Px4Native extends Service {
  static inject=['jobs','runResources'];
  readonly ownerId:string;readonly project:string;readonly output:string;
  private readonly compose:ComposeExecution;private readonly deadline:number;
  private engine:EngineMetadata|undefined;private readonly refs:ArtifactRef[]=[];
  private launched:Promise<void>|undefined;
  private primaryId:string|undefined;
  private workerState:'not-started'|'unresolved'|'settled'='not-started';
  private loggerStarted=false;private loggerClosed=false;
  private actorBefore:Record<string,unknown>|undefined;
  private workerPromise:Promise<ArtifactRef[]>|undefined;
  private loggerStartRef:ArtifactRef|undefined;private loggerStopRef:ArtifactRef|undefined;
  private actorBeforeRef:ArtifactRef|undefined;private actorAfterRef:ArtifactRef|undefined;
  private loggerPath:string|undefined;
  private archiveRoot:string|undefined;private workerArchive:string|undefined;
  constructor(ctx:Context,readonly config:Px4Config){
    super(ctx,'px4');
    if(config.mode==='native-sdk-v2'){
      this.config=Object.freeze({...config,composeFiles:Object.freeze([...config.composeFiles])});
      config=this.config;
    }
    const deadline=config.deadlineMs??120000;
    if(!Number.isSafeInteger(deadline)||deadline<=0||deadline>300000)throw new Error('invalid finite PX4 deadline');
    if(![config.composeExecutable,config.socketPath,config.cwd,config.outputRoot,...config.composeFiles].every(isAbsolute))throw new Error('provider paths must be absolute');
    if(!/@sha256:[a-f0-9]{64}$/.test(config.workerImage))throw new Error('immutable stock worker digest required');
    if(config.mode!==undefined&&config.mode!=='legacy-grpc'&&config.mode!=='native-sdk-v2')throw new Error('unknown PX4 provider mode');
    if(config.mode!=='native-sdk-v2'&&(!Number.isSafeInteger(config.grpcPort)||config.grpcPort!<1024||config.grpcPort!>65535))throw new Error('configured unprivileged local gRPC port required');
    if(config.mode==='native-sdk-v2'){
      if(!config.archiveRoot||!isAbsolute(config.archiveRoot))throw new Error('absolute native archive required');
      const part=relative(config.outputRoot,config.archiveRoot);
      if(!part||part==='..'||part.startsWith('../')||isAbsolute(part))throw new Error('native archive must be inside the mounted output root');
      this.archiveRoot=config.archiveRoot;this.workerArchive='/run/robotics/output/px4/'+part;
    }
    this.deadline=deadline;this.ownerId=ctx.runResources.ownerId;
    const scope=createHash('sha256').update(this.ownerId+randomUUID()).digest('hex').slice(0,24);
    this.project='rr-px4-'+scope;this.output=join(config.outputRoot,scope);
    this.compose=new ComposeExecution(ctx.jobs,{
      executable:config.composeExecutable,socketPath:config.socketPath,projectName:this.project,
      files:config.composeFiles,cwd:config.cwd,timeoutMs:deadline,maxBufferBytes:1048576,
      env:{ROBOTICS_PX4_IMAGE:config.workerImage,ROBOTICS_RUN_VOLUME:config.runVolume,
        ROBOTICS_RUN_ID:this.ownerId,ROBOTICS_PX4_SCOPE:scope,
        ...(config.mode==='native-sdk-v2'?{}:{ROBOTICS_PX4_GRPC_PORT:String(config.grpcPort)})},
    });
    ctx.runResources.track({id:this.project,ownerId:this.ownerId,
      cleanup:async()=>{
        if(this.config.mode==='native-sdk-v2'){
          if(this.workerState!=='settled'||!this.loggerClosed||!this.engine)throw new Error('native cleanup requires settled worker and closed logger');
          const ownership=await this.engine.projectOwnership({runId:this.ownerId,projectName:this.project});
          if(ownership.status!=='complete')throw new Error('native project ownership is incomplete');
        }
        const result=await this.compose.run(['down','--remove-orphans','--timeout','5']);
        if(!result.ok)throw new Error(result.diagnostic??'owned PX4 project cleanup failed');
      },
      verifyCleanup:async signal=>{
        signal.throwIfAborted();
        if(!this.engine)return {released:false,evidenceRefs:[],diagnostic:'native Engine was not observed'};
        const observed=await this.engine.remainingOwned(this.ownerId);
        const owned=(values:unknown[])=>values.filter(v=>record(record(v).Labels??{})['com.docker.compose.project']===this.project);
        const released=!owned(observed.containers).length&&!owned(observed.networks).length;
        const path=this.config.mode==='native-sdk-v2'?join(this.archiveRoot!,'capture','engine-cleanup.json'):join(this.output,'engine-cleanup.json');
        await writeFile(path,JSON.stringify({owner_id:this.ownerId,project:this.project,released,observed}));
        return {released,evidenceRefs:[await reference(path)]};
      }});
  }
  async *[Service.init](){
    this.launched=this.launch();
    await this.launched;
  }
  private async launch():Promise<void>{
    if(this.config.mode==='native-sdk-v2'){
      if(await realpath(this.config.outputRoot)!==resolve(this.config.outputRoot)||await realpath(this.archiveRoot!)!==resolve(this.archiveRoot!))throw new Error('native archive path must not traverse symbolic links');
    }
    await mkdir(join(this.output,'rootfs'),{recursive:true});
    if(this.config.mode==='native-sdk-v2')await mkdir(join(this.archiveRoot!,'parent-facts'),{mode:0o700});
    await this.compose.requireVersion();
    this.engine=await EngineMetadata.connect({socketPath:this.config.socketPath,operationMinApi:'1.24',operationMaxApi:'1.53'});
    const services=this.config.mode==='native-sdk-v2'?['px4-native']:['px4-native','mavsdk-native'];
    const started=await this.compose.run(['up','--detach',...services]);
    await writeFile(join(this.output,'compose-launch.json'),JSON.stringify(started));
    this.refs.push(await reference(join(this.output,'compose-launch.json')));
    if(!started.ok)throw new Error(started.diagnostic??'stock firmware/server launch failed');
    let primaryId:string|undefined;
    for(const name of services){
      const ps=await this.compose.run(['ps','--all','--quiet',name]);const id=ps.stdout.trim();
      if(!ps.ok||! /^[a-f0-9]{64}$/.test(id))throw new Error('exact worker container ID missing');
      if(name==='px4-native'){primaryId=id;this.primaryId=id;}
      const observation=await this.engine.inspect(id,{networkNamespaceContainerId:name==='mavsdk-native'?primaryId:undefined,runId:this.ownerId,projectName:this.project,
        imageDigest:this.config.workerImage,mounts:name==='px4-native'?[{destination:'/run/robotics',readOnly:false,volumeName:this.config.runVolume}]:[],
        hostConfig:{Init:true,ReadonlyRootfs:true,Memory:name==='px4-native'?4294967296:268435456,
          ...(this.config.mode==='native-sdk-v2'?{Privileged:false,PidsLimit:256}:{})},user:'1000:1000'});
      if(this.config.mode==='native-sdk-v2'){
        this.actorBefore=this.actorFacts(observation,id);
      }else{
        const path=join(this.output,name+'-engine.json');await writeFile(path,JSON.stringify(observation));this.refs.push(await reference(path));
      }
      if(observation.status!=='complete')await this.captureLogs('startup-workers.log');
      if(observation.status!=='complete'||record(record(observation.container).State).Running!==true)throw new Error('native Engine readiness facts incomplete');
    }
  }
  private actorFacts(observation:unknown,id:string):Record<string,unknown>{
    const facts=record(observation),container=record(facts.container),state=record(container.State),config=record(container.Config),labels=record(config.Labels),image=record(facts.image),host=record(container.HostConfig);
    const dropped=Array.isArray(host.CapDrop)?host.CapDrop.map(value=>typeof value==='string'?value.replace(/^CAP_/,''):'').sort():[];
    const standard=['CHOWN','DAC_OVERRIDE','FOWNER','FSETID','KILL','NET_BIND_SERVICE','SETFCAP','SETGID','SETPCAP','SETUID','SYS_CHROOT'].sort();
    const expectedCommand=['-d','/opt/px4/build/px4_sitl_default/etc','-i','0','-w',
      '/run/robotics/output/px4/'+this.output.split('/').at(-1)+'/rootfs'];
    const mounts=Array.isArray(container.Mounts)?container.Mounts.map(record):[];
    const volume=mounts.filter(mount=>mount.Destination==='/run/robotics'),temporary=mounts.filter(mount=>mount.Destination==='/tmp');
    const tmpfs=record(host.Tmpfs),tmpOptions=typeof tmpfs['/tmp']==='string'?tmpfs['/tmp'].split(','):[];
    const sizes=tmpOptions.filter(option=>option.startsWith('size='));
    const sizeMatch=sizes.length===1?/^size=(\d+)([kmg]?)$/i.exec(sizes[0]!):null;
    const factors:Record<string,number>={'':1,k:1024,m:1048576,g:1073741824};
    if(facts.status!=='complete'||container.Id!==id||state.Running!==true||state.OOMKilled!==false||container.RestartCount!==0||
      labels['org.robotics.runtime.run-id']!==this.ownerId||labels['com.docker.compose.project']!==this.project||
      config.User!=='1000:1000'||JSON.stringify(config.Entrypoint)!==JSON.stringify(['/opt/px4/build/px4_sitl_default/bin/px4'])||
      JSON.stringify(config.Cmd)!==JSON.stringify(expectedCommand)||host.Privileged!==false||host.PidsLimit!==256||host.Init!==true||
      host.ReadonlyRootfs!==true||host.Memory!==4294967296||JSON.stringify(host.CapAdd??[])!=='[]'||
      (JSON.stringify(dropped)!==JSON.stringify(['ALL'])&&JSON.stringify(dropped)!==JSON.stringify(standard))||
      JSON.stringify(host.SecurityOpt)!==JSON.stringify(['no-new-privileges'])||
      Object.keys(tmpfs).some(key=>key!=='/tmp')||temporary.length>1||
      temporary.some(mount=>mount.Type!=='tmpfs'||mount.RW!==true)||
      tmpOptions.filter(option=>option==='rw').length!==1||tmpOptions.filter(option=>option.startsWith('mode=')).join()!=='mode=1777'||
      tmpOptions.some(option=>!['rw','mode=1777','rprivate','nosuid','nodev','tmpcopyup'].includes(option)&&!/^size=\d+[kmg]?$/i.test(option))||
      !sizeMatch||Number(sizeMatch[1])*factors[sizeMatch[2]!.toLowerCase()]! !==536870912||
      volume.length!==1||volume[0]!.Type!=='volume'||volume[0]!.Name!==this.config.runVolume||volume[0]!.RW!==true||
      mounts.some(mount=>!['/run/robotics','/tmp'].includes(String(mount.Destination)))||
      typeof state.StartedAt!=='string'||typeof container.Image!=='string'||image.Id!==container.Image)throw new Error('owned PX4 actor identity is incomplete');
    const safeMounts=mounts.map(mount=>({Type:mount.Type,Destination:mount.Destination,Name:mount.Name,RW:mount.RW}));
    return {container:{Id:container.Id,Image:container.Image,RestartCount:container.RestartCount,Mounts:safeMounts,
      State:{Running:state.Running,StartedAt:state.StartedAt},
      Config:{User:config.User,Entrypoint:config.Entrypoint,Cmd:config.Cmd,Labels:{'org.robotics.runtime.run-id':labels['org.robotics.runtime.run-id'],'com.docker.compose.project':labels['com.docker.compose.project']}},
      HostConfig:{Init:host.Init,ReadonlyRootfs:host.ReadonlyRootfs,Memory:host.Memory,Privileged:host.Privileged,PidsLimit:host.PidsLimit,
        CapAdd:host.CapAdd,CapDrop:host.CapDrop,SecurityOpt:host.SecurityOpt,Tmpfs:{'/tmp':tmpfs['/tmp']}}},
      image:{Id:image.Id}};
  }
  private async currentActor(signal:AbortSignal):Promise<Record<string,unknown>>{
    if(!this.engine||!this.primaryId)throw new Error('PX4 actor was not observed');
    const observed=await this.engine.inspect(this.primaryId,{runId:this.ownerId,projectName:this.project,imageDigest:this.config.workerImage,
      mounts:[{destination:'/run/robotics',readOnly:false,volumeName:this.config.runVolume}],
      hostConfig:{Init:true,ReadonlyRootfs:true,Memory:4294967296,Privileged:false,PidsLimit:256},user:'1000:1000'},{cancelSignal:signal});
    const current=this.actorFacts(observed,this.primaryId);
    if(JSON.stringify(current)!==JSON.stringify(this.actorBefore))throw new Error('PX4 actor changed during attempt');
    return current;
  }
  private async nativeFact(name:string,value:unknown):Promise<ArtifactRef>{
    const path=join(this.archiveRoot!,'parent-facts',name);
    const file=await open(path,'wx',0o600);
    try{await file.writeFile(JSON.stringify(value)+'\n');await file.sync()}finally{await file.close()}
    const directory=await open(join(this.archiveRoot!,'parent-facts'),'r');
    try{await directory.sync()}finally{await directory.close()}
    const ref=await reference(path);this.refs.push(ref);return ref;
  }
  private async loggerCommand(command:'on'|'status'|'stop',role:'before-case'|'after-case',signal:AbortSignal){
    const executable='/opt/px4/build/px4_sitl_default/bin/px4-logger',argv=['--instance','0',command];
    const started_unix_ns=String(BigInt(Date.now())*1000000n);
    const result=await this.compose.run(['exec','-T','px4-native',executable,...argv],signal);
    const finished_unix_ns=String(BigInt(Date.now())*1000000n);
    return {owner_id:this.ownerId,container_id:this.primaryId,role,started_unix_ns,finished_unix_ns,invocation:{executable,argv},result};
  }
  async startNativeLogger(signal:AbortSignal):Promise<ArtifactRef[]>{
    if(this.config.mode!=='native-sdk-v2'||this.loggerStarted||!this.primaryId)throw new Error('native logger start is unavailable');
    await this.currentActor(signal);
    const started=await this.loggerCommand('on','before-case',signal);
    await this.nativeFact('logger-on.json',started);
    const status=await this.loggerCommand('status','before-case',signal);
    this.loggerStartRef=await this.nativeFact('logger-start.json',status);
    const path=/Log file:\s*(\S+)/.exec(status.result.stdout)?.[1];
    if(!started.result.ok||started.result.exitCode!==0||!status.result.ok||status.result.exitCode!==0||
      status.result.timedOut||status.result.canceled||!/Full File Logging Running:/.test(status.result.stdout)||!path)throw new Error('full PX4 file logger is not active');
    this.loggerPath=path;
    await this.currentActor(signal);
    this.loggerStarted=true;return [...this.refs];
  }
  private async readNativeFact(path:string):Promise<{facts:Record<string,unknown>;ref:ArtifactRef}>{
    const parent=resolve(dirname(path)),root=resolve(this.archiveRoot!);
    const inside=relative(root,parent);
    if(isAbsolute(inside)||inside==='..'||inside.startsWith('../')||await realpath(parent)!==parent)throw new Error('native fact parent is not confined');
    const handle=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);
    try{
      const before=await handle.stat({bigint:true});
      if(!before.isFile()||before.size>1048576n)throw new Error('native fact must be a bounded regular file');
      const buffer=Buffer.alloc(Number(before.size)+1);
      let offset=0;
      while(offset<buffer.length){
        const result=await handle.read(buffer,offset,buffer.length-offset,null);
        if(!result.bytesRead)break;
        offset+=result.bytesRead;
      }
      const after=await handle.stat({bigint:true}),current=await lstat(path,{bigint:true});
      const same=(a:typeof before,b:typeof before)=>['dev','ino','mode','size','mtimeNs','ctimeNs'].every(key=>a[key as keyof typeof a]===b[key as keyof typeof b]);
      if(offset!==Number(before.size)||!same(before,after)||!same(before,current)||await realpath(parent)!==parent)throw new Error('native fact changed while being read');
      const bytes=buffer.subarray(0,offset),facts=record(JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes)));
      return {facts,ref:{uri:pathToFileURL(resolve(path)).href,sha256:createHash('sha256').update(bytes).digest('hex'),size_bytes:bytes.length}};
    }finally{await handle.close()}
  }
  private async processFact(name:'before'|'after',signal:AbortSignal):Promise<{facts:Record<string,unknown>;ref:ArtifactRef}>{
    const location=this.workerArchive+'/parent-facts/process-identity-'+name+'.json';
    const job=await this.compose.run(['exec','-T','px4-native','/usr/bin/python3','-B','/opt/robotics/px4/probe.py',
      '--mode','actor-identity','--instance','0','--container-id',this.primaryId!,'--owner-id',this.ownerId,'--output',location],signal);
    await this.nativeFact('process-identity-'+name+'-job.json',job);
    if(!job.ok)throw new Error('PX4 process identity unavailable');
    const path=join(this.archiveRoot!,'parent-facts','process-identity-'+name+'.json');
    const {facts,ref}=await this.readNativeFact(path);this.refs.push(ref);
    const process=record(facts.px4_process);
    if(facts.owner_id!==this.ownerId||facts.container_id!==this.primaryId||process.instance!==0||!Number.isInteger(process.pid)||typeof process.start_ticks!=='string'||
      typeof process.executable_sha256!=='string'||! /^[a-f0-9]{64}$/.test(process.executable_sha256))throw new Error('PX4 process identity is invalid');
    return {facts,ref};
  }
  async executeNative(caseName:string,ids:Record<string,number>,signal:AbortSignal):Promise<ArtifactRef[]>{
    if(this.workerPromise)throw new Error('native worker already invoked');
    this.workerPromise=this.executeNativeOnce(caseName,ids,signal);
    return this.workerPromise;
  }
  private async executeNativeOnce(caseName:string,ids:Record<string,number>,signal:AbortSignal):Promise<ArtifactRef[]>{
    if(this.config.mode!=='native-sdk-v2'||!this.loggerStarted||!this.primaryId||!this.engine)throw new Error('native worker prerequisites are unavailable');
    if(!['land','unarmed-refusal','application-deadline'].includes(caseName))throw new Error('unsupported PX4 native case');
    const keys=['source_system_id','source_component_id','target_system_id','target_component_id'];
    if(Object.keys(ids).sort().join(',')!==[...keys].sort().join(',')||keys.some(key=>!Number.isInteger(ids[key])||ids[key]!<1||ids[key]!>255))throw new Error('explicit SDK identities required');
    const selectedIds=Object.fromEntries(keys.map(key=>[key,ids[key]!]));
    const process=await this.processFact('before',signal),actor=await this.currentActor(signal);
    this.actorBeforeRef=await this.nativeFact('actor-before.json',{owner_id:this.ownerId,captured_unix_ns:String(BigInt(Date.now())*1000000n),
      ...actor,process_record:{...process.ref,media_type:'application/json'}});
    const nativeProcess=record(process.facts.px4_process);
    const actorConfig={owner_id:this.ownerId,px4_pid:nativeProcess.pid,px4_start_ticks:nativeProcess.start_ticks,
      px4_executable_sha256:nativeProcess.executable_sha256,instance:0,...selectedIds};
    await this.nativeFact('native-actor-config.json',actorConfig);
    await this.currentActor(signal);
    const docker=new Docker({socketPath:this.config.socketPath,version:'v'+this.engine.facts.clientApi});
    this.workerState='unresolved';
    const exec=await docker.getContainer(this.primaryId).exec({AttachStdout:true,AttachStderr:true,Tty:false,
      Cmd:['/usr/bin/timeout','--signal=TERM','--kill-after=5s',String(this.deadline/1000)+'s',
        '/opt/px4-native-venv/bin/python','-B','/opt/robotics/px4/native_worker.py',caseName,'--run-id',this.ownerId,
        '--output',this.workerArchive+'/capture','--config',this.workerArchive+'/parent-facts/native-actor-config.json'],abortSignal:signal});
    if(!/^[a-f0-9]{64}$/.test(exec.id))throw new Error('native exec identity unavailable');
    const execRecord=await this.nativeFact('native-worker-exec.json',{owner_id:this.ownerId,container_id:this.primaryId,exec_id:exec.id});
    const stream=await exec.start({Detach:false,Tty:false,abortSignal:signal});
    let total=0;const chunks:Buffer[]=[];
    stream.on('data',(chunk:Buffer)=>{
      const remaining=Math.max(0,524288-total);if(remaining)chunks.push(chunk.subarray(0,remaining));
      total+=chunk.length;if(total>524288)stream.destroy(new Error('native worker output exceeded bound'));
    });
    try{await finished(stream,{readable:true,writable:false,signal})}
    catch(failure){
      if(!stream.destroyed)stream.destroy();
      const error_category=signal.aborted?'canceled':total>524288?'output_limit':'stream_error';
      try{await this.nativeFact('native-worker-output-partial.json',{owner_id:this.ownerId,container_id:this.primaryId,exec_id:exec.id,
        complete:false,truncated:total>524288,error_category,output_base64:Buffer.concat(chunks).toString('base64')})}
      catch(retentionError){throw new AggregateError([failure,retentionError],'native worker output retention failed')}
      throw failure;
    }
    finally{if(!stream.readableEnded)stream.destroy()}
    const inspected=await exec.inspect({abortSignal:signal});
    if(inspected.ID!==exec.id||inspected.ContainerID!==this.primaryId||inspected.Running!==false||!Number.isInteger(inspected.ExitCode))throw new Error('native exec settlement is unverified');
    const afterProcess=await this.processFact('after',signal),after=await this.currentActor(signal);
    if(JSON.stringify(afterProcess.facts.px4_process)!==JSON.stringify(process.facts.px4_process))throw new Error('PX4 process changed during native worker');
    const execResult=await this.nativeFact('native-worker-result.json',{owner_id:this.ownerId,container_id:this.primaryId,exec_id:exec.id,
      started:true,stream_complete:true,inspect:{ID:inspected.ID,ContainerID:inspected.ContainerID,Running:inspected.Running,ExitCode:inspected.ExitCode},
      output_base64:Buffer.concat(chunks).toString('base64')});
    this.actorAfterRef=await this.nativeFact('actor-after.json',{owner_id:this.ownerId,captured_unix_ns:String(BigInt(Date.now())*1000000n),
      ...after,process_record:{...afterProcess.ref,media_type:'application/json'},
      exec_record:{...execRecord,media_type:'application/json'},exec_result:{...execResult,media_type:'application/json'}});
    if(inspected.ExitCode===0||inspected.ExitCode===1)this.workerState='settled';
    if(inspected.ExitCode!==0)throw new Error('native worker reported incomplete execution; physical outcome is unknown');
    return [...this.refs];
  }
  async ready(signal:AbortSignal):Promise<{ready:boolean;evidenceRefs:ArtifactRef[]}>{
    await this.launched;signal.throwIfAborted();
    if(this.config.mode!=='native-sdk-v2'){
      const sdk=this.ctx.get('mavsdk') as Mavsdk;
      if(!sdk?.transportReady)throw new Error('native gRPC transport readiness missing');
      const connected=await sdk.observeConnectionState(signal);
      if(connected.connection_state?.is_connected!==true)throw new Error('native Core reports no connected PX4 vehicle');
      const path=join(this.output,'core-connection.json');await writeFile(path,JSON.stringify(connected));this.refs.push(await reference(path));
    }
    const facts=await this.probe('ready','gz-readiness.json',1,signal);
    if(facts.ready!==true||facts.owner_id!==this.ownerId||facts.model!=='x500_0')throw new Error('stock model readiness missing');
    if(record(facts.oci_init).sha256!=='43e9b836ca7631672f12d0610cd574875b62d236dfd62e3b86751f35862e5eba')throw new Error('actual stock OCI init identity is unqualified');
    return {ready:true,evidenceRefs:[...this.refs]};
  }
  async probe(mode:'ready'|'observe'|'last-state',name:string,seconds:number,signal:AbortSignal):Promise<Record<string,unknown>>{
    if(!/^[a-z][a-z0-9-]*\.json$/.test(name)||!Number.isFinite(seconds)||seconds<=0||seconds>60)throw new Error('invalid finite native probe');
    const relative='/run/robotics/output/px4/'+this.output.split('/').at(-1)+'/'+name;
    const result=await this.compose.run(['exec','-T','px4-native','/usr/bin/python3','-B','/opt/robotics/px4/probe.py',
      '--mode',mode,'--owner-id',this.ownerId,'--output',relative,'--seconds',String(seconds)],signal);
    const invocation=join(this.output,name.replace('.json','-job.json'));await writeFile(invocation,JSON.stringify(result));this.refs.push(await reference(invocation));
    if(!result.ok)throw new Error(result.diagnostic??'native Gz probe failed');
    const path=join(this.output,name);const raw=await readFile(path);
    if(raw.length>8388608)throw new Error('native observation exceeds finite bound');
    const facts=record(JSON.parse(raw.toString('utf8')));this.refs.push(await reference(path));return facts;
  }
  private async captureLogs(name:string,signal?:AbortSignal):Promise<void>{
    const services=this.config.mode==='native-sdk-v2'?['px4-native']:['px4-native','mavsdk-native'];
    const logs=await this.compose.run(['logs','--no-color',...services],signal);
    if(!logs.ok)throw new Error('native worker logs could not be retained before stop');
    const path=join(this.output,name);await writeFile(path,logs.stdout+logs.stderr);this.refs.push(await reference(path));
  }
  async diagnosticEvidence(signal:AbortSignal):Promise<ArtifactRef[]>{
    await this.captureLogs('diagnostic-workers.log',signal);
    return [...this.refs];
  }
  async closeNativeMeasurement(signal:AbortSignal):Promise<ArtifactRef[]>{
    let failure:unknown;
    try{if(!this.workerPromise)throw new Error('native worker was not invoked');await this.workerPromise}catch(error){failure=error}
    if(this.workerState!=='settled')throw new Error('native worker settlement is unverified',{cause:failure});
    const refs=await this.drainRecorders(signal);
    if(failure)throw failure;
    return refs;
  }
  async captureLastState(signal:AbortSignal):Promise<ArtifactRef[]>{
    if(this.config.mode==='native-sdk-v2'&&!this.loggerClosed)throw new Error('logger closure must precede world pause');
    await this.probe('last-state','last-native-state.json',3,signal);
    await this.captureLogs('native-workers.log',signal);
    return [...this.refs];
  }
  private loggerDrain:Promise<ArtifactRef[]>|undefined;
  drainRecorders(signal:AbortSignal):Promise<ArtifactRef[]>{return this.loggerDrain??=this.stopLogger(signal)}
  private async stopLogger(signal:AbortSignal):Promise<ArtifactRef[]>{
    if(this.config.mode==='native-sdk-v2'){
      if(this.workerState!=='settled'||!this.loggerStarted)throw new Error('worker settlement or logger start is unverified');
      await this.currentActor(signal);
      const stopped=await this.loggerCommand('stop','after-case',signal);
      const status=await this.loggerCommand('status','after-case',signal);
      this.loggerStopRef=await this.nativeFact('logger-stop.json',{...stopped,status_after:status});
      if(!stopped.result.ok||stopped.result.exitCode!==0||status.result.ok||!Number.isInteger(status.result.exitCode)||status.result.exitCode===0||
        status.result.timedOut||status.result.canceled||status.result.stderr.trim()||
        !/^(?:INFO\s+\[logger\]\s+)?not running\s*$/.test(status.result.stdout)||
        /timeout, forcing stop|server not running|error connecting/i.test(stopped.result.stdout+stopped.result.stderr+status.result.stdout))throw new Error('stock logger shutdown is unverified');
      await this.currentActor(signal);
      this.loggerClosed=true;return [...this.refs];
    }
    const stopped=await this.compose.run(['exec','-T','px4-native','/opt/px4/build/px4_sitl_default/bin/px4-logger','stop'],signal);
    const path=join(this.output,'native-logger-stop.json');await writeFile(path,JSON.stringify(stopped));this.refs.push(await reference(path));
    if(!stopped.ok)throw new Error(stopped.diagnostic??'stock native logger did not drain');
    return [...this.refs];
  }
  async exportEvidence(signal:AbortSignal):Promise<ArtifactRef[]>{
    signal.throwIfAborted();
    if(!this.refs.length)throw new Error('native run evidence is absent');
    if(this.config.mode==='native-sdk-v2'&&(this.workerState!=='settled'||!this.loggerClosed))throw new Error('native worker settlement or logger closure is unverified');
    const source=join(this.output,'rootfs/log');
    const entries:{name:string;source:string;relativePath:string}[]=[];
    const visit=async(dir:string,prefix=''):Promise<void>=>{
      for(const name of await readdir(dir)){
        const path=join(dir,name),facts=await lstat(path),relative=prefix+name;
        if(facts.isSymbolicLink())throw new Error('native log inventory contains a symbolic link');
        if(facts.isDirectory())await visit(path,relative+'/');
        else if(facts.isFile())entries.push({name:relative,source:relative,relativePath:relative});
      }
    };
    await visit(source);
    if(!entries.length)throw new Error('stock logger produced no retained native payload');
    const workerRoot='/run/robotics/output/px4/'+this.output.split('/').at(-1);
    const native=this.config.mode==='native-sdk-v2';
    const plan={version:1,runId:this.ownerId,sourceRoot:workerRoot+'/rootfs/log',destinationRoot:native?this.workerArchive+'/capture/retained-native-logs':workerRoot+'/retained-native-logs',maximumBytes:134217728,entries};
    const planPath=join(this.output,'native-log-export-plan.json');
    await writeFile(planPath,JSON.stringify(plan),{flag:'wx'});
    const copied=await this.compose.run(['exec','-T','px4-native','/usr/bin/python3','-B','/opt/robotics/px4/opaque_export.py','--plan',workerRoot+'/native-log-export-plan.json'],signal);
    const jobPath=join(this.output,'native-log-export-job.json');await writeFile(jobPath,JSON.stringify(copied));
    if(!copied.ok)throw new Error(copied.diagnostic??'opaque native log byte export failed');
    const retained=native?join(this.archiveRoot!,'capture','retained-native-logs'):join(this.output,'retained-native-logs');
    const manifestPath=join(retained,'export-manifest.json');
    const bounded=native?await this.readNativeFact(manifestPath):undefined;
    const manifest=bounded?bounded.facts:record(JSON.parse(await readFile(manifestPath,'utf8')));
    if(manifest.status!=='complete'||manifest.runId!==this.ownerId)throw new Error('native byte retention is incomplete');
    const payload=await Promise.all(entries.map(v=>reference(join(retained,v.relativePath))));
    const manifestRef=bounded?bounded.ref:await reference(manifestPath);
    if(native){
      if(!this.actorBeforeRef||!this.actorAfterRef||!this.loggerStartRef||!this.loggerStopRef||!this.loggerPath)throw new Error('original native custody facts are incomplete');
      const logName=this.loggerPath.replace(/^\.\//,'').replace(/^log\//,'');
      const matches=entries.map((entry,index)=>({entry,index})).filter(({entry})=>entry.relativePath===logName);
      if(matches.length!==1)throw new Error('logger path does not identify exactly one exported ULog');
      const item=matches[0]!,ulog=payload[item.index]!;
      const leaf=(ref:ArtifactRef,media_type:string)=>({...ref,media_type});
      const binding={run_id:this.ownerId,domain_id:'px4',kind:'native-evidence',value:{ulog:leaf(ulog,'application/octet-stream'),
        custody:{actor_before:leaf(this.actorBeforeRef,'application/json'),actor_after:leaf(this.actorAfterRef,'application/json'),
          logger_start:leaf(this.loggerStartRef,'application/json'),logger_stop:leaf(this.loggerStopRef,'application/json'),
          export_manifest:leaf(manifestRef,'application/json')}}};
      const bindingPath=join(this.archiveRoot!,'capture','native-evidence.json');
      await writeFile(bindingPath,JSON.stringify(binding)+'\n',{flag:'wx'});this.refs.push(await reference(bindingPath));
    }
    return [...this.refs,await reference(planPath),await reference(jobPath),manifestRef,...payload];
  }
}
export default Px4Native;
