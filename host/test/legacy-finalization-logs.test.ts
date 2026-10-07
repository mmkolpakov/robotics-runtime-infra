import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createServer} from 'node:http';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Context,Jobs,RunResources,referenceFile} from '@robotics-runtime/host';
import Finalization from '../src/plugins/legacy-finalization/index.js';
import Inputs from '../src/plugins/legacy-finalization/inputs.js';
import type {LegacyFinalizationPlan} from '../src/plugins/legacy-finalization/inputs.js';

test('a stopped nonzero observer retains its real SDK log bytes and original verification refusal',async t=>{
 for(const logStatus of [200,500]){
  const root=await mkdtemp(join(tmpdir(),'rr-observer-refusal-')),ctx=new Context();
  const socketPath=join(root,'engine.sock'),resultPath=join(root,'observer-result.json');
  const effects=join(root,'effects.jsonl'),observerId='b'.repeat(64),sourceId='a'.repeat(64),imageId='sha256:'+'c'.repeat(64);
  const ids={simulation:sourceId,observer:observerId,collector:'d'.repeat(64),recorder:'e'.repeat(64)};
  const requests:string[]=[];
  const api=createServer(async(request,response)=>{
   const path=request.url!;requests.push(path);
   if(path.includes('/logs?')){
    response.writeHead(logStatus,{'content-type':logStatus===200?'application/vnd.docker.raw-stream':'application/json'});
    if(logStatus!==200){response.end(JSON.stringify({message:'original native log HTTP failure'}));return}
    const actual=JSON.parse(await readFile(resultPath,'utf8')) as {stdout:string;exitCode:number};
    const payload=Buffer.from(actual.stdout),header=Buffer.alloc(8);header[0]=1;header.writeUInt32BE(payload.length,4);
    response.end(Buffer.concat([header,payload]));return;
   }
   let value:unknown;
   if(path==='/version')value={ApiVersion:'1.41',MinAPIVersion:'1.24'};
   else if(path.startsWith('/v1.41/images/'))value={Id:imageId};
   else {
    const id=Object.values(ids).find(value=>path==='/v1.41/containers/'+value+'/json');
    if(id){
     const actual=id===observerId?JSON.parse(await readFile(resultPath,'utf8')) as {exitCode:number}:undefined;
     const running=id===sourceId;
     value={Id:id,Image:imageId,Config:{User:'1000:1000',Tty:false,Labels:{'org.robotics.runtime.run-id':'run1','com.docker.compose.project':'owned-1'}},
      State:{Status:running?'running':'exited',Running:running,ExitCode:actual?.exitCode??0},Mounts:[],HostConfig:{NetworkMode:'none'},NetworkSettings:{Networks:{}}};
    }
   }
   response.setHeader('content-type','application/json');
   if(value===undefined){response.statusCode=404;value={message:'absent native fixture metadata'}}
   response.end(JSON.stringify(value));
  });
  await new Promise<void>(resolve=>api.listen(socketPath,resolve));
  t.after(async()=>{await ctx.fiber.dispose();api.closeAllConnections();await new Promise<void>((resolve,reject)=>api.close(error=>error?reject(error):resolve()));await rm(root,{recursive:true,force:true})});
  const executable=join(root,'compose.mjs'),foundation='actual finite Compose diagnostic output';
  await writeFile(executable,'#!'+process.execPath+'\n'+
   'import {appendFileSync,writeFileSync} from "node:fs";import {spawnSync} from "node:child_process";\n'+
   'const args=process.argv.slice(2);appendFileSync('+JSON.stringify(effects)+',JSON.stringify(args)+"\\n");\n'+
   'if(args.includes("version"))console.log("5.3.1");\n'+
   'else if(args.includes("ps"))console.log('+JSON.stringify(ids)+'[args.at(-1)]);\n'+
   'else if(args.includes("run")&&args.includes("observer")){const actual=spawnSync(process.execPath,["-e","process.stdout.write(\\"real stopped verifier refusal\\\\n\\");process.exitCode=7"],{encoding:"utf8"});writeFileSync('+JSON.stringify(resultPath)+',JSON.stringify({exitCode:actual.status,stdout:actual.stdout}));console.log('+JSON.stringify(observerId)+')}\n'+
   'else if(args.includes("logs"))process.stdout.write('+JSON.stringify(foundation)+');\n',
   {mode:0o700});
  await ctx.plugin(Jobs,{timeoutMs:3000,maxBufferBytes:1048576}).await();
  const readiness=join(root,'ready.json');await writeFile(readiness,'{"ready":true}\n');
  const requirement={runId:'run1',projectName:'owned-1',imageId,user:'1000:1000',mounts:[],hostConfig:{}};
  const options={executable,socketPath,projectName:'owned-1',files:[join(root,'compose.yaml')],cwd:root,timeoutMs:2000};
  const plan:LegacyFinalizationPlan={runId:'run1',compose:options,postprocessCompose:{...options,projectName:'owned-post'},
   artifactDirectory:join(root,'phases'),retainedDirectory:join(root,'retained'),measurementCompletePath:join(root,'complete'),
   startupRefs:[await referenceFile(readiness)],requirements:Object.fromEntries(Object.keys(ids).map(service=>[service,requirement])),sourceContainerId:sourceId,
   observerService:'observer',instrumentServices:[],recorderServices:['recorder'],collectorService:'collector',stepperService:'stepper',simulationService:'simulation',coordinatorService:'coordinator',
   lastStateWorkerPath:join(root,'last.py'),exportWorkerPath:join(root,'export.py'),inventoryWorkerPath:join(root,'inventory.py'),inventoryPlanPath:join(root,'inventory.json'),
   exportPlanPath:join(root,'export.json'),qualificationInputsWorkerPath:join(root,'args.json'),qualificationInputsHostPath:join(root,'args.json'),
   helperRoot:root,retainedWorkerRoot:root,contractPythonPath:'/opt/contracts/bin/python',scenarioPath:join(root,'scenario.json'),runContextPath:join(root,'run.json'),
   resultPath:join(root,'result.json'),aggregatePath:join(root,'aggregate.json'),evidenceRoot:join(root,'evidence'),foundationLogPath:join(root,'logs','foundation.log'),observerLogPath:join(root,'logs','observer.log'),timeoutMs:2000};
  let provider!:Finalization;
  await ctx.plugin(async scope=>{await scope.plugin(RunResources,'run1').await();await scope.plugin(Inputs).await();scope.get('legacyFinalizationInputs')!.issue(plan);await scope.plugin(Finalization).await();provider=scope.get('legacyFinalization')!}).await();
  await provider.beginMeasurement(AbortSignal.timeout(3000));
  const actual=JSON.parse(await readFile(resultPath,'utf8')) as {exitCode:number;stdout:string};assert.equal(actual.exitCode,7);
  await assert.rejects(provider.hooks.drainRecorders!(AbortSignal.timeout(3000)),(error:unknown)=>{
   assert.ok(error instanceof Error);assert.match(error.message,/public live observer verification failed/);
   if(logStatus!==200){assert.ok(error instanceof AggregateError);assert.match(error.message,/Engine evidence read failed/);assert.match(String(error.errors[1]),/Engine evidence read failed/)}
   return true;
  });
  assert.equal(await readFile(plan.foundationLogPath,'utf8'),foundation);
  assert.ok(requests.some(path=>path==='/v1.41/containers/'+observerId+'/logs?stdout=true&stderr=true&follow=false&tail=10000'));
  if(logStatus===200){
   assert.equal(await readFile(plan.observerLogPath,'utf8'),actual.stdout);
   assert.equal(await readFile(join(plan.artifactDirectory,'observer.log'),'utf8'),actual.stdout);
   const raw=await readFile(join(plan.artifactDirectory,'observer.docker-raw'));assert.equal(raw.readUInt32BE(4),Buffer.byteLength(actual.stdout));assert.equal(raw.subarray(8).toString(),actual.stdout);
   const ref=await referenceFile(plan.observerLogPath);assert.equal(ref.size_bytes,Buffer.byteLength(actual.stdout));
  }
  const calls=(await readFile(effects,'utf8')).trim().split('\n').map(line=>JSON.parse(line) as string[]);
  assert.equal(calls.some(args=>args.includes('down')),false);
 }
});
