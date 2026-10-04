import {Context,Service} from '@robotics-runtime/host';
import type {ComposeOptions} from '../../compose-execution.js';
import type {ContainerRequirement} from '../../engine-metadata.js';

function freeze<T>(value:T):T {
  if(value!==null && typeof value==='object') {for(const child of Object.values(value)) freeze(child);Object.freeze(value)}
  return value;
}

/** Data admitted by the public Python/OPA/release workers; never Loader input. */
export interface LegacyRunInput {
  runId: string;
  compose: ComposeOptions;
  artifactDirectory: string;
  observationServices: readonly string[];
  simulationRequirement: ContainerRequirement;
  stepperRequirement: ContainerRequirement;
  admittedDescriptionPath?: string;
  entityWorkerPath: string;
  clockWorkerPath: string;
  readinessWorkerPath: string;
}
declare module 'cordis' { interface Context { legacyInputs: LegacyInputs; } }
export class LegacyInputs extends Service {
  private readonly runs = new Map<string,Readonly<LegacyRunInput>>();
  constructor(ctx:Context) {super(ctx,'legacyInputs')}
  issue(input:LegacyRunInput): void {
    if(this.runs.has(input.runId)) throw new Error('legacy run input already issued');
    if(input.runId!==input.simulationRequirement.runId || input.runId!==input.stepperRequirement.runId || input.compose.projectName!==input.simulationRequirement.projectName || input.compose.projectName!==input.stepperRequirement.projectName) throw new Error('admitted run/owner bindings disagree');
    const copy=structuredClone(input);
    this.runs.set(input.runId,freeze(copy));
  }
  get(runId:string): Readonly<LegacyRunInput> {
    const input=this.runs.get(runId);
    if(!input) throw new Error('run has no admitted legacy inputs');
    return input;
  }
  release(runId:string):void {this.runs.delete(runId)}
}
export default LegacyInputs;
