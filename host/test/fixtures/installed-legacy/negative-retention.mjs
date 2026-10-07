import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {referenceFile} from '@robotics-runtime/host';
const [root]=process.argv.slice(2);assert.match(root,/^\/retained\/startup-run-[a-f0-9-]{36}$/);
const completion=JSON.parse(await readFile(root+'/completion.json','utf8'));
const report=JSON.parse(await readFile(root+'/negative-report.json','utf8'));
assert.equal(report.status,'passed');assert.notEqual(completion.status,'passed');
if(['cancel','timeout'].includes(report.mode)){assert.equal(report.readyObserved,true);assert.equal(report.measurementOpened,true);assert.equal(report.noSuccessfulMeasurement,true);assert.ok(completion.phases.some(row=>row.phase==='closing-measurement'&&row.status==='error'))}
else{assert.equal(report.noReadyOrMeasurement,true);assert.ok(!completion.phases.some(row=>['ready','measuring'].includes(row.phase)))}
const refs=new Map(completion.evidenceRefs.map(ref=>[ref.uri,ref]));
for(const outcome of completion.resourceOutcomes)for(const ref of outcome.evidenceRefs)refs.set(ref.uri,ref);
assert.ok(refs.size>0);
for(const ref of refs.values()){const path=fileURLToPath(ref.uri);assert.ok(path.startsWith('/retained/'));assert.deepEqual(await referenceFile(path),ref)}
console.log(JSON.stringify({status:'passed',runId:completion.runId,uniqueReferences:refs.size,allHashesAndSizesVerified:true,sourceMounted:false,scope:'retained-only installed negative lifecycle evidence'}));
