import assert from 'node:assert/strict';
import {writeFile, readFile} from 'node:fs/promises';
import {Context,Jobs,RunResources} from '@robotics-runtime/host';
import WebotsNative from '../dist/src/plugins/webots-provider/index.js';
const [root,socket,composeExecutable,image,volume]=process.argv.slice(2);
const runId='rr-c14-'+Date.now();
const ctx=new Context();
await ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:1048576});
await ctx.plugin(RunResources,runId);
const fiber=ctx.plugin(WebotsNative,{composeExecutable,socketPath:socket,
 composeFiles:[root+'/compose.webots.yaml',root+'/compose.webots.podman.yaml'],cwd:root,workerImage:image,runVolume:volume,
 outputRoot:'/run/robotics/output/webots',mode:'offscreen-camera',deadlineMs:120000});
await fiber.await();
const provider=ctx.webots;
const signal=AbortSignal.timeout(120000);
let ready;
try { ready=await provider.ready(signal); } catch(error) {await fiber.dispose(); await ctx.fiber.dispose(); throw error;}
assert.equal(ready.ready,true);
const result=await provider.measure(signal);assert.equal(result.status,'completed');
const native=JSON.parse(await readFile(provider.output+'/controller-result.json','utf8'));
assert.equal(native.world.random_seed,1);assert.equal(native.world.optimal_thread_count,1);
assert.ok(native.last_native_state.time_seconds>native.initial_state.time_seconds);
assert.ok(native.last_native_state.body_position_m[2]<native.initial_state.body_position_m[2]);
assert.equal(native.camera.format,'BGRA');assert.equal(native.camera.width,96);assert.equal(native.camera.height,64);
const refs=await provider.exportEvidence(signal);
const path='/run/robotics/output/c14-provider-qualification.json';
await writeFile(path,JSON.stringify({scope:'source native CPU/provider/Compose; no published consumer or hardware claim',
 runId,project:provider.project,output:provider.output,ready,native,result,exportedRefs:refs}));
await fiber.dispose();
const cleanup=await ctx.runResources.verify(30000);
assert.ok(cleanup.every(x=>x.attempted&&x.released&&!x.cleanupError),JSON.stringify(cleanup));
await writeFile('/run/robotics/output/c14-provider-cleanup.json',JSON.stringify(cleanup));
await ctx.fiber.dispose();
console.log(JSON.stringify({passed:true,runId,project:provider.project,output:provider.output,qualification:path,cleanup}));
