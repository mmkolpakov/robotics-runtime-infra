import {randomUUID} from 'node:crypto';
import {isAbsolute} from 'node:path';
import {Context,Service} from '@robotics-runtime/host';
import type {ArtifactRef} from '@robotics-runtime/host';
import type {ContainerRequirement} from '../../engine-metadata.js';
import type {ComposeOptions} from '../../compose-execution.js';

export interface LegacyFinalizationPlan {
  runId:string;
  compose:ComposeOptions;
  postprocessCompose:ComposeOptions;
  artifactDirectory:string;
  retainedDirectory:string;
  measurementCompletePath:string;
  startupRefs:readonly ArtifactRef[];
  requirements:Readonly<Record<string,ContainerRequirement>>;
  sourceContainerId:string;
  observerService:string;
  instrumentServices:readonly string[];
  recorderServices:readonly string[];
  collectorService:string;
  stepperService:string;
  simulationService:string;
  coordinatorService:string;
  exportCoordinatorService?:string;
  lastStateWorkerPath:string;
  exportWorkerPath:string;
  inventoryWorkerPath:string;
  inventoryPlanPath:string;
  qualificationInputsWorkerPath:string;
  qualificationInputsHostPath:string;
  helperRoot:string;
  retainedWorkerRoot:string;
  exportPlanPath:string;
  contractPythonPath:string;
  scenarioPath:string;
  runContextPath:string;
  resultPath:string;
  aggregatePath:string;
  evidenceRoot:string;
  foundationLogPath:string;
  observerLogPath:string;
  timeoutMs:number;
}
export interface LegacyExportAttempt {
  runId:string;inventoryPlanPath:string;exportPlanPath:string;
  qualificationInputsWorkerPath:string;qualificationInputsHostPath:string;retainedDirectory:string;
}
const freeze=(value:unknown,seen=new WeakSet<object>()):void=>{
  if(!value||typeof value!=='object'||seen.has(value)) return;
  seen.add(value);for(const item of Object.values(value)) freeze(item,seen);Object.freeze(value);
};
/** Issued by the root program after admission, never deserialized by Loader. */
export class LegacyFinalizationInputs extends Service {
  private readonly attempts=new Map<string,Readonly<LegacyExportAttempt>>();
  private readonly plans=new Map<string,Readonly<LegacyFinalizationPlan>>();
  constructor(ctx:Context){super(ctx,'legacyFinalizationInputs')}
  issue(plan:LegacyFinalizationPlan):void {
    if(this.plans.has(plan.runId)||!plan.startupRefs.length) throw new Error('finalization needs unique run ownership and native readiness facts');
    if(!Number.isSafeInteger(plan.timeoutMs)||plan.timeoutMs<=0||plan.timeoutMs>300000) throw new Error('invalid finite finalization deadline');
    if(!/^[a-f0-9]{64}$/.test(plan.sourceContainerId)) throw new Error('exact native measurement source required');
    if(Object.values(plan.requirements).some(r=>r.runId!==plan.runId||r.projectName!==plan.compose.projectName)) throw new Error('native requirements do not belong to the acquired run');
    if(plan.compose.projectName===plan.postprocessCompose.projectName) throw new Error('postprocessing requires a distinct retained-only project');
    const copy=structuredClone(plan);
    freeze(copy);
    this.plans.set(copy.runId,Object.freeze(copy));
  }
  get(runId:string):Readonly<LegacyFinalizationPlan>{
    const plan=this.plans.get(runId);
    if(!plan) throw new Error('no admitted finalization plan for owner');
    return plan;
  }
  issueExportAttempt(attempt:LegacyExportAttempt):string {
    const base=this.get(attempt.runId);
    if(![attempt.inventoryPlanPath,attempt.exportPlanPath,attempt.qualificationInputsWorkerPath,attempt.qualificationInputsHostPath,attempt.retainedDirectory].every(isAbsolute)) throw new Error('retry attempt paths must be absolute');
    if(attempt.retainedDirectory===base.retainedDirectory||attempt.exportPlanPath===base.exportPlanPath||attempt.qualificationInputsWorkerPath===base.qualificationInputsWorkerPath) throw new Error('retry must acquire new control/output paths');
    if([...this.attempts.values()].some(a=>a.retainedDirectory===attempt.retainedDirectory||a.exportPlanPath===attempt.exportPlanPath)) throw new Error('export attempt output already issued');
    const copy=structuredClone(attempt);freeze(copy);
    const token=randomUUID();this.attempts.set(token,copy);return token;
  }
  getExportAttempt(runId:string,token:string):Readonly<LegacyExportAttempt>{
    const attempt=this.attempts.get(token);
    if(!attempt||attempt.runId!==runId) throw new Error('export attempt is not issued to this owner');
    return attempt;
  }
  release(runId:string):void {
    this.plans.delete(runId);
    for(const [token,attempt] of this.attempts) if(attempt.runId===runId) this.attempts.delete(token);
  }
}
declare module 'cordis' {interface Context {legacyFinalizationInputs:LegacyFinalizationInputs;}}
export default LegacyFinalizationInputs;
