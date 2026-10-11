import {test} from 'node:test';
import assert from 'node:assert/strict';
import {assertOwned, canonicalConfigId, recoverCreated, createdId, nativeWaitExit, assertRosStopSignal, admitAndStart, removeUnstartedOwned} from './native-identity.mjs';

const expected={cid:'a'.repeat(64),image:'sha256:'+'b'.repeat(64),owner:'issued-owner',name:'issued-name',stopSignal:'SIGINT'};
const native=()=>({Id:expected.cid,Image:'b'.repeat(64),Name:'/issued-name',Config:{Labels:{'org.example.nav2.owner':'issued-owner'},StopSignal:2},State:{Running:true}});

test('bare config ID and prefixed config ID identify the same exact configuration',()=>{
  assert.equal(canonicalConfigId('b'.repeat(64)),expected.image);
  assertOwned(native(),expected);
  assertOwned({...native(),Image:expected.image},expected);
});
test('manifest or another valid configuration cannot substitute for the selected configuration',()=>{
  assert.throws(()=>assertOwned({...native(),Image:'c'.repeat(64)},expected));
});
test('only exact lower-case config ID syntax is normalized',()=>{
  for(const value of ['B'.repeat(64),'sha256:'+'b'.repeat(63),' b'.repeat(64),'sha256:sha256:'+'b'.repeat(64),'b'.repeat(64)+'\n',null])
    assert.throws(()=>canonicalConfigId(value));
});
test('foreign identity and missing ownership refuse before any cleanup effect',()=>{
  for(const changed of [
    {...native(),Id:'c'.repeat(64)},
    {...native(),Name:'/foreign'},
    {...native(),Name:'//issued-name'},
    {...native(),Config:{Labels:{}}},
    {...native(),Config:{Labels:{'org.example.nav2.owner':'foreign'}}}
  ]) assert.throws(()=>assertOwned(changed,expected));
});
test('lost native create response recovers an exact owner-labelled object, retaining only read operations',async()=>{
  const calls=[];
  const result=await recoverCreated(async(op,args)=>{
    calls.push(args[0]); return args[0]==='ps'?expected.cid+'\n':JSON.stringify([native()]);
  },expected);
  assert.equal(result.Id,expected.cid);
  assert.deepEqual(calls,['ps','inspect']);
});
test('lost create response with foreign or ambiguous inventory cannot authorize a stop',async()=>{
  for(const raw of [expected.cid+'\n'+'c'.repeat(64),'truncated']){
    const calls=[];
    await assert.rejects(recoverCreated(async(op,args)=>{calls.push(args[0]);return raw;},expected));
    assert.deepEqual(calls,['ps']);
  }
  await assert.rejects(recoverCreated(async(op,args)=>args[0]==='ps'?expected.cid:JSON.stringify([{...native(),Name:'/foreign'}]),expected));
});
test('unavailable inventory remains a refusal, not an empty success',async()=>{
  await assert.rejects(recoverCreated(async()=>{throw new Error('transport unavailable')},expected),/transport unavailable/);
});
test('an actual empty successful inventory has no owned object',async()=>{
  assert.equal(await recoverCreated(async()=>'',expected),null);
});
test('malformed create response never installs an unvalidated CID, so recovery remains required',()=>{
  assert.equal(createdId(expected.cid+'\n'),expected.cid);
  for(const raw of ['corrupt',expected.cid+'\n\n',expected.cid+'\r\n',' '+expected.cid]) assert.throws(()=>createdId(raw));
});
test('native wait accepts exactly one integer line, without hiding CRLF or extra rows',()=>{
  for(const raw of ['0','0\n','137\n','255']) assert.equal(nativeWaitExit(raw),Number(raw));
  for(const raw of ['0\n\n','0\r\n',' 0\n','0\n137\n','-1\n','256\n','00\n','']) assert.throws(()=>nativeWaitExit(raw));
});

test('the native ROS launch shutdown signal stays SIGINT on acquisition and cleanup',()=>{
  assertOwned(native(),expected);
  assertRosStopSignal(native());
  assertRosStopSignal({...native(),Config:{...native().Config,StopSignal:'SIGINT'}});
  for(const signal of [15,'SIGTERM',9,'SIGKILL',null,'2']){
    assert.throws(()=>assertRosStopSignal({...native(),Config:{...native().Config,StopSignal:signal}}));
  }
});

test('actual acquired caller refuses wrong signal before start/exec and removes exactly owned unstarted object',async()=>{
  const bad={...native(),Config:{...native().Config,StopSignal:15},State:{Running:false,Pid:0,Status:'created'}};
  const calls=[];
  const command=async(op,args)=>{calls.push(args[0]);if(args[0]==='inspect')return JSON.stringify([bad]);if(args[0]==='rm')return expected.cid;throw new Error('unexpected native effect');};
  await assert.rejects(admitAndStart(command,expected),/not SIGINT/);
  assertOwned(bad,expected);
  assert.equal(await removeUnstartedOwned(command,bad,expected),true);
  assert.deepEqual(calls,['inspect','rm']);
});
test('the same actual acquired caller starts only after complete ownership and behavior admission',async()=>{
  const calls=[];
  await admitAndStart(async(op,args)=>{calls.push(args[0]);return args[0]==='inspect'?JSON.stringify([native()]):expected.cid},expected);
  assert.deepEqual(calls,['inspect','start']);
});
test('foreign acquisition cannot start or authorize the unstarted cleanup path',async()=>{
  const foreign={...native(),Name:'/foreign',State:{Running:false,Pid:0,Status:'created'}};
  const calls=[];
  const command=async(op,args)=>{calls.push(args[0]);return JSON.stringify([foreign])};
  await assert.rejects(admitAndStart(command,expected));
  await assert.rejects(removeUnstartedOwned(command,foreign,expected));
  assert.deepEqual(calls,['inspect']);
});
test('running or previously exited actor never uses the unstarted removal shortcut',async()=>{
  for(const state of [{Running:true,Pid:123,Status:'running'},{Running:false,Pid:0,Status:'exited'}]){
    assert.equal(await removeUnstartedOwned(async()=>{throw new Error('unexpected remove')},{...native(),State:state},expected),false);
  }
});
