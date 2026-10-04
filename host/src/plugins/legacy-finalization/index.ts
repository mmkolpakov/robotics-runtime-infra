import {Context,Service,referenceFile} from '@robotics-runtime/host';
import type {ArtifactRef,CompletionHooks,JobResult,RunCompletion} from '@robotics-runtime/host';
import {createHash} from 'node:crypto';
import {createReadStream} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {mkdir,readFile,writeFile,copyFile,stat} from 'node:fs/promises';
import Docker from 'dockerode';
import {Readable,Writable} from 'node:stream';
import {finished} from 'node:stream/promises';
import {join,resolve,isAbsolute,relative,dirname} from 'node:path';
import {setTimeout as pause} from 'node:timers/promises';
import {ComposeExecution} from '../../compose-execution.js';
import {EngineMetadata} from '../../engine-metadata.js';
import type {LegacyFinalizationPlan} from './inputs.js';

const object=(v:unknown):Record<string,unknown>=>{
  if(!v||typeof v!=='object'||Array.isArray(v)) throw new Error('native fact must be an object');
  return v as Record<string,unknown>;
};
/** Recordings can exceed host memory; this is byte hashing, never payload decoding. */
async function referenceRetained(path:string):Promise<ArtifactRef>{
  const before=await stat(path,{bigint:true});
  if(!before.isFile()||before.size>BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('retained artifact size is invalid');
  const hash=createHash('sha256');
  for await(const block of createReadStream(path)) hash.update(block);
  const after=await stat(path,{bigint:true});
  if(['dev','ino','size','mtimeNs','ctimeNs'].some(k=>before[k as keyof typeof before]!==after[k as keyof typeof after])) throw new Error('retained artifact changed while hashing');
  return {uri:pathToFileURL(path).href,sha256:hash.digest('hex'),size_bytes:Number(before.size)};
}
declare module 'cordis'  {interface Context {legacyFinalization:LegacyFinalization;}}
/** Startup and physical disposal remain separate owners; these callbacks are finite. */
export class LegacyFinalization extends Service {
  static inject=['jobs','runResources','legacyFinalizationInputs'];
  private readonly plan:Readonly<LegacyFinalizationPlan>;
  private readonly compose:ComposeExecution;
  private readonly postprocess:ComposeExecution;
  private engine:EngineMetadata|undefined;
  private observerId:string|undefined;
  private counter=0;
  private readonly refs:ArtifactRef[]=[];
  private readonly work=new Map<string,Promise<readonly ArtifactRef[]>>();
  constructor(ctx:Context){
    super(ctx,'legacyFinalization');
    this.plan=ctx.legacyFinalizationInputs.get(ctx.runResources.ownerId);
    if(![this.plan.artifactDirectory,this.plan.retainedDirectory,this.plan.measurementCompletePath].every(isAbsolute)) throw new Error('host paths must be absolute');
    this.compose=new ComposeExecution(ctx.jobs,this.plan.compose);
    this.postprocess=new ComposeExecution(ctx.jobs,this.plan.postprocessCompose);
  }
  private async retain(name:string,value:unknown):Promise<ArtifactRef>{
    await mkdir(this.plan.artifactDirectory,{recursive:true});
    const path=join(this.plan.artifactDirectory,String(++this.counter).padStart(4,'0')+'-'+name+'.json');
    await writeFile(path,JSON.stringify(value,null,2)+'\n');
    const ref=await referenceFile(path);this.refs.push(ref);return ref;
  }
  private async require(name:string,args:readonly string[],signal:AbortSignal,executor:ComposeExecution=this.compose):Promise<JobResult>{
    signal.throwIfAborted();
    const result=await executor.run(args,signal);
    await this.retain(name,result);
    if(!result.ok) throw new Error(name+': '+(result.diagnostic??result.stderr));
    return result;
  }
  private async facts(service:string,signal:AbortSignal,id?:string):Promise<Record<string,unknown>>{
    if(!id) id=(await this.require(service+'-id',['ps','--all','--quiet',service],signal)).stdout.trim();
    const requirement=this.plan.requirements[service];
    if(!requirement) throw new Error('no admitted native requirement for '+service);
    this.engine??=await EngineMetadata.connect({socketPath:this.plan.compose.socketPath,operationMinApi:'1.24',operationMaxApi:'1.53'});
    const observed=await this.engine.inspect(id,requirement);
    await this.retain(service+'-native-state',observed);
    if(observed.status!=='complete') throw new Error(service+' native metadata incomplete');
    return object(object(observed.container).State);
  }
  private once(name:string,work:()=>Promise<readonly ArtifactRef[]>):Promise<readonly ArtifactRef[]>{
    let result=this.work.get(name);
    if(!result){result=work();this.work.set(name,result)}
    return result;
  }
  async beginMeasurement(signal:AbortSignal):Promise<readonly ArtifactRef[]>{
    if(this.observerId) throw new Error('measurement observer already acquired');
    await this.compose.requireVersion();
    await this.retain('startup-readiness-inputs',this.plan.startupRefs);
    const source=await this.facts(this.plan.simulationService,signal,this.plan.sourceContainerId);
    if(source.Running!==true) throw new Error('native measurement source is not running');
    if(this.plan.instrumentServices.length) await this.require('instruments',['up','--detach','--no-build',...this.plan.instrumentServices],signal);
    if(this.plan.recorderServices.length) await this.require('recorders',['up','--detach','--no-build','--wait','--wait-timeout','120',...this.plan.recorderServices],signal);
    const started=await this.require('observer',['run','--detach','--no-deps','--name',this.plan.compose.projectName+'-observer',this.plan.observerService],signal);
    this.observerId=started.stdout.trim();
    if(!/^[a-f0-9]{64}$/.test(this.observerId)) throw new Error('exact acquired observer ID absent');
    await this.facts(this.plan.observerService,signal,this.observerId);
    return [...this.refs];
  }
  readonly hooks:CompletionHooks={
    closeMeasurement:signal=>this.once('close',async()=>{
      if(!this.observerId) throw new Error('measurement has no native observer');
      const deadline=performance.now()+this.plan.timeoutMs;
      for(;;){
        signal.throwIfAborted();
        const observer=await this.facts(this.plan.observerService,signal,this.observerId);
        const source=await this.facts(this.plan.simulationService,signal,this.plan.sourceContainerId);
        if(source.Running!==true) throw new Error('source ended before live completion proof');
        try {await readFile(this.plan.measurementCompletePath);break}
        catch(error){if(object(error).code!=='ENOENT') throw error}
        if(observer.Running!==true) throw new Error('observer ended before measurement completion');
        if(performance.now()>=deadline) throw new Error('measurement completion deadline exceeded');
        await pause(100,undefined,{signal});
      }
      await this.retain('measurement-complete',{marker:await referenceFile(this.plan.measurementCompletePath),observerId:this.observerId,sourceContainerId:this.plan.sourceContainerId});
      for(const service of this.plan.instrumentServices){
        await this.require('stop-'+service,['stop','--timeout','30',service],signal);
        if((await this.facts(service,signal)).Running!==false) throw new Error(service+' remained running');
      }
      return [...this.refs];
    }),
    captureLastState:signal=>this.once('last',async()=>{
      await this.require('freeze-writer',['stop','--timeout','30',this.plan.stepperService],signal);
      if((await this.facts(this.plan.stepperService,signal)).Running!==false) throw new Error('periodic writer still running');
      const result=await this.require('native-last-state',['exec','-T',this.plan.simulationService,'robotics-entrypoint','python3',this.plan.lastStateWorkerPath],signal);
      const native=object(JSON.parse(result.stdout));
      if(native.phase!=='native-last-state-before-destructive-reset'||native.reset_performed!==false||typeof native.clock_ns!=='string'||!/^\d+$/.test(native.clock_ns)||native.result_ok!==true) throw new Error('native last-state observation incomplete');
      const path=join(this.plan.artifactDirectory,'last-native-state.json');
      await writeFile(path,result.stdout);this.refs.push(await referenceFile(path));
      return [...this.refs];
    }),
    drainRecorders:signal=>this.once('drain',async()=>{
      for(const service of [this.plan.collectorService,...this.plan.recorderServices]){
        await this.require('drain-'+service,['stop','--timeout','30',service],signal);
        const actual=await this.facts(service,signal);
        if(actual.Running!==false||actual.ExitCode!==0) throw new Error(service+' did not confirm clean native drain');
      }
      await this.require('metrics',['run','--rm','--no-deps','evidence-sink','artifact',this.plan.evidenceRoot+'/metrics.otlp.jsonl','application/x-ndjson','900000'],signal);
      await this.require('finalize',['run','--rm','--no-deps','evidence-finalize'],signal);
      if(!this.observerId) throw new Error('observer ID absent');
      const deadline=performance.now()+this.plan.timeoutMs;
      for(;;){
        const observer=await this.facts(this.plan.observerService,signal,this.observerId);
        if(observer.Running===false){if(observer.ExitCode!==0) throw new Error('public live observer verification failed');break}
        if(performance.now()>=deadline) throw new Error('public live observer did not finish after evidence finalization');
        await pause(100,undefined,{signal});
      }
      const foundation=await this.require('final-logs',['logs','--no-color'],signal);
      await mkdir(dirname(this.plan.foundationLogPath),{recursive:true});
      await writeFile(this.plan.foundationLogPath,foundation.stdout,{flag:'wx'});
      this.refs.push(await referenceFile(this.plan.foundationLogPath));
      if(!this.engine) throw new Error('native observer evidence endpoint absent');
      const logs=await this.engine.readLogs(this.observerId,{runId:this.plan.runId,projectName:this.plan.compose.projectName},{tailLines:10000,maxBytes:1048576,deadlineMs:Math.min(this.plan.timeoutMs,120000)},signal);
      await mkdir(dirname(this.plan.observerLogPath),{recursive:true});
      const rawPath=this.plan.observerLogPath+'.docker-raw';
      await writeFile(rawPath,logs.bytes,{flag:'wx'});
      this.refs.push(await referenceFile(rawPath));
      const chunks:Buffer[]=[];
      const capture=()=>new Writable({write(chunk,_encoding,callback){chunks.push(Buffer.from(chunk));callback()}});
      const source=Readable.from([logs.bytes]);
      if(logs.tty) source.on('data',chunk=>chunks.push(Buffer.from(chunk)));
      else new Docker({socketPath:this.plan.compose.socketPath,version:'v'+this.engine.facts.clientApi}).modem.demuxStream(source,capture(),capture());
      await finished(source);
      await writeFile(this.plan.observerLogPath,Buffer.concat(chunks),{flag:'wx'});
      this.refs.push(await referenceFile(this.plan.observerLogPath));
      return [...this.refs];
    }),
    exportEvidence:signal=>this.performExport(this.plan,signal),
  };
  /** Use this callback with public run.retryExport; the retained run/fiber stays alive. */
  async exportAttempt(token:string,signal:AbortSignal):Promise<readonly ArtifactRef[]>{
    const attempt=this.ctx.legacyFinalizationInputs.getExportAttempt(this.plan.runId,token);
    return this.performExport({...this.plan,...attempt},signal);
  }
  private finite(name:string,command:readonly string[],signal:AbortSignal,executor:ComposeExecution=this.compose,service=this.plan.coordinatorService):Promise<JobResult>{
    return this.require(name,['run','--rm','--no-deps',service,'timeout','--signal=TERM','--kill-after=5s',String(Math.ceil(this.plan.timeoutMs/1000)),...command],signal,executor);
  }
  private async performExport(plan:Readonly<LegacyFinalizationPlan>,signal:AbortSignal):Promise<readonly ArtifactRef[]>{
      // RunOwner retains acquisition on failure; there is no destructive finally here.
      await this.finite('inventory',[plan.contractPythonPath,plan.inventoryWorkerPath,'--plan',plan.inventoryPlanPath,'--output',plan.exportPlanPath,'--arguments',plan.qualificationInputsWorkerPath],signal,this.compose,plan.exportCoordinatorService??plan.coordinatorService);
      await this.finite('export',[plan.contractPythonPath,plan.exportWorkerPath,'--plan',plan.exportPlanPath],signal,this.compose,plan.exportCoordinatorService??plan.coordinatorService);
      const manifestPath=join(plan.retainedDirectory,'export-manifest.json');
      const manifest=object(JSON.parse((await readFile(manifestPath)).toString('utf8')));
      if(manifest.status!=='complete'||manifest.runId!==plan.runId||!Array.isArray(manifest.entries)||!manifest.entries.length) throw new Error('retained manifest incomplete');
      const exported:ArtifactRef[]=[];
      for(const raw of manifest.entries){
        const entry=object(raw);
        if(typeof entry.relativePath!=='string') throw new Error('invalid retained path');
        const path=resolve(plan.retainedDirectory,entry.relativePath);
        const rel=relative(plan.retainedDirectory,path);
        if(!rel||rel.startsWith('..')||isAbsolute(rel)) throw new Error('retained reference escapes output');
        const ref=await referenceRetained(path);
        if(ref.sha256!==entry.sha256||ref.size_bytes!==entry.size_bytes) throw new Error('retained bytes differ from export');
        exported.push(ref);
      }
      return [...exported,await referenceFile(manifestPath),await referenceFile(plan.qualificationInputsHostPath),...this.refs];
  }

  async aggregateAfterCleanup(completion:RunCompletion,signal:AbortSignal):Promise<ArtifactRef>{
    if(completion.runId!==this.plan.runId||completion.status!=='passed'||!completion.resourceOutcomes.length||completion.resourceOutcomes.some(r=>!r.attempted||!r.released||r.cleanupError)) throw new Error('evaluation requires export and independently verified cleanup');
    const result=await this.finite('aggregate',['/opt/contracts/bin/robotics-acceptance','aggregate','--scenario',this.plan.scenarioPath,'--run-context',this.plan.runContextPath,'--result',this.plan.resultPath,'--output',this.plan.aggregatePath],signal,this.postprocess);
    return this.retain('aggregate-complete',result);
  }
  private async cleanupPostprocess(signal:AbortSignal):Promise<void>{
    const clean=await this.postprocess.run(['down','--remove-orphans'],signal);
    await this.retain('postprocess-cleanup',clean);
    if(!clean.ok) throw new Error('finite qualification worker project cleanup failed');
    const remaining=await (await EngineMetadata.connect({socketPath:this.plan.postprocessCompose.socketPath,operationMinApi:'1.24',operationMaxApi:'1.53'})).remainingOwned(this.plan.runId);
    const owned=remaining.containers.filter(v=>object(object(v).Labels)['com.docker.compose.project']===this.plan.postprocessCompose.projectName);
    const networks=remaining.networks.filter(v=>object(object(v).Labels)['com.docker.compose.project']===this.plan.postprocessCompose.projectName);
    if(owned.length||networks.length) throw new Error('qualification worker resources remain');
    await this.retain('postprocess-native-inventory',remaining);
  }
  async qualifyAfterCleanup(completion:RunCompletion,signal:AbortSignal):Promise<readonly ArtifactRef[]>{
    let original:unknown;
    try {
    await this.aggregateAfterCleanup(completion,signal);
    const values:unknown=JSON.parse(await readFile(this.plan.qualificationInputsHostPath,'utf8'));
    if(!Array.isArray(values)||values.some(v=>typeof v!=='string')||values.length>8192) throw new Error('invalid retained qualification argument inventory');
    const args=[...values as string[],'--aggregate',this.plan.aggregatePath];
    const root=this.plan.retainedWorkerRoot;
    const helper=this.plan.helperRoot;
    const invoke=async(name:string,command:readonly string[])=>this.finite(name,command,signal,this.postprocess);
    await invoke('package',[helper+'/scripts/qualification/package-artifacts','--output',root+'/qualification',...args]);
    await invoke('statement',[helper+'/scripts/qualification/create-statement',...args,'--output',root+'/qualification-statement.json']);
    await invoke('sign',['bash',helper+'/scripts/ci/foundation/sign-ephemeral-qualification.sh',root+'/qualification-statement.json',root+'/qualification.sigstore.json',root+'/qualification.pub']);
    for(const name of ['qualification-statement.json','qualification.sigstore.json','qualification.pub']) await copyFile(join(this.plan.retainedDirectory,name),join(this.plan.retainedDirectory,'qualification',name));
    const portable=(await readFile(join(this.plan.retainedDirectory,'qualification','qualification-arguments.txt'),'utf8')).trimEnd().split('\n');
    await this.require('portable-verify',['run','--rm','--no-deps','--workdir',root+'/qualification',this.plan.coordinatorService,'timeout','--signal=TERM','--kill-after=5s',String(Math.ceil(this.plan.timeoutMs/1000)),helper+'/scripts/qualification/verify-bundle',...portable,'--bundle','qualification.sigstore.json','--key','qualification.pub'],signal,this.postprocess);
    return Promise.all(['qualification-statement.json','qualification.sigstore.json','qualification.pub','acceptance-aggregate.json'].map(name=>referenceFile(join(this.plan.retainedDirectory,name))));
    } catch(error) {
      original=error;
      await this.retain('postprocess-error',{error:String(error),retainedDirectory:this.plan.retainedDirectory});
      throw error;
    } finally {
      try {await this.cleanupPostprocess(AbortSignal.timeout(Math.min(this.plan.timeoutMs,120000)))}
      catch(error){if(original!==undefined)throw new AggregateError([original,error],'postprocessing and acquired worker cleanup failed');throw error}
    }
  }
}
export default LegacyFinalization;
