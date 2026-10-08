import {test} from 'node:test';
import assert from 'node:assert/strict';
import {Context} from '@robotics-runtime/host';
import Inputs from '../src/plugins/legacy-finalization/inputs.js';
import type {LegacyFinalizationPlan} from '../src/plugins/legacy-finalization/inputs.js';

const plan=():LegacyFinalizationPlan=>({
 runId:'fixture-owner',compose:{executable:'/tools/compose',socketPath:'/tools/socket',projectName:'fixture-source',files:['/source/model.yaml'],cwd:'/source'},
 postprocessCompose:{executable:'/tools/compose',socketPath:'/tools/socket',projectName:'fixture-post',files:['/source/post.yaml'],cwd:'/source'},
 artifactDirectory:'/retained/control/phase',retainedDirectory:'/retained/attempt-0',measurementCompletePath:'/run/robotics/measurement-complete',
 startupRefs:[{uri:'file:///retained/ready.json',sha256:'a'.repeat(64),size_bytes:1}],requirements:{},sourceContainerId:'b'.repeat(64),
 observerService:'observer',instrumentServices:['metrics'],recorderServices:['recorder'],collectorService:'collector',stepperService:'stepper',simulationService:'simulation',coordinatorService:'legacy-coordinator',
 lastStateWorkerPath:'/input/last-state.py',exportWorkerPath:'/workers/export_retained.py',inventoryWorkerPath:'/workers/collect_inventory.py',
 inventoryPlanPath:'/retained/control/0/input.json',exportPlanPath:'/retained/control/0/export.json',
 qualificationInputsWorkerPath:'/retained/control/0/args.json',qualificationInputsHostPath:'/retained/control/0/args.json',
 helperRoot:'/opt/robotics/finalizer',retainedWorkerRoot:'/retained/attempt-0',contractPythonPath:'/opt/contracts/bin/python',
 scenarioPath:'/retained/attempt-0/scenario.yaml',runContextPath:'/retained/attempt-0/run.json',resultPath:'/retained/attempt-0/result.json',aggregatePath:'/retained/attempt-0/acceptance-aggregate.json',
 evidenceRoot:'/evidence',foundationLogPath:'/retained/control/foundation.log',observerLogPath:'/retained/control/observer.log',timeoutMs:30000,
});
test('retry tokens keep the original issuer snapshot and refuse foreign/reused attempts',async()=>{
 const ctx=new Context();const fiber=ctx.plugin(Inputs);await fiber.await();
 const input=ctx.get('legacyFinalizationInputs');assert.ok(input);
 const base=plan();input.issue(base);
 base.instrumentServices=['mutated'];
 const attempt={runId:base.runId,inventoryPlanPath:'/retained/control/1/input.json',exportPlanPath:'/retained/control/1/export.json',
  qualificationInputsWorkerPath:'/retained/control/1/args.json',qualificationInputsHostPath:'/retained/control/1/args.json',retainedDirectory:'/retained/attempt-1'};
 const token=input.issueExportAttempt(attempt);attempt.retainedDirectory='/changed';
 assert.equal(input.getExportAttempt(base.runId,token).retainedDirectory,'/retained/attempt-1');
 assert.equal(input.get(base.runId).retainedDirectory,'/retained/attempt-0');
 assert.deepEqual(input.get(base.runId).instrumentServices,['metrics']);
 assert.throws(()=>input.getExportAttempt('foreign-owner',token),/not issued to this owner/);
 assert.throws(()=>input.issueExportAttempt({...attempt,retainedDirectory:'/retained/attempt-0'}),/new control\/output paths/);
 assert.throws(()=>input.issueExportAttempt({...attempt,retainedDirectory:'/retained/attempt-1'}),/already issued/);
 input.release(base.runId);assert.throws(()=>input.getExportAttempt(base.runId,token),/not issued to this owner/);
 await fiber.dispose();await ctx.fiber.dispose();
});
