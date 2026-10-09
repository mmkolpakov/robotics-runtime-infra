import test from 'node:test';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, writeFile, mkdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import fs from 'node:fs';
import {spawnSync} from 'node:child_process';
import {syncBuiltinESMExports} from 'node:module';
import {Context, Jobs, isDisposed} from '@robotics-runtime/host';
import {admitContext} from './admit-context.mjs';

const fixture=process.env.NAV2_CONTEXT_FIXTURE;
const contractsExecutable=process.env.NAV2_CONTRACTS_CLI;
if(!fixture||!contractsExecutable)throw new Error('actual public context fixture and CLI required');

test('actual public context/schema validation and foreign route controls before native effects',async()=>{
  const root=await mkdtemp(join(tmpdir(),'nav2-context-'));
  const ctx=new Context(), fiber=ctx.plugin(Jobs,{timeoutMs:15000,maxBufferBytes:1048576});
  await fiber.await();
  try{
    const original=JSON.parse(await readFile(join(fixture,'run-context.json'),'utf8'));
    let sequence=0;
    const run=async(change,expected)=>{
      const directory=join(root,String(++sequence));await mkdir(directory);
      const path=join(directory,'issued.json');
      await writeFile(path,JSON.stringify(change?change(structuredClone(original)):original));
      const output=join(directory,'retained');await mkdir(output);
      const invoke=()=>admitContext(ctx.jobs,{contextPath:path,
        scenarioPath:join(fixture,'scenario.json'),
        schemaPath:new URL('./nav2.schema.json',import.meta.url).pathname,
        contractsExecutable,output,domainId:'nav2',mode:'success'});
      if(expected){await assert.rejects(invoke,expected);return;}
      const admitted=await invoke();
      assert.equal(admitted.runId,original.run_id);
      assert.equal(admitted.domainId,'nav2');
      assert.match(admitted.runId,/^run-[a-f0-9-]{36}$/);
      assert.ok(admitted.contextSha256&&admitted.scenarioSha256);
    };
    await run();
    await run(value=>({...value,run_id:'nav2-'+value.run_id.slice(4)}),/public document validation refused/);
    await run(value=>({...value,domains:[{domain_id:'foreign',role:'simulation'}]}),/foreign run context/);
    await run(value=>({...value,scenario_sha256:'0'.repeat(64)}),/foreign run context/);
    await run(value=>({...value,scenario_id:'foreign'}),/foreign run context/);
    await run(value=>({...value,domains:[{domain_id:'nav2',role:'foreign'}]}),/foreign run context/);
    await run(value=>({...value,time_authority:{kind:'ptp',source_id:'gazebo-harmonic-clock'}}),/foreign run context/);
    await run(value=>({...value,time_authority:{kind:'sim_clock',source_id:'foreign'}}),/foreign run context/);
    const foreignScenario=JSON.parse(await readFile(join(fixture,'scenario.json'),'utf8'));
    foreignScenario.execution.data_plane_profile='foreign-profile';
    const scenarioPath=join(root,'foreign-scenario.json');
    const scenarioRaw=JSON.stringify(foreignScenario);await writeFile(scenarioPath,scenarioRaw);
    const contextPath=join(root,'foreign-route-context.json');
    await writeFile(contextPath,JSON.stringify({...original,scenario_sha256:createHash('sha256').update(scenarioRaw).digest('hex')}));
    const output=join(root,'foreign-route-retained');await mkdir(output);
    await assert.rejects(()=>admitContext(ctx.jobs,{contextPath,scenarioPath,
      schemaPath:new URL('./nav2.schema.json',import.meta.url).pathname,
      contractsExecutable,output,domainId:'nav2',mode:'success'}),/foreign execution route/);

  }finally{
    await fiber.dispose();await fiber.await();assert.equal(isDisposed(fiber),true);
    await rm(root,{recursive:true,force:true});
  }
});

test('driver never recovers or acquires a native actor before public context admission',async()=>{
  const source=await readFile(new URL('./native-check.mjs',import.meta.url),'utf8');
  assert.ok(source.indexOf('await admitContext(')<source.indexOf("command('create'"));
  assert.ok(source.includes('if(!cid&&acquisitionAttempted)'));
  assert.ok(source.indexOf('acquisitionAttempted=true')<source.indexOf("command('create'"));
});

test('actual opened document growth refuses before validator or native effects',async()=>{
  const root=await mkdtemp(join(tmpdir(),'nav2-context-growth-'));
  const source=join(root,'context.json'),output=join(root,'retained');await mkdir(output);
  await writeFile(source,'{}');
  const originalOpen=fs.promises.open;
  let changed=false,validated=false;
  fs.promises.open=async(...args)=>{
    const handle=await originalOpen(...args);
    const originalRead=handle.read.bind(handle);
    handle.read=async(...readArgs)=>{
      if(!changed){changed=true;await writeFile(source,Buffer.alloc(4*1024*1024+1,32));}
      return originalRead(...readArgs);
    };
    return handle;
  };
  syncBuiltinESMExports();
  try{
    await assert.rejects(()=>admitContext({run:async()=>{validated=true;throw new Error('validator must not run');}},
      {contextPath:source,scenarioPath:source,schemaPath:source,contractsExecutable:'unused',
       output,domainId:'nav2',mode:'success'}),/changed or exceeded/);
    assert.equal(changed,true);assert.equal(validated,false);
  }finally{
    fs.promises.open=originalOpen;syncBuiltinESMExports();
    await rm(root,{recursive:true,force:true});
  }
});

test('actual FIFO is refused as nonregular without waiting for a writer',async()=>{
  const root=await mkdtemp(join(tmpdir(),'nav2-context-fifo-'));
  try{
    const fifo=join(root,'input');assert.equal(spawnSync('mkfifo',[fifo],{timeout:1000}).status,0);
    const output=join(root,'retained');await mkdir(output);
    await assert.rejects(()=>admitContext({run:async()=>{throw new Error('validator must not run');}},
      {contextPath:fifo,scenarioPath:fifo,schemaPath:fifo,contractsExecutable:'unused',
       output,domainId:'nav2',mode:'success'}),/bounded regular document/);
  }finally{await rm(root,{recursive:true,force:true});}
});
