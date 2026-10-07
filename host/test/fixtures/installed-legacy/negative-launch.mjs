import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdir,readFile,writeFile,stat} from 'node:fs/promises';
import {Context,Jobs} from '@robotics-runtime/host';
import Docker from 'dockerode';
import {ComposeExecution,EngineMetadata} from '@robotics-runtime/infra-host';
import {legacyLiveComposeOptions,prefetchLegacyImages} from './app/qualify-legacy-live.mjs';
const [root,socket,image,artifacts,mode]=process.argv.slice(2);
assert.ok(['cancel','timeout','foreign-cleanup'].includes(mode));
assert.match(image,/^[^\s@]+@sha256:[a-f0-9]{64}$/);
assert.ok(import.meta.resolve('@robotics-runtime/infra-host').startsWith('file://'+root+'/node_modules/'));
const identity=JSON.parse(await readFile(root+'/identity.json','utf8')),engineProfile=identity.engineProfile;
const runId='run-'+randomUUID(),project='rr-installed-ros-negative-'+runId.slice(4,12),owner='installed-ros-negative-'+runId.slice(4,12);
await mkdir(artifacts,{recursive:false});
const save=(name,value)=>writeFile(artifacts+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const ctx=new Context();await ctx.plugin(Jobs,{timeoutMs:600000,maxBufferBytes:4194304}).await();
const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
const native=new Docker({socketPath:socket,version:'v'+engine.facts.clientApi});
const actualEngine=engine.facts.versionResponse.Components?.some(row=>row.Name==='Podman Engine')?'podman':'docker';
assert.equal(actualEngine,engineProfile.engine);await save('engine',engine.facts);
const absentVolume=async name=>{try{await native.getVolume(name).inspect({abortSignal:AbortSignal.timeout(10000)})}catch(error){assert.equal(error.statusCode,404);await save('absent-volume-'+name,{name,statusCode:404});return}assert.fail('negative fixture volume is already present: '+name)};
const job=async(name,args)=>{const result=await ctx.jobs.run({executable:'/usr/bin/'+actualEngine,args,env:actualEngine==='docker'?{DOCKER_HOST:'unix://'+socket,DOCKER_CONTEXT:''}:{},extendEnv:true,timeoutMs:30000,maxBufferBytes:4194304});await save(name,result);assert.equal(result.ok,true,result.stderr);return result};
const env={C18_NODE_IMAGE:image,C18_SOCKET:socket,C18_SOCKET_GID:String((await stat(socket)).gid),C18_HOST_OWNER:owner,C18_HOST_PROJECT:project,
 C18_SOURCE_VOLUME:identity.sourceVolume,C18_RETAINED_VOLUME:identity.retainedVolume,C18_DEPLOYMENT_HOST_ROOT:root+'/deployment'};
const compose=new ComposeExecution(ctx.jobs,{executable:root+'/tools/docker-compose',socketPath:socket,projectName:project,
 files:[root+'/compose.host.yaml',root+'/compose.host.'+actualEngine+'.yaml'],cwd:root,env,timeoutMs:600000,maxBufferBytes:4194304});
const ids=text=>text.trim()?text.trim().split(/\s+/):[];
try{
 const before=ids((await job('pre-existing-containers-before',['ps','--all','--quiet','--no-trunc'])).stdout);
 for(const volume of [identity.sourceVolume,identity.retainedVolume])await absentVolume(volume);
 await job('create-retained-volume',['volume','create','--label','org.robotics.runtime.storage-owner='+owner,'--label','org.robotics.runtime.run-id='+owner,identity.retainedVolume]);
 await compose.requireVersion();
 if(actualEngine==='docker'){
  const options=legacyLiveComposeOptions({root:root+'/deployment',socket,executable:root+'/tools/docker-compose',runId,sourceVolume:identity.sourceVolume,retainedVolume:identity.retainedVolume,
   simulationImage:identity.simulationId,simulationReference:identity.simulationImage,coordinatorImage:identity.finalizerImage,evidenceImage:identity.evidenceImage,sourceRevision:identity.deploymentRevision},
   {engineProfile,sourceHostRoot:root+'/deployment',composeEnvironment:{COMPOSE_PARALLEL_LIMIT:'1'}});
  await prefetchLegacyImages(new ComposeExecution(ctx.jobs,options),[identity.simulationId,identity.finalizerImage,identity.evidenceImage],job,save);
 }
 const init=await compose.run(['run','--rm','--no-deps','storage-init']);await save('storage-init',init);assert.equal(init.ok,true,init.stderr);
 const result=await compose.run(['run','--rm','--no-deps','--entrypoint','node','installed-host','/app/negative-bootstrap.mjs',mode,'/inputs','/engine.sock','/usr/local/bin/docker-compose',
  runId,identity.sourceVolume,identity.retainedVolume,identity.simulationId,identity.simulationImage,identity.finalizerImage,identity.evidenceImage,'/retained/startup-'+runId,identity.deploymentRevision]);
 await save('installed-negative-job',result);assert.equal(result.ok,true,result.stderr);
 const report=JSON.parse(result.stdout.trim().split('\n').reverse().find(line=>line.startsWith('{')));assert.equal(report.status,'passed');assert.equal(report.mode,mode);assert.equal(report.engine,actualEngine);
 const runtime=await engine.remainingOwned(runId);await save('runtime-after-negative',runtime);assert.equal(runtime.containers.length,0);assert.equal(runtime.networks.length,0);assert.ok(runtime.volumes.Volumes===null||runtime.volumes.Volumes.length===0);
 const hostOwned=await engine.projectOwnership({runId:owner,projectName:project});await save('host-before-source-removal',hostOwned);assert.equal(hostOwned.status,'complete');assert.equal(hostOwned.inventory.containers.length,0);assert.equal(hostOwned.inventory.networks.length,0);
 const down=await compose.run(['down','--remove-orphans']);await save('host-down',down);assert.equal(down.ok,true,down.stderr);
 const volume=(await native.getVolume(identity.sourceVolume).inspect());await save('source-volume-before-removal',volume);assert.equal(volume.Labels['org.robotics.runtime.run-id'],owner);assert.equal(volume.Labels['org.robotics.runtime.storage-owner'],owner);
 await job('remove-only-owned-source-volume',['volume','rm',identity.sourceVolume]);await absentVolume(identity.sourceVolume);
 const after=ids((await job('pre-existing-containers-after',['ps','--all','--quiet','--no-trunc'])).stdout);assert.ok(before.every(id=>after.includes(id)),'a pre-existing container disappeared');
 const retained=await native.getVolume(identity.retainedVolume).inspect();assert.equal(retained.Labels['org.robotics.runtime.run-id'],owner);
 await save('installed-negative-report',{...report,identity,sourceVolumeRemoved:true,retainedVolume:identity.retainedVolume,preExistingContainerIdsPreserved:before});
 console.log(JSON.stringify({...report,sourceVolumeRemoved:true,retainedVolume:identity.retainedVolume}));
}catch(error){await save('failure',{status:'failed',diagnostic:String(error),identity,mode,runId,project});throw error}finally{await ctx.fiber.dispose()}
