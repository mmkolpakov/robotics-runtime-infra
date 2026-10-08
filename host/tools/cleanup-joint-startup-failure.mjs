import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir,stat,readdir} from 'node:fs/promises';
import {createReadStream} from 'node:fs';
import {createHash} from 'node:crypto';
import {Context,Jobs} from '@robotics-runtime/host';
import {ComposeExecution,EngineMetadata} from '../dist/src/index.js';
const [root,socket,executable,runId,sourceVolume,retainedVolume,output,attempt='attempt1']=process.argv.slice(2);
assert.match(runId,/^run-[a-f0-9-]{36}$/);assert.match(attempt,/^[a-z0-9-]+$/);
const projectName='rr-joint-'+runId.slice(4,20);
const ctx=new Context();await ctx.plugin(Jobs,{timeoutMs:240000,maxBufferBytes:4194304}).await();
const env={ROBOTICS_RUN_ID:runId,LEGACY_SOURCE_ROOT:root,LEGACY_SOURCE_REVISION:'444f0ada8cde6179828cbb09607055e9a61f966d',
 LEGACY_SIMULATION_IMAGE:'sha256:1c227795630eb5d3a5069774031321f7aa48a47179af8345432bf1a0be6c7c60',
 LEGACY_SIMULATION_REFERENCE:'localhost/rr-c09-coordinator@sha256:fe1c89a46975500361fd530d25ba4cdf94235a8864f928fb15ba89781a886604',
 LEGACY_SIMULATION_DIGEST:'sha256:fe1c89a46975500361fd530d25ba4cdf94235a8864f928fb15ba89781a886604',
 LEGACY_COORDINATOR_IMAGE:'localhost/rr-c10-finalizer@sha256:e5f8ee3a4a533cbb201a8f6397912c29db56d808e28dadde11c0cdfacf65546d',
 LEGACY_EVIDENCE_IMAGE:'localhost/rr-c-evidence@sha256:4251a2c5de08772bd8194fac87473387f9fe1c66295b728622e18ddb1fefa148',
 LEGACY_SHARED_VOLUME:sourceVolume,ROBOTICS_RETAINED_VOLUME:retainedVolume,ROS_DOMAIN_ID:'181',GZ_PARTITION:projectName};
const compose=new ComposeExecution(ctx.jobs,{executable,socketPath:socket,projectName,cwd:root,
 files:[root+'/host/test/fixtures/legacy-live/compose.yaml',root+'/host/test/fixtures/legacy-live/evidence.yaml',root+'/host/test/fixtures/legacy-live/compose.podman.yaml'],env,timeoutMs:240000,maxBufferBytes:4194304});
await mkdir(output,{recursive:true});
const job=async(name,args)=>{const result=await compose.run(args);await writeFile(output+'/'+name+'.json',JSON.stringify(result,null,2));assert.ok(result.ok,result.diagnostic??result.stderr);return result};
const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
const before=await engine.remainingOwned(runId);
const startup='/retained/startup-'+runId;
let simulationContainerId;
try{simulationContainerId=JSON.parse(await readFile(startup+'/readiness-snapshot.json','utf8')).simulationContainerId}
catch(error){if(error.code!=='ENOENT')throw error;const names=(await readdir(startup)).filter(name=>name.endsWith('-simulation-native-metadata.json'));assert.equal(names.length,1);simulationContainerId=JSON.parse(await readFile(startup+'/'+names[0],'utf8')).container.Id}
assert.match(simulationContainerId,/^[a-f0-9]{64}$/);
const owner={runId,projectName,networkNamespaceContainerId:simulationContainerId};
const ownership=await engine.projectOwnership(owner);
await writeFile(output+'/project-ownership-before-effects.json',JSON.stringify(ownership,null,2));
assert.equal(ownership.status,'complete',JSON.stringify({missing:ownership.missing,mismatches:ownership.mismatches}));
const observer=before.containers.find(c=>c.Labels?.['com.docker.compose.service']==='acceptance-observer');
if(observer){const raw=await engine.readLogs(observer.Id,{runId,projectName},{tailLines:10000,maxBytes:1048576,deadlineMs:30000});await writeFile(output+'/observer.docker-raw',raw.bytes)}
await job('foundation-raw-logs',['logs','--no-color']);
await job('graceful-writer-drain',['stop','--timeout','30','runtime-probe-publisher','runtime-metrics','simulation-stepper','recorder','evidence-sink','otel-collector']);
await job('native-last-state',['exec','-T','simulation','robotics-entrypoint','python3','/run/robotics/input/helpers/capture-last-state.py']);
await job('retained-startup-files',['run','--rm','--no-deps','--user','10001:1000','legacy-coordinator','/opt/contracts/bin/python','/source/host/workers/legacy-live/export-startup-failure.py','--source','/run/robotics','--destination','/retained/failed-source-'+runId+'-'+attempt,'--run-id',runId]);
const target='/retained/failed-source-'+runId+'-'+attempt;
const manifest=JSON.parse(await readFile(target+'/export-manifest.json','utf8'));assert.equal(manifest.status,'complete');assert.equal(manifest.runId,runId);
for(const entry of manifest.entries){const path=target+'/'+entry.relativePath;const digest=createHash('sha256');for await(const chunk of createReadStream(path))digest.update(chunk);assert.equal(digest.digest('hex'),entry.sha256);assert.equal((await stat(path)).size,entry.size_bytes)}
await writeFile(output+'/host-verified-export.json',JSON.stringify({target,runId,entries:manifest.entries.length,hostReadAndHashesVerified:true}));
await job('actual-project-teardown',['down','--volumes','--remove-orphans']);
const actual=await engine.remainingOwned(runId);
const projectAfter=await engine.projectOwnership(owner);await writeFile(output+'/native-project-after.json',JSON.stringify(projectAfter,null,2));assert.equal(projectAfter.status,'complete');assert.equal(projectAfter.inventory.containers.length,0);assert.equal(projectAfter.inventory.networks.length,0);
await writeFile(output+'/native-empty.json',JSON.stringify(actual,null,2));
assert.equal(actual.containers.length,0);assert.equal(actual.networks.length,0);assert.ok(actual.volumes.Volumes===null||actual.volumes.Volumes?.length===0);
await ctx.fiber.dispose();console.log(JSON.stringify({passed:true,runId,scope:'failed joint run diagnostic export before physical cleanup; no qualification PASS'}));
