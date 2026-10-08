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
import type {ContainerRequirement} from '../src/engine-metadata.js';

const parentId='a'.repeat(64),childId='b'.repeat(64),imageId='sha256:'+'c'.repeat(64);
const labels=(service:string)=>({'org.robotics.runtime.run-id':'run1','com.docker.compose.project':'owned-1','com.docker.compose.service':service});
const parent=()=>({Id:parentId,Image:imageId,Config:{User:'1000:1000',Labels:labels('simulation')},
  State:{Status:'running',Running:true,ExitCode:0},Mounts:[],HostConfig:{NetworkMode:'none'},NetworkSettings:{Networks:{}}});
const child=()=>({...parent(),Id:childId,Config:{User:'1000:1000',Labels:labels('simulation-stepper')},
  HostConfig:{NetworkMode:'container:'+parentId,IpcMode:'container:'+parentId}});
type NativeContainer=ReturnType<typeof parent>;

async function fixture(t:TestContext,mode='partial',containers:NativeContainer[]=[parent(),child()],listedContainers:NativeContainer[]=containers,parentMetadata?:unknown,mounts:ContainerRequirement['mounts']=[],health?:{version:unknown;required:ContainerRequirement['healthcheck']}) {
  const root=await mkdtemp(join(tmpdir(),'rr-gazebo-recovery-')),ctx=new Context(),requests:string[]=[];
  const effects=join(root,'effects'),removed=join(root,'removed'),socketPath=join(root,'engine.sock');
  const api=createServer((request,response)=>{
    const path=request.url!.replace(/^\/v1\.\d+\//,'/v1.41/');requests.push(request.url!);let value:unknown;
    if(path==='/version')value=health?.version??{ApiVersion:'1.41',MinAPIVersion:'1.24'};
    else if(path.startsWith('/v1.41/containers/json'))value=existsSync(removed)?[]:listedContainers.map(row=>({Id:row.Id,Labels:row.Config.Labels}));
    else if(path.startsWith('/v1.41/volumes'))value={Volumes:null};
    else if(path.startsWith('/v1.41/networks'))value=[];
    else if(path.startsWith('/v1.41/images/'))value={Id:imageId};
    else if(path==='/v1.41/containers/'+parentId+'/json'&&parentMetadata!==undefined)value=parentMetadata;
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
  const requirement={runId:'run1',projectName:'owned-1',imageId,user:'1000:1000',mounts,hostConfig:{}};
  const input:LegacyRunInput={runId:'run1',compose:{executable,socketPath,projectName:'owned-1',files:[join(root,'compose.yaml')],cwd:root,timeoutMs:1000},
    artifactDirectory:join(root,'retained'),observationServices:[],simulationRequirement:{...requirement,...(health?{healthcheck:health.required}:{})},stepperRequirement:requirement,
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

const admittedMount={destination:'/run/robotics/input',readOnly:true,volumeName:'owned-input'};
for(const [name,metadata,mounts] of [
  ['wrong image',{...parent(),Image:'sha256:'+'e'.repeat(64)},[]],
  ['missing user',{...parent(),Config:{Labels:labels('simulation')}},[]],
  ['missing admitted mount',parent(),[admittedMount]],
  ['missing container metadata',{},[]],
] as const){
  test('successful up and ps cannot admit a parent with '+name+' for recovery or cleanup',async t=>{
    const {root,runFiber,provider,resources,effects}=await fixture(t,'complete',[parent(),child()],[parent(),child()],metadata,mounts);
    await assert.rejects(provider.ready(AbortSignal.timeout(1000)),/required observed simulation metadata incomplete/);
    assert.throws(()=>provider.snapshot(),/incomplete/);
    const paths=await readdir(join(root,'retained'));
    const bytes=async(name:string)=>readFile(join(root,'retained',paths.find(path=>path.endsWith('-'+name+'.json'))!));
    const started=JSON.parse((await bytes('application-start')).toString('utf8'));
    const acquired=JSON.parse((await bytes('simulation-id')).toString('utf8'));
    assert.equal(started.ok,true);assert.equal(acquired.ok,true);assert.equal(acquired.stdout.trim(),parentId);
    const failedMetadata=await bytes('simulation-native-metadata');
    const failedObservation=JSON.parse(failedMetadata.toString('utf8'));
    assert.equal(failedObservation.status,'incomplete');
    assert.deepEqual(failedObservation.container,metadata);
    await assert.rejects(provider.observeCleanupOwnership(AbortSignal.timeout(1000)),/partial startup simulation native binding incomplete/);
    assert.throws(()=>provider.snapshot(),/incomplete/);
    assert.deepEqual(await bytes('simulation-native-metadata'),failedMetadata);
    const recoveryFiles=await readdir(join(root,'retained'));
    assert.ok(recoveryFiles.some(path=>path.endsWith('-partial-start-simulation-native-metadata.json')));
    await runFiber.dispose().catch(()=>{});
    const outcomes=await resources.verify(1000);
    assert.equal(outcomes[0]!.released,false);assert.ok(outcomes[0]!.cleanupError);
    assert.equal((await commands(effects)).some(args=>args.includes('down')),false);
    assert.deepEqual(await bytes('simulation-native-metadata'),failedMetadata);
  });
}


const healthPolicy={Test:['CMD','native-probe'],StartInterval:2000000000,Interval:30000000000,Timeout:6000000000,StartPeriod:15000000000,Retries:3};
const dockerHealthVersion={ApiVersion:'1.48',MinAPIVersion:'1.24',Components:[{Name:'Engine',Version:'28.0.4'}]};
for(const [name,version] of [
  ['old Docker API',{...dockerHealthVersion,ApiVersion:'1.43'}],
  ['Podman startup scheduling',{...dockerHealthVersion,Components:[{Name:'Podman Engine'}]}],
  ['missing engine identity',{ApiVersion:'1.48',MinAPIVersion:'1.24'}],
] as const) {
  test('native health admission refuses '+name+' before acquisition',async t=>{
    const {provider,runFiber,effects,requests}=await fixture(t,'complete',[],[],undefined,[],{version,required:healthPolicy});
    await assert.rejects(provider.ready(AbortSignal.timeout(1000)),/Docker Engine API 1.44/);
    assert.deepEqual((await commands(effects)).map(args=>args.at(-2)),['version']);
    assert.deepEqual(requests,['/version']);
    assert.throws(()=>provider.snapshot(),/incomplete/);
    await runFiber.dispose();
    assert.equal((await commands(effects)).some(args=>args.includes('up')||args.includes('down')),false);
  });
}
for(const [name,acquired] of [
  ['missing startup interval',Object.fromEntries(Object.entries(healthPolicy).filter(([field])=>field!=='StartInterval'))],
  ['wrong startup interval',{...healthPolicy,StartInterval:0}],
  ['disabled native probe',{...healthPolicy,Test:['NONE']}],
] as const) {
  test('native health admission refuses acquired '+name+' and retains owned cleanup',async t=>{
    const actual={...parent(),Config:{...parent().Config,Healthcheck:acquired}};
    const {root,provider,runFiber,resources,effects}=await fixture(t,'complete',[actual,child()],[actual,child()],undefined,[],{version:dockerHealthVersion,required:healthPolicy});
    await assert.rejects(provider.ready(AbortSignal.timeout(1000)),/required observed simulation metadata incomplete/);
    assert.throws(()=>provider.snapshot(),/incomplete/);
    const names=await readdir(join(root,'retained'));
    const evidence=JSON.parse(await readFile(join(root,'retained',names.find(name=>name.endsWith('-simulation-native-metadata.json'))!),'utf8'));
    assert.equal(evidence.status,'incomplete');assert.deepEqual(evidence.container.Config.Healthcheck,acquired);
    await runFiber.dispose();
    assert.equal((await resources.verify(1000))[0]!.released,true);
    assert.equal((await commands(effects)).filter(args=>args.includes('down')).length,1);
  });
}
test('native health admission accepts the acquired Docker startup policy through normal readiness',async t=>{
  const actual={...parent(),Config:{...parent().Config,Healthcheck:healthPolicy}};
  const {provider,runFiber,resources}=await fixture(t,'complete',[actual,child()],[actual,child()],undefined,[],{version:dockerHealthVersion,required:healthPolicy});
  assert.equal((await provider.ready(AbortSignal.timeout(1000))).ready,true);
  assert.equal(provider.snapshot().simulationContainerId,parentId);
  await runFiber.dispose();assert.equal((await resources.verify(1000))[0]!.released,true);
});
