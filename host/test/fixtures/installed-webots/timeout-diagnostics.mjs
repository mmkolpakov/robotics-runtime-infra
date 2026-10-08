import assert from 'node:assert/strict';
import {readFile,stat} from 'node:fs/promises';
import {join} from 'node:path';
import {referenceFile} from '@robotics-runtime/host';

const optionalJson=async path=>{
 try{return {available:true,value:JSON.parse(await readFile(path,'utf8'))}}
 catch(error){if(error.code!=='ENOENT')throw error;return {available:false}}
};
const absent=async path=>{
 try{await stat(path)}catch(error){if(error.code!=='ENOENT')throw error;return}
 assert.fail('native measurement gate/payload must remain absent: '+path);
};

// Only the expected natural-deadline case can retain incomplete native payloads.
export async function readNativeTimeoutDiagnostics(output,ownerId){
 const worker=JSON.parse(await readFile(join(output,'worker-result.json'),'utf8'));
 assert.equal(worker.owner_id,ownerId);
 assert.equal(worker.status,'canceled');
 assert.match(worker.diagnostic,/deadline/);
 const marker=await readFile(join(output,'cancel'),'utf8');
 assert.equal(marker,'worker deadline','an owned cancel is not the natural deadline case');
 await absent(join(output,'measure'));await absent(join(output,'measurement.json'));
 assert.equal(typeof worker.evidence_exported_before_stop,'boolean');
 assert.equal(worker.processes_reaped,true);
 assert.ok(Array.isArray(worker.children));
 assert.deepEqual(worker.children.map(row=>row.name).sort(),['controller','webots','xvfb']);
 for(const child of worker.children){
  assert.equal(child.reaped,true);assert.equal(child.group_absent,true);
  assert.ok(Number.isSafeInteger(child.registered_pgid)&&child.registered_pgid>0);
  assert.equal(child.pid,child.registered_pgid);assert.ok(Number.isInteger(child.exit_code));
 }
 const controller=await optionalJson(join(output,'controller-result.json'));
 if(controller.available){
  assert.equal(controller.value?.owner_id,ownerId);
  assert.ok(['canceled','error'].includes(controller.value.status));
  assert.ok(Array.isArray(controller.value.samples));assert.equal(controller.value.samples.length,0);
 }
 if(worker.evidence_exported_before_stop||worker.controller_result_ref){
  assert.equal(controller.available,true,'claimed controller export requires actual bytes');
  const actual=await referenceFile(join(output,'controller-result.json'));
  assert.equal(worker.controller_result_ref?.sha256,actual.sha256);
  assert.equal(worker.controller_result_ref?.size_bytes,actual.size_bytes);
 }
 const lastState=await optionalJson(join(output,'last-native-state.json'));
 if(lastState.available){
  const value=lastState.value;
  assert.ok(Number.isFinite(value?.time_seconds)&&value.time_seconds>=0);
  assert.ok(Array.isArray(value.body_position_m)&&value.body_position_m.length===3&&value.body_position_m.every(Number.isFinite));
  if(controller.available)assert.deepEqual(value,controller.value.last_native_state);
 }
 return {worker,marker,controller,lastState,measureGateUnopened:true,measurementAvailable:false};
}
