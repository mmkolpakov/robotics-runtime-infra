import {Service,referenceFile} from '@robotics-runtime/host';
import type {ArtifactRef,Context,Mavsdk} from '@robotics-runtime/host';
import {createHash,randomUUID} from 'node:crypto';
import {mkdir,readFile,readdir,lstat,writeFile} from 'node:fs/promises';
import {isAbsolute,join} from 'node:path';
import {ComposeExecution} from '../../compose-execution.js';
import {EngineMetadata} from '../../engine-metadata.js';

export interface Px4Config {
  composeExecutable:string;socketPath:string;composeFiles:readonly string[];cwd:string;
  workerImage:string;runVolume:string;outputRoot:string;grpcPort:number;deadlineMs?:number;
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
  constructor(ctx:Context,readonly config:Px4Config){
    super(ctx,'px4');
    const deadline=config.deadlineMs??120000;
    if(!Number.isSafeInteger(deadline)||deadline<=0||deadline>300000)throw new Error('invalid finite PX4 deadline');
    if(![config.composeExecutable,config.socketPath,config.cwd,config.outputRoot,...config.composeFiles].every(isAbsolute))throw new Error('provider paths must be absolute');
    if(!/@sha256:[a-f0-9]{64}$/.test(config.workerImage))throw new Error('immutable stock worker digest required');
    if(!Number.isSafeInteger(config.grpcPort)||config.grpcPort<1024||config.grpcPort>65535)throw new Error('configured unprivileged local gRPC port required');
    this.deadline=deadline;this.ownerId=ctx.runResources.ownerId;
    const scope=createHash('sha256').update(this.ownerId+randomUUID()).digest('hex').slice(0,24);
    this.project='rr-px4-'+scope;this.output=join(config.outputRoot,scope);
    this.compose=new ComposeExecution(ctx.jobs,{
      executable:config.composeExecutable,socketPath:config.socketPath,projectName:this.project,
      files:config.composeFiles,cwd:config.cwd,timeoutMs:deadline,maxBufferBytes:1048576,
      env:{ROBOTICS_PX4_IMAGE:config.workerImage,ROBOTICS_RUN_VOLUME:config.runVolume,
        ROBOTICS_RUN_ID:this.ownerId,ROBOTICS_PX4_SCOPE:scope,ROBOTICS_PX4_GRPC_PORT:String(config.grpcPort)},
    });
    ctx.runResources.track({id:this.project,ownerId:this.ownerId,
      cleanup:async()=>{
        const result=await this.compose.run(['down','--remove-orphans','--timeout','5']);
        if(!result.ok)throw new Error(result.diagnostic??'owned PX4 project cleanup failed');
      },
      verifyCleanup:async signal=>{
        signal.throwIfAborted();
        if(!this.engine)return {released:false,evidenceRefs:[],diagnostic:'native Engine was not observed'};
        const observed=await this.engine.remainingOwned(this.ownerId);
        const owned=(values:unknown[])=>values.filter(v=>record(record(v).Labels??{})['com.docker.compose.project']===this.project);
        const released=!owned(observed.containers).length&&!owned(observed.networks).length;
        const path=join(this.output,'engine-cleanup.json');
        await writeFile(path,JSON.stringify({owner_id:this.ownerId,project:this.project,released,observed}));
        return {released,evidenceRefs:[await reference(path)]};
      }});
  }
  async *[Service.init](){
    this.launched=this.launch();
    await this.launched;
  }
  private async launch():Promise<void>{
    await mkdir(join(this.output,'rootfs'),{recursive:true});
    await this.compose.requireVersion();
    this.engine=await EngineMetadata.connect({socketPath:this.config.socketPath,operationMinApi:'1.24',operationMaxApi:'1.53'});
    const started=await this.compose.run(['up','--detach','px4-native','mavsdk-native']);
    await writeFile(join(this.output,'compose-launch.json'),JSON.stringify(started));
    this.refs.push(await reference(join(this.output,'compose-launch.json')));
    if(!started.ok)throw new Error(started.diagnostic??'stock firmware/server launch failed');
    let primaryId:string|undefined;
    for(const name of ['px4-native','mavsdk-native']){
      const ps=await this.compose.run(['ps','--all','--quiet',name]);const id=ps.stdout.trim();
      if(!ps.ok||! /^[a-f0-9]{64}$/.test(id))throw new Error('exact worker container ID missing');
      if(name==='px4-native')primaryId=id;
      const observation=await this.engine.inspect(id,{networkNamespaceContainerId:name==='mavsdk-native'?primaryId:undefined,runId:this.ownerId,projectName:this.project,
        imageDigest:this.config.workerImage,mounts:name==='px4-native'?[{destination:'/run/robotics',readOnly:false,volumeName:this.config.runVolume}]:[],
        hostConfig:{Init:true,ReadonlyRootfs:true,Memory:name==='px4-native'?4294967296:268435456},user:'1000:1000'});
      const path=join(this.output,name+'-engine.json');await writeFile(path,JSON.stringify(observation));this.refs.push(await reference(path));
      if(observation.status!=='complete')await this.captureLogs('startup-workers.log');
      if(observation.status!=='complete'||record(record(observation.container).State).Running!==true)throw new Error('native Engine readiness facts incomplete');
    }
  }
  async ready(signal:AbortSignal):Promise<{ready:boolean;evidenceRefs:ArtifactRef[]}>{
    await this.launched;signal.throwIfAborted();
    const sdk=this.ctx.get('mavsdk') as Mavsdk;
    if(!sdk?.transportReady)throw new Error('native gRPC transport readiness missing');
    const connected=await sdk.observeConnectionState(signal);
    if(connected.connection_state?.is_connected!==true)throw new Error('native Core reports no connected PX4 vehicle');
    const path=join(this.output,'core-connection.json');await writeFile(path,JSON.stringify(connected));this.refs.push(await reference(path));
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
    const logs=await this.compose.run(['logs','--no-color','px4-native','mavsdk-native'],signal);
    if(!logs.ok)throw new Error('native worker logs could not be retained before stop');
    const path=join(this.output,name);await writeFile(path,logs.stdout+logs.stderr);this.refs.push(await reference(path));
  }
  async diagnosticEvidence(signal:AbortSignal):Promise<ArtifactRef[]>{
    await this.captureLogs('diagnostic-workers.log',signal);
    return [...this.refs];
  }
  async captureLastState(signal:AbortSignal):Promise<ArtifactRef[]>{
    await this.probe('last-state','last-native-state.json',3,signal);
    await this.captureLogs('native-workers.log',signal);
    return [...this.refs];
  }
  private loggerDrain:Promise<ArtifactRef[]>|undefined;
  drainRecorders(signal:AbortSignal):Promise<ArtifactRef[]>{return this.loggerDrain??=this.stopLogger(signal)}
  private async stopLogger(signal:AbortSignal):Promise<ArtifactRef[]>{
    const stopped=await this.compose.run(['exec','-T','px4-native','/opt/px4/build/px4_sitl_default/bin/px4-logger','stop'],signal);
    const path=join(this.output,'native-logger-stop.json');await writeFile(path,JSON.stringify(stopped));this.refs.push(await reference(path));
    if(!stopped.ok)throw new Error(stopped.diagnostic??'stock native logger did not drain');
    return [...this.refs];
  }
  async exportEvidence(signal:AbortSignal):Promise<ArtifactRef[]>{
    signal.throwIfAborted();
    if(!this.refs.length)throw new Error('native run evidence is absent');
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
    const plan={version:1,runId:this.ownerId,sourceRoot:workerRoot+'/rootfs/log',destinationRoot:workerRoot+'/retained-native-logs',maximumBytes:134217728,entries};
    const planPath=join(this.output,'native-log-export-plan.json');
    await writeFile(planPath,JSON.stringify(plan),{flag:'wx'});
    const copied=await this.compose.run(['exec','-T','px4-native','/usr/bin/python3','-B','/opt/robotics/px4/opaque_export.py','--plan',workerRoot+'/native-log-export-plan.json'],signal);
    const jobPath=join(this.output,'native-log-export-job.json');await writeFile(jobPath,JSON.stringify(copied));
    if(!copied.ok)throw new Error(copied.diagnostic??'opaque native log byte export failed');
    const retained=join(this.output,'retained-native-logs');
    const manifest=record(JSON.parse(await readFile(join(retained,'export-manifest.json'),'utf8')));
    if(manifest.status!=='complete'||manifest.runId!==this.ownerId)throw new Error('native byte retention is incomplete');
    const payload=await Promise.all(entries.map(v=>reference(join(retained,v.relativePath))));
    return [...this.refs,await reference(planPath),await reference(jobPath),await reference(join(retained,'export-manifest.json')),...payload];
  }
}
export default Px4Native;
