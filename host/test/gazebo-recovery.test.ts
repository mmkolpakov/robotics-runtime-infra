import assert from 'node:assert/strict';
import {test} from 'node:test';
import type {TestContext} from 'node:test';
import {createServer} from 'node:http';
import {existsSync} from 'node:fs';
import {mkdtemp, readFile, readdir, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Context, Jobs, RunResources} from '@robotics-runtime/host';
import GazeboRosV1 from '../src/plugins/gazebo-ros-v1/index.js';
import LegacyInputs from '../src/plugins/gazebo-ros-v1/inputs.js';
import type {LegacyRunInput} from '../src/plugins/gazebo-ros-v1/inputs.js';

const parentId='a'.repeat(64),childId='b'.repeat(64),imageId='sha256:'+'c'.repeat(64);
const labels=(service:string)=>({'org.robotics.runtime.run-id':'run1','com.docker.compose.project':'owned-1','com.docker.compose.service':service});
const parent=()=>({Id:parentId,Image:imageId,Config:{User:'1000:1000',Labels:labels('simulation')},
  State:{Status:'running',Running:true,ExitCode:0},Mounts:[],HostConfig:{NetworkMode:'none'},NetworkSettings:{Networks:{}}});
const child=()=>({...parent(),Id:childId,Config:{User:'1000:1000',Labels:labels('simulation-stepper')},
  HostConfig:{NetworkMode:'container:'+parentId,IpcMode:'container:'+parentId}});
type NativeContainer=ReturnType<typeof parent>;

async function fixture(t:TestContext,mode='partial',containers:NativeContainer[]=[parent(),child()],listedContainers:NativeContainer[]=containers) {
  const root=await mkdtemp(join(tmpdir(),'rr-gazebo-recovery-')),ctx=new Context(),requests:string[]=[];
  const effects=join(root,'effects'),removed=join(root,'removed'),socketPath=join(root,'engine.sock');
  const api=createServer((request,response)=>{
    const path=request.url!;requests.push(path);let value:unknown;
    if(path==='/version')value={ApiVersion:'1.41',MinAPIVersion:'1.24'};
    else if(path.startsWith('/v1.41/containers/json'))value=existsSync(removed)?[]:listedContainers.map(row=>({Id:row.Id,Labels:row.Config.Labels}));
    else if(path.startsWith('/v1.41/volumes'))value={Volumes:null};
    else if(path.startsWith('/v1.41/networks'))value=[];
    else if(path.startsWith('/v1.41/images/'))value={Id:imageId};
    else value=containers.find(row=>path==='/v1.41/containers/'+row.Id+'/json');
    response.setHeader('content-type','application/json');
    if(value===undefined){response.statusCode=404;value={message:'missing test metadata'}}
    response.end(JSON.stringify(value));
  });
  await new Promise<void>(resolve=>api.listen(socketPath,resolve));
  const executable=join(root,'compose.mjs');
  await writeFile(executable,'#!'+process.execPath+'\n'+
    'import {appendFileSync,writeFileSync} from "node:fs";\n'+
    'const args=process.argv.slice(2);appendFileSync('+JSON.stringify(effects)+',JSON.stringify(args)+"\\n");\n'+
    'if(args.includes("version"))console.log("5.3.1");\n'+
    'else if(args.includes("up")&&'+JSON.stringify(mode)+'==="partial"){console.error("fixture interrupted up");process.exit(1)}\n'+
    'else if(args.includes("ps"))console.log(args.at(-1)==="simulation"?'+JSON.stringify(parentId)+':'+JSON.stringify(childId)+');\n'+
    'else if(args.includes("exec"))console.log(JSON.stringify({last_ns:"1"}));\n'+
    'else if(args.includes("down"))writeFileSync('+JSON.stringify(removed)+',"removed");\n',{mode:0o700});
  await ctx.plugin(Jobs,{timeoutMs:2000,maxBufferBytes:1048576}).await();
  const requirement={runId:'run1',projectName:'owned-1',imageId,user:'1000:1000',mounts:[],hostConfig:{}};
  const input:LegacyRunInput={runId:'run1',compose:{executable,socketPath,projectName:'owned-1',files:[join(root,'compose.yaml')],cwd:root,timeoutMs:1000},
    artifactDirectory:join(root,'retained'),observationServices:[],simulationRequirement:requirement,stepperRequirement:requirement,
    entityWorkerPath:'/fixed/entity.py',clockWorkerPath:'/fixed/clock.py',readinessWorkerPath:'/fixed/readiness.py'};
  let provider!:GazeboRosV1,resources!:RunResources;
  const runFiber=ctx.plugin(async scope=>{
    await scope.plugin(RunResources,'run1').await();
    await scope.plugin(LegacyInputs).await();
    const inputs=scope.get('legacyInputs');assert.ok(inputs);inputs.issue(input);
    await scope.plugin(GazeboRosV1).await();
    const current=scope.get('gazeboRosV1'),owned=scope.get('runResources');assert.ok(current);assert.ok(owned);
    provider=current;resources=owned;
  });
  await runFiber.await();
  t.after(async()=>{
    await ctx.fiber.dispose().catch(()=>{});
    api.closeAllConnections();await new Promise<void>((resolve,reject)=>api.close(error=>error?reject(error):resolve()));
    await rm(root,{recursive:true,force:true});
  });
  return {root,ctx,runFiber,provider,resources,requests,effects};
}
async function commands(path:string):Promise<string[][]>{
  return (await readFile(path,'utf8')).trim().split('\n').map(line=>JSON.parse(line));
}

