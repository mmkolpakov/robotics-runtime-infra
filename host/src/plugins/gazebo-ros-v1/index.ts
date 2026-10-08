import {Context,Service,referenceFile} from '@robotics-runtime/host';
import type {BackendReadiness,ArtifactRef,JobResult} from '@robotics-runtime/host';
import {mkdir,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {ComposeExecution} from '../../compose-execution.js';
import {EngineMetadata,requireDockerHealthcheckStartInterval} from '../../engine-metadata.js';
import type {LegacyRunInput} from './inputs.js';

declare module 'cordis' { interface Context { gazeboRosV1: GazeboRosV1; } }
/** Retained ROS provider. Native action/time remains in the installed workers. */
export class GazeboRosV1 extends Service {
  static inject=['jobs','runResources','legacyInputs'];
  private readonly input:Readonly<LegacyRunInput>;
  private readonly compose:ComposeExecution;
  private readonly refs:ArtifactRef[]=[];
  private acquired=false;
  private sequence=0;
  private simulationContainerId:string|undefined;
  private stepperContainerId:string|undefined;
  private readonly nativeMetadataRefs:ArtifactRef[]=[];
  private readyWork:Promise<BackendReadiness>|undefined;
  private startupReady=false;
  private readonly cleanupRefs:ArtifactRef[]=[];
  constructor(ctx:Context) {
    super(ctx,'gazeboRosV1');
    this.input=ctx.legacyInputs.get(ctx.runResources.ownerId);
    this.compose=new ComposeExecution(ctx.jobs,this.input.compose);
    ctx.runResources.track({id:this.input.compose.projectName,ownerId:ctx.runResources.ownerId,
      cleanup:async()=>{if(this.acquired) {
        await this.observeCleanupOwnership(AbortSignal.timeout(Math.min(this.input.compose.timeoutMs??120000,120000)));
        await this.require('cleanup',['down','--volumes','--remove-orphans']);
      }},
      verifyCleanup:async(signal)=>{
        const engine=await EngineMetadata.connect({socketPath:this.input.compose.socketPath,operationMinApi:'1.24',operationMaxApi:'1.53'},{cancelSignal:signal});
        const actual=await engine.remainingOwned(this.input.runId,{cancelSignal:signal});
        const ref=await this.retain('cleanup-native-inventory',actual);
        const project=await engine.projectOwnership({runId:this.input.runId,projectName:this.input.compose.projectName,...(this.simulationContainerId?{networkNamespaceContainerId:this.simulationContainerId}:{})},{cancelSignal:signal});
        const projectRef=await this.retain('post-cleanup-project-ownership',project);
        const volumes=actual.volumes as {Volumes?:unknown[]|null};
        return {released:project.status==='complete' && project.inventory.containers.length===0 && project.inventory.networks.length===0 && actual.containers.length===0 && actual.networks.length===0 && Object.hasOwn(volumes,'Volumes') && (volumes.Volumes===null || volumes.Volumes?.length===0),evidenceRefs:[...this.cleanupRefs,ref,projectRef]};
      }});
  }
  /** Bind partial startup from actual admitted metadata before callers retain diagnostics or request cleanup. */
  async observeCleanupOwnership(signal:AbortSignal) {
    const engine=await EngineMetadata.connect({socketPath:this.input.compose.socketPath,operationMinApi:'1.24',operationMaxApi:'1.53'},{cancelSignal:signal});
    await this.bindPartialStartupParent(engine,signal);
    const owned=await engine.projectOwnership({runId:this.input.runId,projectName:this.input.compose.projectName,...(this.simulationContainerId?{networkNamespaceContainerId:this.simulationContainerId}:{})},{cancelSignal:signal});
    this.cleanupRefs.push(await this.retain('pre-cleanup-project-ownership',owned));
    if(owned.status!=='complete')throw new Error('owned project cleanup refused foreign or unbound native resource');
    return owned;
  }
  private async bindPartialStartupParent(engine:EngineMetadata,signal:AbortSignal):Promise<void> {
    if(this.simulationContainerId)return;
    const inventory=await engine.remainingOwned(this.input.runId,{cancelSignal:signal});
    const candidates=inventory.containers.filter(raw=>{
      const row=raw as {Labels?:Record<string,string>};
      return row.Labels?.['org.robotics.runtime.run-id']===this.input.runId &&
        row.Labels?.['com.docker.compose.project']===this.input.compose.projectName &&
        row.Labels?.['com.docker.compose.service']==='simulation';
    }) as {Id?:string}[];
    this.cleanupRefs.push(await this.retain('partial-start-simulation-inventory',{inventory,candidateCount:candidates.length}));
    if(candidates.length>1)throw new Error('partial startup cleanup has ambiguous simulation parents');
    if(!candidates.length)return;
    const id=candidates[0]!.Id;
    if(typeof id!=='string'||!/^[a-f0-9]{64}$/.test(id))throw new Error('partial startup simulation exact ID absent');
    const metadata=await engine.inspect(id,{...this.input.simulationRequirement,healthcheck:undefined},{cancelSignal:signal});
    this.cleanupRefs.push(await this.retain('partial-start-simulation-native-metadata',metadata));
    const labels=(metadata.container as {Config?:{Labels?:Record<string,string>}}).Config?.Labels;
    if(metadata.status!=='complete'||labels?.['com.docker.compose.service']!=='simulation')
      throw new Error('partial startup simulation native binding incomplete');
    this.simulationContainerId=id;
  }
  snapshot() {
    if(!this.startupReady||!this.simulationContainerId||!this.stepperContainerId) throw new Error('native startup snapshot incomplete');
    return Object.freeze({runId:this.input.runId,simulationContainerId:this.simulationContainerId,stepperContainerId:this.stepperContainerId,readyRefs:Object.freeze(this.refs.map(ref=>Object.freeze({...ref}))),nativeMetadataRefs:Object.freeze(this.nativeMetadataRefs.map(ref=>Object.freeze({...ref}))),compose:Object.freeze({projectName:this.input.compose.projectName}),sharedRoot:'/run/robotics',inputRoot:'/run/robotics/input',evidenceRoot:'/run/robotics/evidence',resultsRoot:'/run/robotics/results'});
  }
  ready(signal:AbortSignal):Promise<BackendReadiness> {return this.readyWork??=this.start(signal)}
  private async retain(name:string,value:unknown):Promise<ArtifactRef> {
    await mkdir(this.input.artifactDirectory,{recursive:true});
    const path=join(this.input.artifactDirectory,String(++this.sequence).padStart(4,'0')+'-'+name+'.json');
    await writeFile(path,JSON.stringify(value,null,2)+'\n');
    return Object.freeze(await referenceFile(path));
  }
  private async require(name:string,args:readonly string[],signal?:AbortSignal,expectedExit=0):Promise<JobResult> {
    signal?.throwIfAborted();
    const result=await this.compose.run(args,signal);
    this.refs.push(await this.retain(name,result));
    if(result.exitCode!==expectedExit || result.timedOut || result.canceled || (expectedExit===0&&!result.ok)) throw new Error(`${name}: ${result.diagnostic??result.stderr}`);
    signal?.throwIfAborted();return result;
  }
  private async start(signal:AbortSignal):Promise<BackendReadiness> {
    signal.throwIfAborted();await this.compose.requireVersion(signal);
    signal.throwIfAborted();
    const engine=await EngineMetadata.connect({socketPath:this.input.compose.socketPath,operationMinApi:'1.24',operationMaxApi:'1.53'},{cancelSignal:signal});
    if(this.input.simulationRequirement.healthcheck?.StartInterval!==undefined) requireDockerHealthcheckStartInterval(engine.facts);
    this.acquired=true;
    await this.require('application-start',['up','--detach','--no-build','--wait','--wait-timeout','120','simulation',...this.input.observationServices],signal);
    const id=await this.require('simulation-id',['ps','--quiet','simulation'],signal);
    const simulationContainerId=id.stdout.trim();
    const metadata=await engine.inspect(simulationContainerId,this.input.simulationRequirement,{cancelSignal:signal});
    const simulationRef=await this.retain('simulation-native-metadata',metadata);this.refs.push(simulationRef);this.nativeMetadataRefs.push(simulationRef);
    if(metadata.status!=='complete') throw new Error('required observed simulation metadata incomplete');
    this.simulationContainerId=simulationContainerId;
    if(this.input.admittedDescriptionPath) {
      const initialLog=await this.require('canonical-initial-log',['logs','--no-color','simulation'],signal);
      const initialCount=(initialLog.stdout.match(/InitializeCanonicalLinks/g)??[]).length;
      await this.require('native-urdf',['run','--rm','--no-deps','neutral-robot','check_urdf',this.input.admittedDescriptionPath],signal);
      await this.require('native-preabsence',['exec','-T','simulation','robotics-entrypoint','python3',this.input.entityWorkerPath,'--expect','absent'],signal);
      const missing=await this.require('missing-file-ack',['run','--rm','--no-deps','neutral-robot','timeout','45','ros2','run','ros_gz_sim','create','-world','empty','-file','/run/robotics/product/.readiness-missing.urdf','-name','unreadable_neutral_robot','-allow_renaming','false'],signal);
      if(!missing.stdout.includes('Entity creation successful.')&&!missing.stderr.includes('Entity creation successful.')) throw new Error('missing-file native ACK not observed');
      const negative=await this.require('missing-file-native-absence',['exec','-T','simulation','robotics-entrypoint','python3',this.input.entityWorkerPath,'--entity','unreadable_neutral_robot','--no-wait','--expect','present','--timeout-sec','5'],signal,70);
      const negativeFact=JSON.parse(negative.stdout) as {status?:string;entity?:string;exists?:boolean;result?:unknown};
      if(negativeFact.status!=='entity_absent'||negativeFact.entity!=='unreadable_neutral_robot'||negativeFact.exists!==false||negativeFact.result==null) throw new Error('strict missing-file native absence was not proved');
      // No clock owner exists while native create/canonical initialization runs.
      await this.require('native-asset-start',['up','--detach','--no-build','--no-deps','--force-recreate','neutral-robot'],signal);
      const spawnDeadline=Date.now()+45000;
      let cleanSpawn=false;
      while(Date.now()<spawnDeadline) {
        const logs=await this.require('native-create-ack',['logs','--no-color','neutral-robot'],signal);
        const ids=[...new Set([...logs.stdout.matchAll(/^.*\[(neutral_robot_create-\d+)\].*Entity creation successful\./gm)].map(m=>m[1]))];
        if(ids.length===1 && logs.stdout.includes(`[${ids[0]}]: process has finished cleanly`)) {cleanSpawn=true;break}
        if(/\[neutral_robot_create-\d+\]: process has died/.test(logs.stdout)) throw new Error('fresh native create process failed');
        await new Promise(resolve=>setTimeout(resolve,100));signal.throwIfAborted();
      }
      if(!cleanSpawn) throw new Error('fresh native create ACK and same-process clean exit absent');
      await this.require('native-entity-and-canonical',['exec','-T','simulation','robotics-entrypoint','python3',this.input.entityWorkerPath,'--expect','present'],signal);
      const deadline=Date.now()+30000;
      let canonical=false;
      while(Date.now()<deadline) {
        const logs=await this.require('canonical-after-create',['logs','--no-color','simulation'],signal);
        if((logs.stdout.match(/InitializeCanonicalLinks/g)??[]).length>initialCount) {canonical=true;break}
        await new Promise(resolve=>setTimeout(resolve,100));signal.throwIfAborted();
      }
      if(!canonical) throw new Error('native canonical initialization after asset creation not observed');
    }
    for(const job of this.input.preClockReadyJobs??[]) await this.require('pre-clock-'+job.id,job.args,signal);
    if((this.input.preClockReadyJobs?.length??0)>0 && this.input.admittedDescriptionPath) {
      await this.require('native-entity-after-preparation',['exec','-T','simulation','robotics-entrypoint','python3',this.input.entityWorkerPath,'--expect','present'],signal);
      const canonical=await this.require('canonical-after-preparation',['logs','--no-color','simulation'],signal);
      if(!canonical.stdout.includes('InitializeCanonicalLinks')) throw new Error('native canonical initialization absent after preparation');
    }
    if(this.input.readyObservationServices?.length) await this.require('late-observation-start',['up','--detach','--no-build','--wait','--wait-timeout','120',...this.input.readyObservationServices],signal);
    await this.require('exclusive-clock-owner',['up','--detach','--no-build','simulation-stepper'],signal);
    const stepperId=await this.require('stepper-id',['ps','--quiet','simulation-stepper'],signal);
    this.stepperContainerId=stepperId.stdout.trim();
    const stepper=await engine.inspect(this.stepperContainerId,{...this.input.stepperRequirement,networkNamespaceContainerId:this.simulationContainerId,hostConfig:{...this.input.stepperRequirement.hostConfig,IpcMode:'container:'+this.simulationContainerId}},{cancelSignal:signal});
    const stepperRef=await this.retain('stepper-native-state',stepper);this.refs.push(stepperRef);this.nativeMetadataRefs.push(stepperRef);
    const raw=stepper.container as {State?:{Running?:boolean;ExitCode?:number}};
    if(stepper.status!=='complete'||raw.State?.Running!==true) throw new Error('native exact stepper is not running');
    const clock=await this.require('native-clock-ownership',['exec','-T','simulation','robotics-entrypoint','python3',this.input.clockWorkerPath],signal);
    const cursor=(JSON.parse(clock.stdout) as {last_ns?:unknown}).last_ns;
    if(typeof cursor!=='string'||!/^\d+$/.test(cursor)||BigInt(cursor)<=0n) throw new Error('native Clock cursor must remain a positive lossless ns string');
    if(this.input.admittedDescriptionPath) await this.require('native-robot-readiness',['exec','-T','neutral-robot','robotics-entrypoint','python3',this.input.readinessWorkerPath,'--after-ns',cursor],signal);
    const lastStepper=await engine.inspect(this.stepperContainerId,{...this.input.stepperRequirement,networkNamespaceContainerId:this.simulationContainerId,hostConfig:{...this.input.stepperRequirement.hostConfig,IpcMode:'container:'+this.simulationContainerId}},{cancelSignal:signal});
    const lastRef=await this.retain('stepper-native-state-after-readiness',lastStepper);this.refs.push(lastRef);this.nativeMetadataRefs.push(lastRef);
    if(lastStepper.status!=='complete'||(lastStepper.container as {State?:{Running?:boolean}}).State?.Running!==true) throw new Error('exact stepper stopped during backend readiness');
    await this.require('strict-stepper-native-log',['logs','--no-color','simulation-stepper'],signal);
    signal.throwIfAborted();this.startupReady=true;
    return Object.freeze({ready:true,evidenceRefs:Object.freeze([...this.refs])});
  }
}
export default GazeboRosV1;
