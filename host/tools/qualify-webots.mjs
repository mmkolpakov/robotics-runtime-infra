import assert from 'node:assert/strict';
import {writeFile, readFile, mkdir} from 'node:fs/promises';
import {Context,Jobs,RunResources} from '@robotics-runtime/host';
import {randomUUID} from 'node:crypto';
import {isAbsolute} from 'node:path';
import WebotsNative from '../dist/src/plugins/webots-provider/index.js';
const [root,socket,composeExecutable,image,volume,prefix='webots-physics',documentPython]=process.argv.slice(2);
assert.match(prefix,/^[a-z0-9][a-z0-9-]*$/);
assert.ok(isAbsolute(documentPython??''),'explicit published SDK Python interpreter required');
const runId='run-'+randomUUID();
const pins=JSON.parse(await readFile(root+'/workers/webots/upstream.json','utf8')).model_inputs;
const archive='/run/robotics/output/'+prefix+'-v2';
await mkdir(archive,{recursive:false,mode:0o700});
const ctx=new Context();
await ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:1048576});
await ctx.plugin(RunResources,runId);
let fiber;let firstError;
try {
fiber=ctx.plugin(WebotsNative,{composeExecutable,socketPath:socket,
 composeFiles:[root+'/compose.webots.yaml',root+'/compose.webots.podman.yaml'],cwd:root,workerImage:image,runVolume:volume,
 outputRoot:'/run/robotics/output/webots',artifactDirectory:archive+'/capture',mode:'physics-only',
 worldSha256:pins.world.sha256,protoSha256:pins.proto.sha256,deadlineMs:120000});
await fiber.await();
const provider=ctx.webots;
const documents=async(operation,args)=>{
 const result=await ctx.jobs.run({executable:documentPython,args:['-m','host.producers.webots_native',operation,...args],cwd:root,extendEnv:false,env:{PATH:'/usr/bin:/bin'}});
 await writeFile(archive+'/document-'+operation+'-job.json',JSON.stringify(result,null,2));
 assert.equal(result.ok,true,result.stderr);return JSON.parse(result.stdout);
};
const issued=Object.freeze(await documents('prepare',['--assets',root+'/workers/webots','--output',archive+'/inputs','--owner-id',runId,'--worker-image',image,'--project',provider.project]));
const inputManifest=Object.freeze({...issued.input_manifest});
const signal=AbortSignal.timeout(120000);
let ready;
ready=await provider.ready(signal);
assert.equal(ready.ready,true);
const result=await provider.measure(signal);assert.equal(result.status,'completed');
const native=JSON.parse(await readFile(provider.output+'/controller-result.json','utf8'));
assert.equal(native.world.random_seed,1);assert.equal(native.world.optimal_thread_count,1);
assert.ok(native.last_native_state.time_seconds>native.initial_state.time_seconds);
assert.ok(native.last_native_state.body_position_m[2]<native.initial_state.body_position_m[2]);
assert.equal(native.camera.sampling_period_ms,0);
const refs=await provider.exportEvidence(signal);
const engine=JSON.parse(await readFile(provider.output+'/engine-readiness.json','utf8'));
assert.equal(engine.container.HostConfig.Init,true);
const init=JSON.parse(await readFile(provider.output+'/oci-init.json','utf8'));
assert.equal(init.pid,1);assert.equal(init.sha256,'43e9b836ca7631672f12d0610cd574875b62d236dfd62e3b86751f35862e5eba');
assert.ok(result.children.every(child=>child.group_absent&&child.reaped));
const path='/run/robotics/output/'+prefix+'-qualification.json';
await writeFile(path,JSON.stringify({scope:'source native CPU/provider/Compose; no published consumer or hardware claim',
 runId,project:provider.project,output:provider.output,ready,native,result,ociInit:init,engine,exportedRefs:refs}));
await fiber.dispose();
const cleanup=await ctx.runResources.verify(30000);
assert.ok(cleanup.length>0&&cleanup.some(x=>x.id===provider.project&&x.ownerId===runId), 'expected provider cleanup proof is required');
assert.ok(cleanup.every(x=>x.attempted&&x.released&&!x.cleanupError),JSON.stringify(cleanup));
await writeFile('/run/robotics/output/'+prefix+'-cleanup.json',JSON.stringify(cleanup));
const publicInputs=await documents('complete',['--prepared',archive+'/inputs','--capture',provider.retainedOutput,'--cleanup',provider.retainedOutput+'/engine-cleanup.json','--input-manifest-sha256',inputManifest.sha256,'--input-manifest-size',String(inputManifest.size_bytes)]);
await ctx.fiber.dispose();
console.log(JSON.stringify({providerSourceQualificationPassed:true,runId,project:provider.project,output:provider.output,qualification:path,cleanup,publicInputs,documentScope:'physics-only native v2 inputs; evaluator verdict remains independent'}));

} catch(error) {firstError=error;throw error;}
finally {
 try {await fiber?.dispose();await ctx.fiber.dispose();}
 catch(error) {await writeFile(archive+'/dispose-diagnostic.json',JSON.stringify({diagnostic:String(error),scope:'passive/native child settlement; native stop not asserted'}));if(!firstError)throw error;}
}