test('interrupted startup recovers its unique admitted namespace parent before explicit cleanup',async t=>{
  const {root,runFiber,provider,resources,effects}=await fixture(t);
  await assert.rejects(provider.ready(AbortSignal.timeout(1000)),/application-start/);
  const observed=await provider.observeCleanupOwnership(AbortSignal.timeout(1000));
  assert.equal(observed.status,'complete');assert.equal(observed.namespaceParents.length,1);
  assert.throws(()=>provider.snapshot(),/incomplete/);
  assert.equal((await commands(effects)).some(args=>args.includes('down')),false);
  const retained=await readdir(join(root,'retained'));
  assert.ok(retained.some(name=>name.endsWith('partial-start-simulation-native-metadata.json')));
  await runFiber.dispose();
  const outcomes=await resources.verify(1000);
  assert.equal(outcomes[0]!.released,true,JSON.stringify(outcomes));assert.equal(outcomes[0]!.cleanupError,undefined);
  assert.equal((await commands(effects)).filter(args=>args.includes('down')).length,1);
});

for(const [name,containers,diagnostic] of [
  ['missing parent',[child()],/foreign or unbound/],
  ['multiple simulation parents',[parent(),{...parent(),Id:'d'.repeat(64)},child()],/ambiguous/],
  ['wrong admitted image',[{...parent(),Image:'sha256:'+'e'.repeat(64)},child()],/native binding incomplete/],
  ['foreign actual parent owner',[{...parent(),Config:{User:'1000:1000',Labels:{...labels('simulation'),'org.robotics.runtime.run-id':'foreign'}}},child()],/foreign or unbound/],
  ['foreign namespace parent',[parent(),{...child(),HostConfig:{NetworkMode:'container:'+'f'.repeat(64)}}],/foreign or unbound/],
  ['missing exact parent ID',[{...parent(),Id:'short-id'},child()],/exact ID absent/],
] as const){
  test('partial startup refuses '+name+' and leaves cleanup effects unissued',async t=>{
    const {runFiber,provider,resources,effects}=await fixture(t,'partial',structuredClone([...containers]));
    await assert.rejects(provider.ready(AbortSignal.timeout(1000)),/application-start/);
    await assert.rejects(provider.observeCleanupOwnership(AbortSignal.timeout(1000)),diagnostic);
    await runFiber.dispose().catch(()=>{});
    const outcomes=await resources.verify(1000);
    assert.equal(outcomes[0]!.released,false);assert.ok(outcomes[0]!.cleanupError);
    assert.equal((await commands(effects)).some(args=>args.includes('down')),false);
  });
}

test('completed startup reuses its acquired parent and keeps readiness snapshot and cleanup behavior',async t=>{
  const {runFiber,provider,resources,requests,effects}=await fixture(t,'complete');
  assert.equal((await provider.ready(AbortSignal.timeout(1000))).ready,true);
  const snapshot=provider.snapshot();assert.equal(snapshot.simulationContainerId,parentId);
  const mark=requests.length;
  assert.equal((await provider.observeCleanupOwnership(AbortSignal.timeout(1000))).status,'complete');
  assert.deepEqual(provider.snapshot(),snapshot);
  const inventories=requests.slice(mark).filter(path=>path.startsWith('/v1.41/containers/json'));
  assert.equal(inventories.length,1);
  assert.deepEqual(JSON.parse(new URL('http://engine'+inventories[0]).searchParams.get('filters')!),{label:['com.docker.compose.project=owned-1']});
  await runFiber.dispose();const outcomes=await resources.verify(1000);assert.equal(outcomes[0]!.released,true,JSON.stringify(outcomes));
  assert.equal((await commands(effects)).filter(args=>args.includes('down')).length,1);
});

test('pre-canceled ownership recovery makes no Engine request or cleanup effect',async t=>{
  const {provider,requests,effects}=await fixture(t);
  await assert.rejects(provider.ready(AbortSignal.timeout(1000)),/application-start/);
  const before=requests.length,abort=new AbortController();abort.abort(new Error('caller canceled recovery'));
  await assert.rejects(provider.observeCleanupOwnership(abort.signal),/caller canceled recovery/);
  assert.equal(requests.length,before);
  assert.equal((await commands(effects)).some(args=>args.includes('down')),false);
});

for(const [name,actualLabels] of [
  ['service',{...labels('simulation'),'com.docker.compose.service':'foreign-service'}],
  ['owner',{...labels('simulation'),'org.robotics.runtime.run-id':'foreign-owner'}],
] as const){
  test('partial recovery refuses inspected parent '+name+' changed after the owned inventory',async t=>{
    const actual={...parent(),Config:{User:'1000:1000',Labels:actualLabels}};
    const {runFiber,provider,resources,effects}=await fixture(t,'partial',[actual,child()],[parent(),child()]);
    await assert.rejects(provider.ready(AbortSignal.timeout(1000)),/application-start/);
    await assert.rejects(provider.observeCleanupOwnership(AbortSignal.timeout(1000)),/native binding incomplete/);
    await runFiber.dispose().catch(()=>{});
    assert.ok((await resources.verify(1000))[0]!.cleanupError);
    assert.equal((await commands(effects)).some(args=>args.includes('down')),false);
  });
}
