import assert from 'node:assert/strict';
import Docker from 'dockerode';
import {Readable,Writable} from 'node:stream';
import {finished} from 'node:stream/promises';
import {writeFile,mkdir} from 'node:fs/promises';
import {Context,Jobs} from '@robotics-runtime/host';
import {ComposeExecution,EngineMetadata} from '../dist/src/index.js';
const [root,socket,executable,image,volume,output]=process.argv.slice(2);
const ctx=new Context();
const jobs=ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:1048576});await jobs.await();
const runId='rr-finalization-'+Date.now();
const projectName=runId;
const compose=new ComposeExecution(ctx.jobs,{executable,socketPath:socket,projectName,cwd:root,
 files:[root+'/compose.legacy-retained.yaml',root+'/compose.legacy-finalization.podman.yaml',root+'/host/test/fixtures/legacy-finalization/qualification.yaml'],
 env:{LEGACY_FINALIZER_IMAGE:image,ROBOTICS_RUN_ID:runId,ROBOTICS_RETAINED_VOLUME:volume,LEGACY_SOURCE_ROOT:root}});
await mkdir(output,{recursive:true});
let passed=false;
try{
 await compose.requireVersion();
 const launch=await compose.run(['run','--detach','--no-deps','legacy-coordinator','/opt/contracts/bin/python','/source/host/tools/qualify-finalization-workers.py']);
 await writeFile(output+'/launch.json',JSON.stringify(launch,null,2));
 assert.equal(launch.ok,true,launch.diagnostic);
 const id=launch.stdout.trim();assert.match(id,/^[a-f0-9]{64}$/);
 const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
 const required={runId,projectName,user:'1000:1000',imageDigest:image,
   mounts:[{destination:'/retained',readOnly:false,volumeName:volume}],
   hostConfig:{Init:true,ReadonlyRootfs:true,NetworkMode:'none',Memory:536870912}};
 const actual=await engine.inspect(id,required);
 await writeFile(output+'/metadata.json',JSON.stringify(actual,null,2));
 assert.equal(actual.status,'complete',JSON.stringify(actual));
 const deadline=performance.now()+120000;
 let last=actual;
 while(last.container.State.Running){
   assert.ok(performance.now()<deadline,'finite coordinator did not finish');
   await new Promise(resolve=>setTimeout(resolve,100));
   last=await engine.inspect(id,required);
 }
 await writeFile(output+'/final-state.json',JSON.stringify(last,null,2));
 assert.equal(last.status,'complete');assert.equal(last.container.State.ExitCode,0);
 const limits={tailLines:1000,maxBytes:1048576,deadlineMs:15000};
 const logs=await engine.readLogs(id,{runId,projectName},limits);
 await writeFile(output+'/container-logs.raw',logs.bytes);
 await writeFile(output+'/log-transport.json',JSON.stringify({containerId:logs.containerId,clientApi:logs.clientApi,tty:logs.tty,sizeBytes:logs.bytes.length},null,2));
 await assert.rejects(engine.readLogs(id,{runId:'foreign-owner',projectName},limits),/foreign container ownership/);
 await assert.rejects(engine.readLogs(id,{runId,projectName:'foreign-project'},limits),/foreign container ownership/);
 await assert.rejects(engine.readLogs(id,{runId,projectName},{...limits,maxBytes:1}),/byte bound/);
 const mutableLimits={...limits,maxBytes:1};
 const bounded=engine.readLogs(id,{runId,projectName},mutableLimits);mutableLimits.maxBytes=16777216;
 await assert.rejects(bounded,/byte bound/);
 const mutableOwner={runId:'foreign-owner',projectName};
 const refused=engine.readLogs(id,mutableOwner,limits);mutableOwner.runId=runId;
 await assert.rejects(refused,/foreign container ownership/);
 await assert.rejects(engine.readLogs(id,{runId,projectName},{...limits,deadlineMs:0}),/finite native log bounds/);
 await assert.rejects(engine.readLogs(id,{runId,projectName},{...limits,deadlineMs:1}));
 await assert.rejects(engine.readLogs('0'.repeat(64),{runId,projectName},limits));
 const canceled=new AbortController();canceled.abort(new Error('qualification cancellation'));
 await assert.rejects(engine.readLogs(id,{runId,projectName},limits,canceled.signal),/qualification cancellation/);
 // Keep raw native transport bytes; use only the pinned SDK's framing decoder.
 const parts=[];const capture=()=>new Writable({write(chunk,_encoding,callback){parts.push(Buffer.from(chunk));callback()}});
 const source=Readable.from([logs.bytes]);
 if(logs.tty) source.on('data',chunk=>parts.push(Buffer.from(chunk)));
 else new Docker({socketPath:socket,version:'v'+engine.facts.clientApi}).modem.demuxStream(source,capture(),capture());
 await finished(source);
 const text=Buffer.concat(parts).toString('utf8');
 await writeFile(output+'/container-logs.txt',text);
 assert.match(text,/Ran 6 tests/);assert.match(text,/OK/);
 await writeFile(output+'/log-negative-checks.json',JSON.stringify({foreignRunRefused:true,foreignProjectRefused:true,mutatedOwnerRefused:true,mutatedByteCapEnforced:true,byteBound:true,invalidDeadline:true,nativeDeadline:true,removedIdRefused:true,canceledReadRefused:true}));
 passed=true;
}finally{
 const cleanup=await compose.run(['down','--remove-orphans']);
 const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
 const remaining=await engine.remainingOwned(runId);
 await writeFile(output+'/cleanup.json',JSON.stringify({cleanup,remaining},null,2));
 assert.ok(cleanup.ok&&remaining.containers.length===0&&remaining.networks.length===0,'finite project cleanup incomplete');
 await jobs.dispose();await ctx.fiber.dispose();
}
console.log(JSON.stringify({passed,runId,scope:'repository-fixture native public workers and retained-only Compose; live measurement gate is separate'}));
