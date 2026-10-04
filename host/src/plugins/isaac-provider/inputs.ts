import {randomUUID} from 'node:crypto';
import {isAbsolute} from 'node:path';
import {Service} from '@robotics-runtime/host';
import type {ArtifactRef,Context} from '@robotics-runtime/host';
import type {ComposeOptions} from '../../compose-execution.js';

export const ISAAC_IMAGE='nvcr.io/nvidia/isaac-sim:6.1.0@sha256:0c16dd67d09a70ea474f2c809a13c4d09bd23c738184cf1bf28af487ecd39080';
export const ISAAC_SCENE_SHA256='0a19bca17a24a7d61bdef19dc410a220ef1ffe464f4e992a5c1cae7c52cbca29';
/** Root verification outcome; vendor evidence bytes are retained without inventing a report decoder. */
export interface SourceCheckerOutcome {status:'passed';evidenceRefs:readonly ArtifactRef[]}
export interface IsaacPlan {
  runId:string; compose:ComposeOptions; inputVolume:string; resultVolume:string;
  outputDirectory:string; scope:string; sourceRefs:readonly ArtifactRef[];
  sourceCheckerOutcome:SourceCheckerOutcome;
  steps:number; dtSeconds:number; renderFrames:number; width:number; height:number;
  deadlineMs:number;
}
const freeze=(value:unknown):void=>{
  if(!value||typeof value!=='object')return;
  for(const item of Object.values(value))freeze(item);Object.freeze(value);
};
/** Root-issued source/worker inventory. Loader receives only its owner-bound token. */
export class IsaacInputs extends Service {
  private readonly plans=new Map<string,Readonly<IsaacPlan>>();
  constructor(ctx:Context){super(ctx,'isaacInputs')}
  issue(plan:IsaacPlan):string {
    if(!/^[a-zA-Z0-9_.:-]{1,128}$/.test(plan.runId)||!/^[a-f0-9]{24}$/.test(plan.scope))throw new Error('unique Isaac owner and scope required');
    if(![plan.outputDirectory,plan.compose.executable,plan.compose.socketPath,plan.compose.cwd,...plan.compose.files].every(isAbsolute)||!plan.compose.files.length)throw new Error('absolute source profile paths required');
    if(!plan.outputDirectory.endsWith('/output/isaac/'+plan.scope))throw new Error('output directory must map to the selected worker scope');
    if(!Number.isSafeInteger(plan.deadlineMs)||plan.deadlineMs<1000||plan.deadlineMs>300000)throw new Error('invalid finite Isaac deadline');
    if(!Number.isSafeInteger(plan.steps)||plan.steps<1||plan.steps>10000||!Number.isFinite(plan.dtSeconds)||plan.dtSeconds<=0||plan.dtSeconds>1)throw new Error('invalid finite native physics workload');
    if(!Number.isSafeInteger(plan.renderFrames)||plan.renderFrames<0||plan.renderFrames>10000||![plan.width,plan.height].every(v=>Number.isSafeInteger(v)&&v>=1&&v<=4096))throw new Error('invalid finite native capture workload');
    if(![plan.inputVolume,plan.resultVolume].every(v=>/^[a-zA-Z0-9][a-zA-Z0-9_.-]+$/.test(v))||plan.inputVolume===plan.resultVolume)throw new Error('distinct external input/result volumes required');
    if(!plan.sourceRefs.some(v=>v.uri.endsWith('/native-observe.py'))||!plan.sourceRefs.some(v=>v.uri.endsWith('/fixture.usda')&&v.sha256===ISAAC_SCENE_SHA256))throw new Error('source inventory and pinned fixture required');
    if(plan.sourceCheckerOutcome?.status!=='passed'||!Array.isArray(plan.sourceCheckerOutcome.evidenceRefs)||!plan.sourceCheckerOutcome.evidenceRefs.length)throw new Error('explicit successful root checker outcome and retained evidence required');
    if([...plan.sourceRefs,...plan.sourceCheckerOutcome.evidenceRefs].some(ref=>!ref.uri.startsWith('file:')||!/^[a-f0-9]{64}$/.test(ref.sha256)||!Number.isSafeInteger(ref.size_bytes)||ref.size_bytes<1))throw new Error('retained local source/checker references required');
    if([...this.plans.values()].some(v=>v.runId===plan.runId||v.scope===plan.scope||v.outputDirectory===plan.outputDirectory||v.compose.projectName===plan.compose.projectName))throw new Error('Isaac owner/output/project already issued');
    const copy=structuredClone(plan);freeze(copy);const token=randomUUID();this.plans.set(token,copy);return token;
  }
  get(token:string,runId:string):Readonly<IsaacPlan>{
    const plan=this.plans.get(token);
    if(!plan||plan.runId!==runId)throw new Error('Isaac plan is not issued to this owner');
    return plan;
  }
}
declare module 'cordis' {interface Context {isaacInputs:IsaacInputs}}
export default IsaacInputs;
