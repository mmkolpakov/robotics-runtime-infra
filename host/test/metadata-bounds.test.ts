import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createServer} from 'node:http';
import {once} from 'node:events';
import type {IncomingMessage,ServerResponse} from 'node:http';
import {mkdtemp,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,dirname} from 'node:path';
import {referenceFile} from '@robotics-runtime/host';
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
  return {server:api,endpoint:{socketPath,operationMinApi:'1.24',operationMaxApi:'1.53'},close:async()=>{
    api.closeAllConnections();await new Promise<void>((resolve,reject)=>api.close(error=>error?reject(error):resolve()));
    await rm(root,{recursive:true,force:true});
  }};
}

function prematureClose(response:ServerResponse,signal:AbortSignal):Promise<void> {
  return once(response,'close',{signal}).then(()=>{assert.equal(response.writableFinished,false)});
}
function timeoutRefusal(error:unknown):boolean {
  return error instanceof Error&&(error.name==='TimeoutError'||
    ('code' in error&&error.code==='ABORT_ERR'&&error.cause instanceof Error&&error.cause.name==='TimeoutError'));
}
function cancelledBy(reason:Error):(error:unknown)=>boolean {
  return error=>error===reason||(error instanceof Error&&'code' in error&&error.code==='ABORT_ERR'&&error.cause===reason);
}

test('native discovery deadline rejects with its actual timeout reason', {timeout:2000}, async(t)=>{
  let requests=0,closed:Promise<void>|undefined;
  const api=await server((_request,response)=>{requests++;closed=prematureClose(response,t.signal)});
  try {
    await assert.rejects(EngineMetadata.connect(api.endpoint,{deadlineMs:25}),timeoutRefusal);
    // The deadline may expire before this server accepts the request.
    if(closed)await closed;
    assert.ok(requests<=1);
  } finally {await api.close()}
});

test('native discovery cancellation closes an accepted Unix response before cleanup', {timeout:2000}, async(t)=>{
  let requests=0,closed:Promise<void>|undefined;
  const api=await server((_request,response)=>{requests++;closed=prematureClose(response,t.signal)});
  try {
    const arrived=once(api.server,'request',{signal:t.signal});
    const abort=new AbortController(),reason=new Error('test cancellation');
    const rejected=assert.rejects(EngineMetadata.connect(api.endpoint,{deadlineMs:1000,cancelSignal:abort.signal}),cancelledBy(reason));
    await arrived;abort.abort(reason);await rejected;
    assert.ok(closed);await closed;assert.equal(requests,1);
  } finally {await api.close()}
});

test('pre-cancelled discovery and invalid deadline make no additional Unix request', {timeout:2000}, async()=>{
  let requests=0;
  const api=await server(()=>{requests++});
  try {
    const baseline=requests,abort=new AbortController();abort.abort(new Error('test cancellation'));
    await assert.rejects(EngineMetadata.connect(api.endpoint,{cancelSignal:abort.signal}),/test cancellation/);
    assert.equal(requests,baseline);
    await assert.rejects(EngineMetadata.connect(api.endpoint,{deadlineMs:0}),/finite/);
    assert.equal(requests,baseline);
  } finally {await api.close()}
});

test('image metadata deadline prevents continuation to network reads', {timeout:2000}, async(t)=>{
  const requests:string[]=[];let imageClosed:Promise<void>|undefined;
  const api=await server((request,response)=>{
    requests.push(request.url!);
    if(request.url==='/version')json(response,version);
    else if(request.url==='/v1.41/containers/'+id+'/json')json(response,container);
    else if(request.url?.startsWith('/v1.41/images/'))imageClosed=prematureClose(response,t.signal);
    else json(response,[]);
  });
  try {
    const engine=await EngineMetadata.connect(api.endpoint);
    await assert.rejects(engine.inspect(id,required,{deadlineMs:25}),timeoutRefusal);
    if(imageClosed)await imageClosed;
    assert.equal(requests.some(path=>path.startsWith('/v1.41/networks')),false);
  } finally {await api.close()}
});

