import {writeFile,mkdir} from 'node:fs/promises';
import {ComposeExecution,EngineMetadata} from '../dist/src/index.js';
const [root,corePath,socket,output,overlay]=process.argv.slice(2);
const {Context,Jobs}=await import(corePath);
const ctx=new Context();
const fiber=ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:4*1024*1024});
await fiber.await();
const runId='rr-c08-'+Date.now();
const projectName=runId;
const compose=new ComposeExecution(ctx.jobs,{executable:root+'/host/.tools/docker-compose',socketPath:socket,projectName,files:[root+'/compose.host-storage.yaml',...(overlay?[root+'/'+overlay]:[])],cwd:root,env:{ROBOTICS_RUN_ID:runId},timeoutMs:120000});
await mkdir(output,{recursive:true});
let status='failed';
try {
  await compose.requireVersion();
  const engine=await EngineMetadata.connect({socketPath:socket,clientMinApi:'1.24',clientMaxApi:'1.53'});
  await writeFile(output+'/engine.json',JSON.stringify(engine.facts,null,2)+'\n');
  const up=await compose.run(['up','--detach','--no-build','storage-host']);
  await writeFile(output+'/up.json',JSON.stringify(up,null,2)+'\n');
  if(!up.ok) throw new Error(up.diagnostic ?? up.stderr);
  for(const [name,user,readOnly] of [['storage-worker','10001:1000',true],['storage-host','1000:1000',false]]) {
    const id=await compose.run(['ps','--all','--quiet',name]);
    if(!id.ok) throw new Error(id.diagnostic);
    const observation=await engine.inspect(id.stdout.trim(),{runId,projectName,user,imageDigest:'docker.io/library/node@sha256:b64fccfbcd1ae10d11b969a868b50e1c2530a7054813d5cdea04ac3bce551697',mounts:[{destination:'/run/robotics',readOnly:false,volumeName:runId+'-data'},{destination:'/run/robotics/input',readOnly,volumeName:runId+'-input'}],hostConfig:{Memory:268435456,ReadonlyRootfs:true}});
    await writeFile(output+'/'+name+'.json',JSON.stringify(observation,null,2)+'\n');
    if(observation.status!=='complete') throw new Error(name+' metadata incomplete: '+JSON.stringify({missing:observation.missing,mismatches:observation.mismatches}));
  }
  const logs=await compose.run(['logs','--no-color']);
  await writeFile(output+'/logs.json',JSON.stringify(logs,null,2)+'\n');
  if(!logs.ok || !logs.stdout.includes('"exactBytes":true')) throw new Error('native storage result not proved');
  const line=logs.stdout.split('\n').find(l => l.includes('"exactBytes":true'));
  const envelope=JSON.parse(line.slice(line.indexOf('{')));
  await writeFile(output+'/exact.json',Buffer.from(envelope.payloadBase64,'base64'));
  status='passed';
} finally {
  const logs=await compose.run(['logs','--no-color']);
  await writeFile(output+'/final-logs.json',JSON.stringify(logs,null,2)+'\n');
  const down=await compose.run(['down','--volumes']);
  await writeFile(output+'/cleanup.json',JSON.stringify(down,null,2)+'\n');
  const cleanupEngine=await EngineMetadata.connect({socketPath:socket,clientMinApi:'1.24',clientMaxApi:'1.53'});
  const remaining=await cleanupEngine.remainingOwned(runId);
  await writeFile(output+'/remaining-owned.json',JSON.stringify(remaining,null,2)+'\n');
  const cleanup=down.ok && remaining.containers.length===0 && remaining.networks.length===0 && Object.hasOwn(remaining.volumes,'Volumes') && (remaining.volumes.Volumes===null || (Array.isArray(remaining.volumes.Volumes) && remaining.volumes.Volumes.length===0));
  await writeFile(output+'/result.json',JSON.stringify({status:status==='passed' && cleanup ? 'passed' : 'failed',measurementStatus:status,cleanup,runId,scope:'Engine metadata and Node OCI storage fixture; Python worker entrypoints and Docker CI remain separate gates'},null,2)+'\n');
  await fiber.dispose();
  if(!cleanup) throw new Error('actual cleanup failed');
}
console.log(JSON.stringify({status,runId}));
