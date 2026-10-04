import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createServer} from 'node:http';
import type {IncomingMessage,ServerResponse} from 'node:http';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {EngineMetadata} from '../src/index.js';
import type {ContainerRequirement} from '../src/index.js';

const version={ApiVersion:'1.41',MinAPIVersion:'1.24'};
const id='c'.repeat(64),imageId='sha256:'+'a'.repeat(64);
const required:ContainerRequirement={runId:'run1',projectName:'owned-1',user:'10001:1000',mounts:[],hostConfig:{ReadonlyRootfs:true}};
const container={Id:id,Image:imageId,Config:{User:required.user,Labels:{'org.robotics.runtime.run-id':'run1','com.docker.compose.project':'owned-1'}},State:{Status:'running',Running:true,ExitCode:0},Mounts:[],HostConfig:{ReadonlyRootfs:true,NetworkMode:'none'},NetworkSettings:{Networks:{}}};
function json(response:ServerResponse,value:unknown):void {response.setHeader('content-type','application/json');response.end(JSON.stringify(value))}
async function server(work:(request:IncomingMessage,response:ServerResponse)=>void) {
  const root=await mkdtemp(join(tmpdir(),'rr-metadata-'));const socketPath=join(root,'engine.sock');
  const api=createServer(work);await new Promise<void>(resolve=>api.listen(socketPath,resolve));
  return {endpoint:{socketPath,operationMinApi:'1.24',operationMaxApi:'1.53'},close:async()=>{
    api.closeAllConnections();await new Promise<void>((resolve,reject)=>api.close(error=>error?reject(error):resolve()));
    await rm(root,{recursive:true,force:true});
  }};
}

test('native discovery deadline aborts the actual Unix request and pre-cancellation makes no request',async()=>{
  let requests=0,closed=false;
  const api=await server((request)=>{requests++;request.once('close',()=>{closed=true})});
  try {
    await assert.rejects(EngineMetadata.connect(api.endpoint,{deadlineMs:25}));
    await new Promise(resolve=>setTimeout(resolve,20));assert.equal(closed,true);
    const abort=new AbortController();abort.abort(new Error('test cancellation'));
    await assert.rejects(EngineMetadata.connect(api.endpoint,{cancelSignal:abort.signal}),/test cancellation/);
    assert.equal(requests,1);
    await assert.rejects(EngineMetadata.connect(api.endpoint,{deadlineMs:0}),/finite/);
    assert.equal(requests,1);
  } finally {await api.close()}
});

test('image metadata deadline prevents continuation to network reads',async()=>{
  const requests:string[]=[];let imageClosed=false;
  const api=await server((request,response)=>{
    requests.push(request.url!);
    if(request.url==='/version')json(response,version);
    else if(request.url==='/v1.41/containers/'+id+'/json')json(response,container);
    else if(request.url?.startsWith('/v1.41/images/'))request.once('close',()=>{imageClosed=true});
    else json(response,[]);
  });
  try {
    const engine=await EngineMetadata.connect(api.endpoint);
    await assert.rejects(engine.inspect(id,required,{deadlineMs:25}));
    await new Promise(resolve=>setTimeout(resolve,20));assert.equal(imageClosed,true);
    assert.equal(requests.some(path=>path.startsWith('/v1.41/networks')),false);
  } finally {await api.close()}
});

test('canceled network metadata rejects rather than becoming a completed observation',async()=>{
  let networkStarted!:()=>void;const started=new Promise<void>(resolve=>{networkStarted=resolve});let networkClosed=false;
  const api=await server((request,response)=>{
    if(request.url==='/version')json(response,version);
    else if(request.url==='/v1.41/containers/'+id+'/json')json(response,{...container,HostConfig:{...container.HostConfig,NetworkMode:'bridge'},NetworkSettings:{Networks:{n:{NetworkID:'network-id'}}}});
    else if(request.url?.startsWith('/v1.41/images/'))json(response,{Id:imageId});
    else {request.once('close',()=>{networkClosed=true});networkStarted()}
  });
  try {
    const engine=await EngineMetadata.connect(api.endpoint),abort=new AbortController();
    const read=engine.inspect(id,required,{deadlineMs:1000,cancelSignal:abort.signal});
    const rejected=assert.rejects(read);await started;abort.abort(new Error('stop network observation'));await rejected;
    await new Promise(resolve=>setTimeout(resolve,20));assert.equal(networkClosed,true);
  } finally {await api.close()}
});

test('owned inventory is bounded as one request group',async()=>{
  const requests:string[]=[];let volumesClosed=false;
  const api=await server((request,response)=>{
    requests.push(request.url!);
    if(request.url==='/version')json(response,version);
    else if(request.url?.startsWith('/v1.41/volumes'))request.once('close',()=>{volumesClosed=true});
    else json(response,[]);
  });
  try {
    const engine=await EngineMetadata.connect(api.endpoint);
    await assert.rejects(engine.remainingOwned('run1',{deadlineMs:25}));
    await new Promise(resolve=>setTimeout(resolve,20));assert.equal(volumesClosed,true);
    assert.equal(requests.length,4);
    for(const path of requests.slice(1))assert.deepEqual(JSON.parse(new URL('http://engine'+path).searchParams.get('filters')!),{label:['org.robotics.runtime.run-id=run1']});
  } finally {await api.close()}
});

test('discovery endpoint and metadata requirements cannot change during an awaited native response',async()=>{
  const api=await server((request,response)=>{
    if(request.url==='/version')setTimeout(()=>json(response,version),10);
    else if(request.url==='/v1.41/containers/'+id+'/json')setTimeout(()=>json(response,container),10);
    else json(response,{Id:imageId});
  });
  try {
    const endpoint={...api.endpoint};const pending=EngineMetadata.connect(endpoint);endpoint.socketPath='/foreign/engine.sock';endpoint.operationMaxApi='1.20';
    const engine=await pending;assert.equal(engine.facts.endpoint,'unix://'+api.endpoint.socketPath);assert.equal(engine.facts.clientApi,'1.41');
    const policy=structuredClone(required);const read=engine.inspect(id,policy);policy.runId='foreign';(policy.hostConfig as Record<string,unknown>).ReadonlyRootfs=false;
    assert.equal((await read).status,'complete');
  } finally {await api.close()}
});
