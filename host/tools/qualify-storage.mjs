import {createHash} from 'node:crypto';
import {writeFile,mkdir,readFile} from 'node:fs/promises';
import {ComposeExecution,EngineMetadata} from '../dist/src/index.js';
const [root,corePath,socket,output,overlay,rawHostImage]=process.argv.slice(2);
const hostImage=rawHostImage?(rawHostImage.startsWith('sha256:')?rawHostImage:'sha256:'+rawHostImage):undefined;
const {Context,Jobs}=await import(corePath);
const ctx=new Context();
const fiber=ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:4*1024*1024});
await fiber.await();
const runId='rr-c08-'+Date.now();
const projectName=runId;
const initSha=hostImage?createHash('sha256').update(await readFile(root+'/host/.tools/oci-init/catatonit')).digest('hex'):undefined;
const compose=new ComposeExecution(ctx.jobs,{executable:root+'/host/.tools/docker-compose',socketPath:socket,projectName,files:[root+'/compose.host-storage.yaml',...(overlay?[root+'/'+overlay]:[])],profiles:hostImage?['host-preflight']:[],cwd:root,env:{ROBOTICS_RUN_ID:runId,...(hostImage?{HOST_IMAGE:hostImage,ROBOTICS_EXPECTED_INIT_SHA256:initSha,ROBOTICS_ENGINE_HOST_SOCKET:socket,ROBOTICS_ENGINE_ROOTLESS_UID:String(process.getuid()),ROBOTICS_ENGINE_ROOTLESS_GID:String(process.getgid())}:{})},timeoutMs:120000});
await mkdir(output,{recursive:true});
let status='failed';
try {
  await compose.requireVersion();
  const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
  await writeFile(output+'/engine.json',JSON.stringify(engine.facts,null,2)+'\n');
  const up=await compose.run(['up','--detach','--no-build',hostImage?'host-image':'storage-host']);
  await writeFile(output+'/up.json',JSON.stringify(up,null,2)+'\n');
  if(!up.ok) throw new Error(up.diagnostic ?? up.stderr);
  for(const [name,user,readOnly] of [['storage-worker','10001:1000',true],['storage-host','1000:1000',false]]) {
    const id=await compose.run(['ps','--all','--quiet',name]);
    if(!id.ok) throw new Error(id.diagnostic);
    const observation=await engine.inspect(id.stdout.trim(),{runId,projectName,user,imageDigest:'docker.io/library/node@sha256:b64fccfbcd1ae10d11b969a868b50e1c2530a7054813d5cdea04ac3bce551697',mounts:[{destination:'/run/robotics',readOnly:false,volumeName:runId+'-data'},{destination:'/run/robotics/input',readOnly,volumeName:runId+'-input'}],hostConfig:{Memory:268435456,ReadonlyRootfs:true,NetworkMode:'none',Privileged:false,...(name==='storage-host'?{Init:true}:{}),...(overlay ? {UsernsMode:'private',CapDrop:['CHOWN','DAC_OVERRIDE','FOWNER','FSETID','KILL','NET_BIND_SERVICE','SETFCAP','SETGID','SETPCAP','SETUID','SYS_CHROOT'],SecurityOpt:['no-new-privileges']} : {CapDrop:['ALL'],SecurityOpt:['no-new-privileges:true']})}});
    await writeFile(output+'/'+name+'.json',JSON.stringify(observation,null,2)+'\n');
    if(observation.status!=='complete') throw new Error(name+' metadata incomplete: '+JSON.stringify({missing:observation.missing,mismatches:observation.mismatches}));
  }
  if(hostImage) {
    const wait=await compose.run(['wait','host-image']);
    await writeFile(output+'/wait-host-image.json',JSON.stringify(wait,null,2)+'\n');
    if(!wait.ok) throw new Error('native host preflight did not exit successfully: '+wait.diagnostic);
    const id=await compose.run(['ps','--all','--quiet','host-image']);
    const observation=await engine.inspect(id.stdout.trim(),{runId,projectName,user:'1000:1000',mounts:[{destination:'/run/robotics',readOnly:false,volumeName:runId+'-data'},{destination:'/run/robotics/input',readOnly:false,volumeName:runId+'-input'}],hostConfig:{Memory:268435456,ReadonlyRootfs:true,NetworkMode:'none',Privileged:false,Init:true,UsernsMode:'private',CapDrop:['CHOWN','DAC_OVERRIDE','FOWNER','FSETID','KILL','NET_BIND_SERVICE','SETFCAP','SETGID','SETPCAP','SETUID','SYS_CHROOT'],SecurityOpt:['no-new-privileges']}});
    await writeFile(output+'/host-image.json',JSON.stringify(observation,null,2)+'\n');
    if(observation.status!=='complete'||observation.container.Image!==hostImage||observation.container.State.ExitCode!==0) throw new Error('actual Compose host image or namespace/socket preflight failed');
  }
  const logs=await compose.run(['logs','--no-color']);
  await writeFile(output+'/logs.json',JSON.stringify(logs,null,2)+'\n');
  if(!logs.ok || !logs.stdout.includes('"exactBytes":true')) throw new Error('native storage result not proved');
  const line=logs.stdout.split('\n').find(l => l.includes('"exactBytes":true'));
  const envelope=JSON.parse(line.slice(line.indexOf('{')));
  const innerMap=(text,inside)=>{for(const l of text.trim().split('\n')) {const [a,b,n]=l.trim().split(/\s+/).map(Number);if(a<=inside && inside<a+n)return b+inside-a} throw new Error('native child mapping absent')};
  const parentMaps=overlay?await engine.rootlessParentMaps():undefined;
  if(parentMaps) await writeFile(output+'/native-parent-maps.json',JSON.stringify(parentMaps,null,2)+'\n');
  const parentMap=(rows,inside)=>{const row=rows.find(r=>r.container_id<=inside && inside<r.container_id+r.size);if(!row)throw new Error('native parent mapping absent');return row.host_id+inside-row.container_id};
  for(const native of [envelope,envelope.worker]) {
    if(!native.namespace.capabilities.every(l=>/:\s+0+$/.test(l))) throw new Error('native capability set is not empty');
    if(parentMaps && (parentMap(parentMaps.uidMap,innerMap(native.namespace.uidMap,1000))!==process.getuid() || parentMap(parentMaps.gidMap,innerMap(native.namespace.gidMap,1000))!==process.getgid())) throw new Error('native child -> parent -> HOME mapping mismatch');
  }
  await writeFile(output+'/exact.json',Buffer.from(envelope.payloadBase64,'base64'));
  if(hostImage) {
    const nativeLine=logs.stdout.split('\n').find(l=>l.includes('"kind":"host-image-native"'));
    if(!nativeLine) throw new Error('host image native proof absent');
    const hostProof=JSON.parse(nativeLine.slice(nativeLine.indexOf('{')));
    if(parentMap(parentMaps.uidMap,innerMap(hostProof.uidMap,1000))!==process.getuid() || parentMap(parentMaps.gidMap,innerMap(hostProof.gidMap,1000))!==process.getgid()) throw new Error('native host namespace chain mismatch');
    await writeFile(output+'/host-image-proof.json',JSON.stringify(hostProof,null,2)+'\n');
  }
  status='passed';
} finally {
  const logs=await compose.run(['logs','--no-color']);
  await writeFile(output+'/final-logs.json',JSON.stringify(logs,null,2)+'\n');
  const down=await compose.run(['down','--volumes']);
  await writeFile(output+'/cleanup.json',JSON.stringify(down,null,2)+'\n');
  const cleanupEngine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
  const remaining=await cleanupEngine.remainingOwned(runId);
  await writeFile(output+'/remaining-owned.json',JSON.stringify(remaining,null,2)+'\n');
  const cleanup=down.ok && remaining.containers.length===0 && remaining.networks.length===0 && Object.hasOwn(remaining.volumes,'Volumes') && (remaining.volumes.Volumes===null || (Array.isArray(remaining.volumes.Volumes) && remaining.volumes.Volumes.length===0));
  await writeFile(output+'/result.json',JSON.stringify({status:status==='passed' && cleanup ? 'passed' : 'failed',measurementStatus:status,cleanup,runId,scope:'Engine metadata and Node OCI storage fixture; Python worker entrypoints and Docker CI remain separate gates'},null,2)+'\n');
  await fiber.dispose();
  if(!cleanup) throw new Error('actual cleanup failed');
}
console.log(JSON.stringify({status,runId}));