test('canceled network metadata rejects rather than becoming a completed observation', {timeout:2000}, async(t)=>{
  let networkClosed:Promise<void>|undefined;
  const api=await server((request,response)=>{
    if(request.url==='/version')json(response,version);
    else if(request.url==='/v1.41/containers/'+id+'/json')json(response,{...container,HostConfig:{...container.HostConfig,NetworkMode:'bridge'},NetworkSettings:{Networks:{n:{NetworkID:'network-id'}}}});
    else if(request.url?.startsWith('/v1.41/images/'))json(response,{Id:imageId});
    else {networkClosed=prematureClose(response,t.signal);api.server.emit('held-request')}
  });
  try {
    const engine=await EngineMetadata.connect(api.endpoint),abort=new AbortController(),reason=new Error('stop network observation');
    const arrived=once(api.server,'held-request',{signal:t.signal});
    const rejected=assert.rejects(engine.inspect(id,required,{deadlineMs:1000,cancelSignal:abort.signal}),cancelledBy(reason));
    await arrived;abort.abort(reason);await rejected;
    assert.ok(networkClosed);await networkClosed;
  } finally {await api.close()}
});

test('owned inventory deadline bounds the whole request group', {timeout:2000}, async(t)=>{
  const requests:string[]=[];let volumesClosed:Promise<void>|undefined;
  const api=await server((request,response)=>{
    requests.push(request.url!);
    if(request.url==='/version')json(response,version);
    else if(request.url?.startsWith('/v1.41/volumes'))volumesClosed=prematureClose(response,t.signal);
    else json(response,[]);
  });
  try {
    const engine=await EngineMetadata.connect(api.endpoint);
    await assert.rejects(engine.remainingOwned('run1',{deadlineMs:25}),timeoutRefusal);
    if(volumesClosed)await volumesClosed;
    assert.ok(requests.length>=1&&requests.length<=4);
    const paths=requests.slice(1).map(path=>new URL('http://engine'+path).pathname);
    assert.equal(new Set(paths).size,paths.length);
    for(const path of paths)assert.ok(['/v1.41/containers/json','/v1.41/volumes','/v1.41/networks'].includes(path));
    for(const path of requests.slice(1))assert.deepEqual(JSON.parse(new URL('http://engine'+path).searchParams.get('filters')!),{label:['org.robotics.runtime.run-id=run1']});
  } finally {await api.close()}
});

