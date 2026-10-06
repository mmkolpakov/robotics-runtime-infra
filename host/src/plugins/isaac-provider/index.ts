import {Service,referenceFile} from '@robotics-runtime/host';
import type {ArtifactRef,Context} from '@robotics-runtime/host';
import {createHash} from 'node:crypto';
import {mkdir,readFile,stat,writeFile,lstat,chmod} from 'node:fs/promises';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {setTimeout as pause} from 'node:timers/promises';
import {ComposeExecution} from '../../compose-execution.js';
import {EngineMetadata} from '../../engine-metadata.js';
import {requireSupportedIsaacClient,observeIsaacClient,admitIsaacDeployment} from './admission.js';
import {ISAAC_IMAGE,ISAAC_SCENE_SHA256} from './inputs.js';
import type {IsaacPlan} from './inputs.js';

const record=(value:unknown):Record<string,unknown>=>{
  if(!value||typeof value!=='object'||Array.isArray(value))throw new Error('native Isaac fact is not an object');
  return value as Record<string,unknown>;
};
async function reference(path:string):Promise<ArtifactRef>{
  const facts=await lstat(path);if(!facts.isFile())throw new Error('native Isaac evidence must be a regular file');
  return referenceFile(path);
}
declare module 'cordis' {interface Context {isaac:IsaacNative}}
/** Finite SDK episode; native world/physics/rendering stay entirely in the worker. */
export class IsaacNative extends Service {
  static inject=['jobs','runResources','isaacInputs'];
  readonly plan:Readonly<IsaacPlan>;
  private readonly token:string;
  private readonly compose:ComposeExecution;
  private engine:EngineMetadata|undefined;private containerId:string|undefined;
  private launchPromise:Promise<void>|undefined;private measurement:Promise<Record<string,unknown>>|undefined;
  private phase:'unstarted'|'paused'|'measuring'|'measured'|'released'='unstarted';
  private readonly refs:ArtifactRef[]=[];
  private cancelRequested=false;
  constructor(ctx:Context,config:{token:string}){
    super(ctx,'isaac');
    this.token=config.token;
    this.plan=ctx.isaacInputs.get(this.token,ctx.runResources.ownerId);
    const p=this.plan;
    this.compose=new ComposeExecution(ctx.jobs,{...p.compose,timeoutMs:p.deadlineMs,maxBufferBytes:1048576,
      env:{...p.compose.env,ROBOTICS_RUN_ID:p.runId,ROBOTICS_ISAAC_SCOPE:p.scope,
        ROBOTICS_ISAAC_PHASE_TOKEN:config.token,ROBOTICS_ISAAC_INPUT_VOLUME:p.inputVolume,
        ROBOTICS_ISAAC_RESULT_VOLUME:p.resultVolume,ROBOTICS_ISAAC_STEPS:String(p.steps),
        ROBOTICS_ISAAC_DT:String(p.dtSeconds),ROBOTICS_ISAAC_RENDER_FRAMES:String(p.renderFrames),
        ROBOTICS_ISAAC_WIDTH:String(p.width),ROBOTICS_ISAAC_HEIGHT:String(p.height),
        ROBOTICS_ISAAC_PHASE_TIMEOUT:String(p.deadlineMs/1000)}});
    // No resources exist before host admission succeeds; refusal performs no Jobs.
  }
  private async write(name:string,value:unknown):Promise<ArtifactRef>{
    const path=join(this.plan.outputDirectory,name);await writeFile(path,JSON.stringify(value),{flag:'wx'});
    const ref=await reference(path);this.refs.push(ref);return ref;
  }
  private signal(cancel:AbortSignal):AbortSignal{
    return AbortSignal.any([cancel,AbortSignal.timeout(this.plan.deadlineMs)]);
  }
  private async launch(signal:AbortSignal):Promise<void>{
    signal.throwIfAborted();const client=await observeIsaacClient();requireSupportedIsaacClient(client);
    for(const ref of [...this.plan.sourceRefs,...this.plan.sourceCheckerOutcome.evidenceRefs]){
      const actual=await reference(fileURLToPath(ref.uri));
      if(actual.sha256!==ref.sha256||actual.size_bytes!==ref.size_bytes)throw new Error('admitted source/checker bytes changed before native launch');
    }
    const deployment=await admitIsaacDeployment(client,{socketPath:this.plan.compose.socketPath,operationMinApi:'1.24',operationMaxApi:'1.53'},signal);
    this.engine=deployment.engine;
    signal.throwIfAborted();
    if(this.cancelRequested)throw new Error('finite Isaac episode cancelled before launch');
    await mkdir(this.plan.outputDirectory,{recursive:false,mode:0o770});
    await chmod(this.plan.outputDirectory,0o2770);
    if((await stat(this.plan.outputDirectory)).gid!==1000)throw new Error('SDK output directory requires the admitted shared GID 1000');
    await this.write('deployment-admission.json',{client,deployment:deployment.observed,sourceCheckerOutcome:this.plan.sourceCheckerOutcome,profile:'native-linux-nvidia',runtimeQualified:false});
    await this.compose.requireVersion(signal);
    this.ctx.runResources.track({id:this.plan.compose.projectName,ownerId:this.plan.runId,
      cleanup:async()=>{
        const errors:string[]=[];let admittedOwnership=false;
        try{
          const s=AbortSignal.timeout(this.plan.deadlineMs);
          const ownership=await this.engine!.projectOwnership({runId:this.plan.runId,projectName:this.plan.compose.projectName},{cancelSignal:s});
          await this.write('cleanup-preflight.json',ownership);
          if(ownership.status!=='complete')throw new Error('native Isaac cleanup ownership is incomplete');
          admittedOwnership=true;
          const candidates=ownership.containerDetails.filter(v=>record(record(record(v).Config).Labels)['com.docker.compose.service']==='isaac-native');
          if(candidates.length>1)throw new Error('native Isaac cleanup cannot identify a unique worker');
          if(candidates.length){
            const id=record(candidates[0]).Id;
            if(typeof id!=='string'||! /^[a-f0-9]{64}$/.test(id)||this.containerId&&this.containerId!==id)throw new Error('native Isaac cleanup worker identity differs');
            await this.marker('release');
            const waited=await this.compose.run(['wait','isaac-native'],s);
            await this.write('native-close-job.json',waited);
            if(!waited.ok||waited.stdout.trim()!=='0')errors.push('native graceful close job did not report success');
            const stopped=await this.engine!.inspect(id,{
              runId:this.plan.runId,projectName:this.plan.compose.projectName,imageDigest:ISAAC_IMAGE,
              mounts:[{destination:'/run/robotics/input',readOnly:true,volumeName:this.plan.inputVolume},{destination:'/run/robotics',readOnly:false,volumeName:this.plan.resultVolume}],
              hostConfig:{Init:true,ReadonlyRootfs:false,Runtime:'nvidia'},user:'1234:1234',
            },{cancelSignal:s});
            await this.write('native-closed-engine.json',stopped);
            const state=record(record(stopped.container).State);
            if(stopped.status!=='complete'||state.Running!==false||state.Status!=='exited'||state.ExitCode!==0)errors.push('actual successful native application shutdown is unconfirmed');
          }
        }catch(error){errors.push(error instanceof Error?error.message:String(error))}
        finally{
          if(admittedOwnership){
            try{
              // A cancelled/expired graceful wait must not cancel the separately bounded physical cleanup.
              const s=AbortSignal.timeout(this.plan.deadlineMs);
              const before=await this.engine!.projectOwnership({runId:this.plan.runId,projectName:this.plan.compose.projectName},{cancelSignal:s});
              await this.write('cleanup-final-preflight.json',before);
              if(before.status!=='complete')throw new Error('native Isaac cleanup ownership changed or is incomplete');
              const result=await this.compose.run(['down','--volumes','--remove-orphans','--timeout','5'],s);
              await this.write('cleanup-down-job.json',result);
              if(!result.ok)throw new Error(result.diagnostic??'owned Isaac cleanup failed');
              this.phase='released';
            }catch(error){errors.push(error instanceof Error?error.message:String(error))}
          }
        }
        if(errors.length)throw new Error(errors.join('; '));
      },
      verifyCleanup:async cancel=>{
        const observed=await this.engine!.projectOwnership({runId:this.plan.runId,projectName:this.plan.compose.projectName},{cancelSignal:this.signal(cancel)});
        const volumes=record(observed.inventory.volumes).Volumes;
        const released=observed.status==='complete'&&!observed.inventory.containers.length&&!observed.inventory.networks.length&&(volumes===null||Array.isArray(volumes)&&!volumes.length);
        const ref=await this.write('cleanup-native-inventory.json',{released,observed,retainedExternalVolume:this.plan.resultVolume});
        return {released,evidenceRefs:[ref]};
      }});
    const up=await this.compose.run(['up','--detach','isaac-native'],signal);
    await this.write('native-launch-job.json',up);
    if(!up.ok)throw new Error(up.diagnostic??'native Isaac worker launch failed');
    const ps=await this.compose.run(['ps','--all','--quiet','isaac-native'],signal);
    if(!ps.ok||!/^[a-f0-9]{64}$/.test(ps.stdout.trim()))throw new Error('exact native Isaac container ID unavailable');
    this.containerId=ps.stdout.trim();this.phase='paused';
    if(this.cancelRequested)await this.marker('cancel');
  }
  private async live(signal:AbortSignal):Promise<ArtifactRef>{
    if(!this.engine||!this.containerId)throw new Error('native Isaac worker has not launched');
    const observed=await this.engine.inspect(this.containerId,{
      runId:this.plan.runId,projectName:this.plan.compose.projectName,imageDigest:ISAAC_IMAGE,
      mounts:[{destination:'/run/robotics/input',readOnly:true,volumeName:this.plan.inputVolume},{destination:'/run/robotics',readOnly:false,volumeName:this.plan.resultVolume}],
      hostConfig:{Init:true,ReadonlyRootfs:false,Runtime:'nvidia'},user:'1234:1234',
    },{cancelSignal:signal});
    if(observed.status!=='complete'||record(record(observed.container).State).Running!==true)throw new Error('native Isaac worker is no longer live or Engine facts are incomplete');
    return this.write('engine-live-'+this.refs.length+'.json',observed);
  }
  private async fact(name:string,signal:AbortSignal):Promise<Record<string,unknown>>{
    for(;;){
      signal.throwIfAborted();
      try{
        const failure=join(this.plan.outputDirectory,'worker-error.json');
        try{
          const failureStat=await lstat(failure);
          if(!failureStat.isFile()||failureStat.size>1048576)throw new Error('native Isaac error fact exceeds its regular-file bound');
          const errorFacts=record(JSON.parse(await readFile(failure,'utf8')));
          if(errorFacts.owner_id!==this.plan.runId||errorFacts.phase_token!==this.token)throw new Error('native worker error belongs to another episode');
          throw new Error(String(errorFacts.diagnostic??'native Isaac workload failed'));
        }catch(error){if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error}
        const path=join(this.plan.outputDirectory,name);
        const facts=await lstat(path);if(!facts.isFile()||facts.size>1048576)throw new Error('native Isaac fact exceeds its regular-file bound');
        const value=record(JSON.parse(await readFile(path,'utf8')));
        if(value.owner_id!==this.plan.runId||value.phase_token!==this.token)throw new Error('native Isaac evidence belongs to another episode');
        return value;
      }catch(error){if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error}
      await pause(25,undefined,{signal});
    }
  }
  async ready(cancel:AbortSignal):Promise<{ready:boolean;evidenceRefs:ArtifactRef[]}>{
    const signal=this.signal(cancel);
    if(this.phase!=='unstarted'&&this.phase!=='paused')throw new Error('finite Isaac episode is outside its live ready phase');
    await(this.launchPromise??=this.launch(signal));
    const first=await this.fact('paused-state.json',signal);
    let current=first;
    while(current.observation===first.observation){await pause(25,undefined,{signal});current=await this.fact('paused-state.json',signal)}
    const ready=await this.fact('ready.json',signal);
    if(current.phase!=='ready'||current.application_running!==true||current.timeline_playing!==false||typeof current.simulation_time_seconds!=='number'||
      !Number.isFinite(current.simulation_time_seconds)||current.simulation_time_seconds!==ready.simulation_time_seconds||
      ready.runtime_version!=='6.1.0'||ready.scene_sha256!==ISAAC_SCENE_SHA256||ready.body_prim!=='/World/Body'||
      ready.scene_default_prim!=='/World'||ready.physics_device!=='cuda:0'||!Array.isArray(ready.body_position)||ready.body_position.length!==3||ready.body_position.some(v=>typeof v!=='number'||!Number.isFinite(v))||
      ready.bootstrap_sha256!==this.plan.sourceRefs.find(v=>v.uri.endsWith('/native-observe.py'))!.sha256)throw new Error('fresh native PAUSED world/body readiness is absent');
    await this.write('native-ready-observed-'+this.refs.length+'.json',{ready,current});
    await this.live(signal);
    return {ready:true,evidenceRefs:[...this.plan.sourceRefs,...this.plan.sourceCheckerOutcome.evidenceRefs,...this.refs]};
  }
  private async marker(action:'start'|'release'|'cancel'):Promise<void>{
    const path=join(this.plan.outputDirectory,action+'.json');
    const value={owner_id:this.plan.runId,phase_token:this.token,action};
    try{await writeFile(path,JSON.stringify(value),{flag:'wx'})}
    catch(error){
      if((error as NodeJS.ErrnoException).code!=='EEXIST')throw error;
      const facts=await lstat(path);
      if(!facts.isFile()||facts.size>4096||JSON.stringify(record(JSON.parse(await readFile(path,'utf8'))))!==JSON.stringify(value))throw new Error('private phase marker differs from its issued episode');
    }
  }
  async cancel():Promise<void>{
    if(this.phase==='released')return;
    this.cancelRequested=true;
    try{await this.marker('cancel')}catch(error){if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error}
  }
  async diagnosticEvidence(cancel:AbortSignal):Promise<ArtifactRef[]>{
    cancel.throwIfAborted();
    if(this.engine&&this.containerId){
      const log=await this.engine.readLogs(this.containerId,{runId:this.plan.runId,projectName:this.plan.compose.projectName},
        {tailLines:1000,maxBytes:1048576,deadlineMs:30000},cancel);
      const path=join(this.plan.outputDirectory,'diagnostic-native-log-'+this.refs.length+'.bin');
      await writeFile(path,log.bytes,{flag:'wx'});this.refs.push(await reference(path));
    }
    for(const name of ['ready.json','episode-result.json','worker-error.json']){
      try{this.refs.push(await reference(join(this.plan.outputDirectory,name)))}
      catch(error){if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error}
    }
    return [...this.plan.sourceRefs,...this.plan.sourceCheckerOutcome.evidenceRefs,...this.refs];
  }
  measure(cancel:AbortSignal):Promise<Record<string,unknown>>{
    return this.measurement??=this.observeEpisode(cancel);
  }
  private async observeEpisode(cancel:AbortSignal):Promise<Record<string,unknown>>{
    const signal=this.signal(cancel);await this.ready(signal);this.phase='measuring';await this.marker('start');
    const facts=await this.fact('episode-result.json',signal);
    if(facts.status!=='completed'||facts.application_running!==true||facts.timeline_playing_after_pause!==false||facts.requested_physics_steps!==this.plan.steps||
      facts.scene_sha256!==ISAAC_SCENE_SHA256||typeof facts.physics_advance_seconds!=='number'||!Number.isFinite(facts.physics_advance_seconds)||facts.physics_advance_seconds<=0)throw new Error('native finite episode did not complete PAUSED');
    await this.live(signal);this.phase='measured';return facts;
  }
  async exportEvidence(cancel:AbortSignal):Promise<ArtifactRef[]>{
    const signal=this.signal(cancel);
    if(this.phase!=='measured')throw new Error('completed native episode is required before export');
    const facts=await this.fact('episode-result.json',signal);await this.live(signal);
    const names=['ready.json','episode-result.json'];
    if(this.plan.renderFrames>0){
      if(!facts.native_capture)throw new Error('requested native capture is absent');
      names.push('capture/camera.rgba','capture/camera.png');
    }
    const output=await Promise.all(names.map(name=>reference(join(this.plan.outputDirectory,name))));
    return [...this.plan.sourceRefs,...this.plan.sourceCheckerOutcome.evidenceRefs,...this.refs,...output];
  }
}
export default IsaacNative;