test('owned inventory cancellation closes an accepted request group before cleanup', {timeout:2000}, async(t)=>{
  const requests:string[]=[];let volumesClosed:Promise<void>|undefined;
  const api=await server((request,response)=>{
    requests.push(request.url!);
    if(request.url==='/version')json(response,version);
    else if(request.url?.startsWith('/v1.41/volumes'))volumesClosed=prematureClose(response,t.signal);
    else json(response,[]);
    if(requests.length===4)api.server.emit('inventory-ready');
  });
  try {
    const engine=await EngineMetadata.connect(api.endpoint),abort=new AbortController(),reason=new Error('stop inventory observation');
    const arrived=once(api.server,'inventory-ready',{signal:t.signal});
    const rejected=assert.rejects(engine.remainingOwned('run1',{deadlineMs:1000,cancelSignal:abort.signal}),cancelledBy(reason));
    await arrived;abort.abort(reason);await rejected;
    assert.ok(volumesClosed);await volumesClosed;
    assert.equal(requests.length,4);
    assert.deepEqual(new Set(requests.slice(1).map(path=>new URL('http://engine'+path).pathname)),new Set(['/v1.41/containers/json','/v1.41/volumes','/v1.41/networks']));
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

test('deployment info uses the selected SDK Unix endpoint and cancels its actual held request', {timeout:2000}, async(t)=>{
  let held=false,closed:Promise<void>|undefined;const requests:string[]=[];
  const raw={OperatingSystem:'Ubuntu 24.04.3 LTS',KernelVersion:'6.8.0-generic',Architecture:'x86_64',Runtimes:{nvidia:{path:'nvidia-container-runtime'}}};
  const api=await server((request,response)=>{
    requests.push(request.url!);
    if(request.url==='/version')json(response,version);
    else if(request.url==='/v1.41/info'){
      if(held)closed=prematureClose(response,t.signal);
      else json(response,raw);
    }else json(response,{unexpected:true});
  });
  try{
    const engine=await EngineMetadata.connect(api.endpoint);
    const observed=await engine.deploymentInfo();
    assert.deepEqual(observed.info,raw);assert.equal(observed.engine.endpoint,'unix://'+api.endpoint.socketPath);
    assert.equal(observed.engine.clientApi,'1.41');
    held=true;
    const arrived=once(api.server,'request',{signal:t.signal});
    const abort=new AbortController(),reason=new Error('deployment read cancelled');
    const rejected=assert.rejects(engine.deploymentInfo({deadlineMs:1000,cancelSignal:abort.signal}),cancelledBy(reason));
    await arrived;abort.abort(reason);await rejected;
    assert.ok(closed);await closed;
    assert.deepEqual(requests,['/version','/v1.41/info','/v1.41/info']);
  }finally{await api.close()}
});

test('owned empty native log streams retain actual zero bytes and a zero-byte file reference',async()=>{
  for(const tty of [false,true]){
    const requests:string[]=[];
    const api=await server((request,response)=>{
      requests.push(request.url!);
      if(request.url==='/version')json(response,version);
      else if(request.url==='/v1.41/containers/'+id+'/json')json(response,{...container,Config:{...container.Config,Tty:tty}});
      else {response.writeHead(200,{'content-type':'application/vnd.docker.raw-stream'});response.end()}
    });
    try{
      const engine=await EngineMetadata.connect(api.endpoint);
      const observed=await engine.readLogs(id,{runId:'run1',projectName:'owned-1'},{tailLines:17,maxBytes:1024,deadlineMs:1000});
      assert.equal(observed.containerId,id);assert.equal(observed.clientApi,'1.41');assert.equal(observed.tty,tty);
      assert.deepEqual(observed.bytes,Buffer.alloc(0));
      const path=join(dirname(api.endpoint.socketPath),'observer.docker-raw');await writeFile(path,observed.bytes);
      const ref=await referenceFile(path);assert.equal(ref.size_bytes,0);
      assert.equal(ref.sha256,'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      assert.deepEqual(requests,['/version','/v1.41/containers/'+id+'/json','/v1.41/containers/'+id+'/logs?stdout=true&stderr=true&follow=false&tail=17']);
    }finally{await api.close()}
  }
});

test('empty logs cannot bypass native ownership or missing transport framing',async()=>{
  for(const config of [
    {...container.Config,Tty:false,Labels:{...container.Config.Labels,'org.robotics.runtime.run-id':'foreign'}},
    {...container.Config},
  ]){
    let logRequests=0;
    const api=await server((request,response)=>{
      if(request.url==='/version')json(response,version);
      else if(request.url==='/v1.41/containers/'+id+'/json')json(response,{...container,Config:config});
      else {logRequests++;response.end()}
    });
    try{
      const engine=await EngineMetadata.connect(api.endpoint);
      await assert.rejects(engine.readLogs(id,{runId:'run1',projectName:'owned-1'},{tailLines:1,maxBytes:1024,deadlineMs:1000}),/ownership|framing/);
      assert.equal(logRequests,0);
    }finally{await api.close()}
  }
});

test('native log HTTP errors never become successful empty streams',async()=>{
  for(const statusCode of [404,500]){
    const api=await server((request,response)=>{
      if(request.url==='/version')json(response,version);
      else if(request.url==='/v1.41/containers/'+id+'/json')json(response,{...container,Config:{...container.Config,Tty:false}});
      else {response.statusCode=statusCode;json(response,{message:'native log request failed'})}
    });
    try{
      const engine=await EngineMetadata.connect(api.endpoint);
      await assert.rejects(engine.readLogs(id,{runId:'run1',projectName:'owned-1'},{tailLines:1,maxBytes:1024,deadlineMs:1000}),
        (error:unknown)=>typeof error==='object'&&error!==null&&Reflect.get(error,'statusCode')===statusCode);
    }finally{await api.close()}
  }
});

test('native log EOF is required and over-limit streams are refused',async()=>{
  for(const mode of ['truncated','over-limit']){
    const api=await server((request,response)=>{
      if(request.url==='/version')json(response,version);
      else if(request.url==='/v1.41/containers/'+id+'/json')json(response,{...container,Config:{...container.Config,Tty:false}});
      else if(mode==='truncated'){
        response.writeHead(200,{'content-type':'application/vnd.docker.raw-stream','content-length':'100'});
        response.write(Buffer.from('partial'));setImmediate(()=>response.destroy());
      }else {response.writeHead(200,{'content-type':'application/vnd.docker.raw-stream'});response.end(Buffer.alloc(33))}
    });
    try{
      const engine=await EngineMetadata.connect(api.endpoint);
      const pending=engine.readLogs(id,{runId:'run1',projectName:'owned-1'},{tailLines:1,maxBytes:32,deadlineMs:1000});
      if(mode==='over-limit')await assert.rejects(pending,/byte bound/);else await assert.rejects(pending);
    }finally{await api.close()}
  }
});

test('native log deadline and accepted zero-byte stream cancellation refuse without EOF', {timeout:4000}, async(t)=>{
  for(const mode of ['cancel','deadline']){
    let closed:Promise<void>|undefined;
    const api=await server((request,response)=>{
      if(request.url==='/version')json(response,version);
      else if(request.url==='/v1.41/containers/'+id+'/json')json(response,{...container,Config:{...container.Config,Tty:false}});
      else {
        closed=prematureClose(response,t.signal);
        response.writeHead(200,{'content-type':'application/vnd.docker.raw-stream'});response.flushHeaders();
        api.server.emit('held-request');
      }
    });
    try{
      const engine=await EngineMetadata.connect(api.endpoint),abort=new AbortController(),reason=new Error('stop native log read');
      const arrived=mode==='cancel'?once(api.server,'held-request',{signal:t.signal}):undefined;
      const pending=engine.readLogs(id,{runId:'run1',projectName:'owned-1'},{tailLines:1,maxBytes:1024,deadlineMs:mode==='deadline'?50:1000},abort.signal);
      const rejected=assert.rejects(pending,mode==='deadline'?timeoutRefusal:cancelledBy(reason));
      if(mode==='cancel'){await arrived;abort.abort(reason)}
      await rejected;
      if(mode==='cancel')assert.ok(closed);
      if(closed)await closed;
    }finally{await api.close()}
  }
});

test('native log reads preserve raw TTY and multiplexed bytes through finite EOF',async()=>{
  for(const tty of [false,true]){
    const payload=Buffer.from('native output\n');
    const header=Buffer.alloc(8);header[0]=1;header.writeUInt32BE(payload.length,4);
    const bytes=tty?payload:Buffer.concat([header,payload]);
    const api=await server((request,response)=>{
      if(request.url==='/version')json(response,version);
      else if(request.url==='/v1.41/containers/'+id+'/json')json(response,{...container,Config:{...container.Config,Tty:tty}});
      else {response.writeHead(200,{'content-type':'application/vnd.docker.raw-stream'});response.write(bytes.subarray(0,4));response.end(bytes.subarray(4))}
    });
    try{
      const engine=await EngineMetadata.connect(api.endpoint);
      const observed=await engine.readLogs(id,{runId:'run1',projectName:'owned-1'},{tailLines:17,maxBytes:1024,deadlineMs:1000});
      assert.equal(observed.tty,tty);assert.deepEqual(observed.bytes,bytes);
    }finally{await api.close()}
  }
});
