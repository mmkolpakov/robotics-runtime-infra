import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,rm,lstat,chmod} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {randomUUID,createHash} from 'node:crypto';
import {pathToFileURL,fileURLToPath} from 'node:url';
import {Context,Jobs,referenceFile} from '@robotics-runtime/host';
import {ComposeExecution,EngineMetadata,createLocalAttempt,loadLocalAttempt,observeCoordinator,recoverLocalAttempt} from '../dist/src/index.js';
const [destination]=process.argv.slice(2);assert.ok(destination,'explicit private report directory required');
const root=await mkdtemp(join(tmpdir(),'rr-local-recovery-native-')),scope='rr-recovery-'+randomUUID();
const repo=resolve(fileURLToPath(new URL('../../',import.meta.url))),composeExecutable=join(repo,'host/.tools/compose');
const image='node:24.21.0-trixie-slim@sha256:b64fccfbcd1ae10d11b969a868b50e1c2530a7054813d5cdea04ac3bce551697';
const units=[],projects=[],foreign=[];let apiUnit;
const report={scope:'isolated source Linux/systemd/Podman process and byte-retention controls; no simulator or robot qualification',steps:[]};
const command=(executable,args)=>{const p=spawnSync(executable,args,{encoding:'utf8',timeout:15000,maxBuffer:1048576});assert.equal(p.status,0,p.stderr);return p.stdout.trim()};
const podman=args=>command('/usr/bin/podman',args),systemctl=args=>command('/usr/bin/systemctl',['--user',...args]);
const ctx=new Context();await ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:1048576,killTimeoutMs:2000}).await();
const socket=join(root,'engine.sock'),output=resolve(destination);await mkdir(output,{recursive:true,mode:0o700});
try{
 apiUnit=scope+'-api.service';
 command('/usr/bin/systemd-run',['--user','--unit='+apiUnit,'--property=Type=exec','--property=RuntimeMaxSec=240','--property=TimeoutStopSec=2','--property=KillMode=control-group','/usr/bin/podman','system','service','--time=0','unix://'+socket]);
 for(let n=0;n<100;n++){try{assert.ok((await lstat(socket)).isSocket());break}catch{await new Promise(r=>setTimeout(r,50))}}
 const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
 const rawImageId=JSON.parse(podman(['image','inspect',image]))[0].Id,imageId=rawImageId.startsWith('sha256:')?rawImageId:'sha256:'+rawImageId;
 const worker=join(repo,'host/workers/legacy-finalization/export_retained.py');
 const fixture=async(name,volumeOnly=false)=>{
  const area=join(root,name);await mkdir(area,{mode:0o700});
  const runId='run-'+randomUUID(),projectName='rr-r-'+randomUUID().slice(0,12),unit='rr-attempt-'+randomUUID()+'.service';units.push(unit);
  const source=join(area,'source');await mkdir(source);const raw=Buffer.from('retained '+name+' bytes\n');await writeFile(join(source,'diagnostic.txt'),raw);
  const target=join(area,'retained'),exportPlan=join(area,'export-plan.json');
  await writeFile(exportPlan,JSON.stringify({version:1,runId,sourceRoot:source,destinationRoot:target,maximumBytes:1048576,
   entries:[{name:'diagnostic',source:'diagnostic.txt',relativePath:'diagnostic.txt',sha256:createHash('sha256').update(raw).digest('hex'),size_bytes:raw.length}]}));
  const composeFile=join(area,'compose.yaml');
  await writeFile(composeFile,'services:\n  worker:\n    image: '+image+'\n    user: "1000:1000"\n    read_only: true\n    network_mode: none\n    cap_drop: [ALL]\n    security_opt: [no-new-privileges:true]\n    labels:\n      org.robotics.runtime.run-id: '+runId+'\n    command: [node, -e, "process.on(\\"SIGTERM\\",()=>{});setInterval(()=>{},1000)"]\n'+(volumeOnly?'volumes:\n  protected:\n    name: '+projectName+'-protected\n    labels:\n      org.robotics.runtime.run-id: '+runId+'\n':''));
  const options={executable:composeExecutable,socketPath:socket,projectName,files:[composeFile],cwd:area,timeoutMs:20000,maxBufferBytes:1048576};
  const compose=new ComposeExecution(ctx.jobs,options);projects.push({compose,runId,projectName});
  command('/usr/bin/systemd-run',['--user','--unit='+unit,'--property=Type=exec','--property=RuntimeMaxSec=120','--property=TimeoutStopSec=1','--property=KillMode=control-group','--property=Restart=no',process.execPath,'-e','process.on("SIGTERM",()=>{});setInterval(()=>{},1000)']);
  const invocationId=systemctl(['show',unit,'--property=InvocationID','--value']);assert.match(invocationId,/^[a-f0-9]{32}$/);
  const attempt=await createLocalAttempt(join(area,'attempt.json'),{runId,projectName,targetEnvironment:'simulation',coordinator:{unit,invocationId},
   admissionRefs:[await referenceFile(composeFile),await referenceFile(worker)]},{jobs:ctx.jobs,busctl:'/usr/bin/busctl'});
  assert.equal((await compose.run(['up','--detach','--no-build'])).ok,true);
  const native=await engine.projectOwnership({runId,projectName});assert.equal(native.containerDetails.length,1);
  const id=native.containerDetails[0].Id;
  const capabilities=podman(['exec',id,'node','-e','console.log(require("fs").readFileSync("/proc/self/status","utf8").split("\\n").filter(line=>/^Cap(?:Eff|Bnd):/.test(line)).join("\\n"))']);
  assert.match(capabilities,/^CapEff:\s+0+\s*$/m);assert.match(capabilities,/^CapBnd:\s+0+\s*$/m);
  const requirement={runId,projectName,imageId,user:'1000:1000',mounts:[],hostConfig:{ReadonlyRootfs:true}};
  const plan={attempt,busctl:'/usr/bin/busctl',compose:options,requirements:{worker:requirement},exportReceiptPath:join(area,'export.json'),deadlineMs:30000,
   exportRequest:{executable:'/usr/bin/python3',args:[worker,'--plan',exportPlan],cwd:area,timeoutMs:10000,maxBufferBytes:1048576,extendEnv:false,env:{PATH:'/usr/bin:/bin'}},
   exportRefs:[{uri:pathToFileURL(join(target,'diagnostic.txt')).href,sha256:createHash('sha256').update(raw).digest('hex'),size_bytes:raw.length}]};
  return {area,unit,runId,projectName,compose,attempt,plan,raw,source,target,capabilities};
 };
 const kill=async f=>{
  systemctl(['kill','--kill-whom=main','--signal=KILL',f.unit]);
  const attempt=await loadLocalAttempt(f.attempt);let observed;
  for(let n=0;n<100;n++){observed=await observeCoordinator(ctx.jobs,'/usr/bin/busctl',attempt.coordinator);if(observed.status==='quiescent')break;await new Promise(r=>setTimeout(r,50))}
  assert.equal(observed.status,'quiescent');return observed;
 };
 const completed=await fixture('killed-coordinator');
 const active=await recoverLocalAttempt(ctx.jobs,completed.plan);assert.equal(active.resources,'retained');assert.match(active.diagnostic,/coordinator/);
 await assert.rejects(readFile(join(completed.target,'diagnostic.txt')),{code:'ENOENT'});
 const os=await kill(completed);assert.equal(os.runtimeMaxUs,120000000);assert.equal(os.timeoutStopUs,1000000);
 const before=await engine.remainingOwned(completed.runId);assert.equal(before.containers.length,1);
 const recovered=await recoverLocalAttempt(ctx.jobs,completed.plan);assert.equal(recovered.resources,'released',JSON.stringify(recovered));
 for(const key of ['nativeFinalState','robotStop','cancellation'])assert.equal(recovered[key],'unknown');
 assert.deepEqual(await readFile(join(completed.target,'diagnostic.txt')),completed.raw);
 const originalReceipt=await readFile(completed.plan.exportReceiptPath);
 const repeated=await recoverLocalAttempt(ctx.jobs,{...completed.plan,exportRequest:{...completed.plan.exportRequest,executable:'/definitely/not/executed'}});
 assert.equal(repeated.resources,'released',JSON.stringify(repeated));assert.deepEqual(await readFile(completed.plan.exportReceiptPath),originalReceipt);
 await writeFile(join(output,'retained-diagnostic.txt'),await readFile(join(completed.target,'diagnostic.txt')),{mode:0o400});
 await writeFile(join(output,'export-receipt.json'),originalReceipt,{mode:0o400});
 report.steps.push({name:'killed-coordinator-engine-container-outside-cgroup-retention-before-down-and-repeat',passed:true,coordinator:os,containerSurvivedCoordinator:true,capabilities:completed.capabilities,outcome:recovered,repeated});
 const attemptInput=join(completed.area,'attempt-reference.json'),operatorInput=join(completed.area,'operator-plan.json'),lock=join(completed.area,'recovery.lock');
 await writeFile(attemptInput,JSON.stringify(completed.attempt),{mode:0o600});await writeFile(operatorInput,JSON.stringify({...completed.plan,exportRequest:{...completed.plan.exportRequest,executable:'/definitely/not/executed'}}),{mode:0o600});
 const cli=await ctx.jobs.run({executable:'/usr/bin/flock',args:['--nonblock','--conflict-exit-code','75',lock,process.execPath,join(repo,'host/tools/recover-local-attempt.mjs'),attemptInput,operatorInput],timeoutMs:15000,maxBufferBytes:1048576});
 assert.equal(cli.ok,true,cli.stderr);assert.equal(JSON.parse(cli.stdout).resources,'released');
 const holder=scope+'-lock.service',marker=join(completed.area,'locked');units.push(holder);
 command('/usr/bin/systemd-run',['--user','--unit='+holder,'--property=Type=exec','--property=RuntimeMaxSec=10','--property=TimeoutStopSec=1','--property=KillMode=control-group','/usr/bin/flock',lock,process.execPath,'-e','require("fs").writeFileSync('+JSON.stringify(marker)+',"held");setInterval(()=>{},1000)']);
 for(let n=0;n<100;n++){try{await readFile(marker);break}catch{await new Promise(r=>setTimeout(r,20))}}
 const conflict=await ctx.jobs.run({executable:'/usr/bin/flock',args:['--nonblock','--conflict-exit-code','75',lock,process.execPath,join(repo,'host/tools/recover-local-attempt.mjs'),attemptInput,operatorInput],timeoutMs:5000,maxBufferBytes:1048576});assert.equal(conflict.exitCode,75);systemctl(['stop',holder]);units.splice(units.indexOf(holder),1);
 report.steps.push({name:'actual-operator-CLI-and-flock-exclude-concurrent-recovery',passed:true,cli,conflict});
 for(const mode of [0o644,0o444]){await chmod(completed.plan.exportReceiptPath,mode);const permission=await recoverLocalAttempt(ctx.jobs,completed.plan);assert.equal(permission.resources,'retained');assert.match(permission.diagnostic,/private immutable/)}await chmod(completed.plan.exportReceiptPath,0o400);
 report.steps.push({name:'foreign-readable-export-receipts-0644-and-0444-refused',passed:true});


 const refused=await fixture('export-refusal');await kill(refused);
 const bad={...refused.plan,exportRequest:{...refused.plan.exportRequest,executable:'/usr/bin/false',args:[]}};
 const failed=await recoverLocalAttempt(ctx.jobs,bad);assert.equal(failed.resources,'retained');assert.match(failed.diagnostic,/export/);assert.equal((await engine.remainingOwned(refused.runId)).containers.length,1);
 const prior=await readFile(refused.plan.exportReceiptPath);const retry=await recoverLocalAttempt(ctx.jobs,refused.plan);
 assert.equal(retry.resources,'retained');assert.deepEqual(await readFile(refused.plan.exportReceiptPath),prior);assert.deepEqual(await readFile(join(refused.source,'diagnostic.txt')),refused.raw);
 report.steps.push({name:'failed-export-blocks-cleanup-and-same-receipt-replay',passed:true,outcome:failed,retry});
 const hanging=await fixture('export-timeout');await kill(hanging);
 const hung=await recoverLocalAttempt(ctx.jobs,{...hanging.plan,exportRequest:{...hanging.plan.exportRequest,executable:process.execPath,args:['-e','process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'],timeoutMs:300}});
 assert.equal(hung.resources,'retained');assert.ok(hung.observations.some(value=>value.export?.timedOut===true));assert.equal((await engine.remainingOwned(hanging.runId)).containers.length,1);
 report.steps.push({name:'hanging-export-worker-is-settled-by-existing-Jobs-without-cleanup',passed:true,outcome:hung});


 const shared=await fixture('foreign-resource');await kill(shared);
 const foreignId=podman(['run','--detach','--name',scope+'-foreign','--network=none','--label','org.robotics.runtime.fixture='+scope,'--label','com.docker.compose.project='+shared.projectName,'--label','org.robotics.runtime.run-id=foreign','--label','com.docker.compose.service=worker',image,'sleep','120']);foreign.push(foreignId);
 const denied=await recoverLocalAttempt(ctx.jobs,shared.plan);assert.equal(denied.resources,'retained');assert.match(denied.diagnostic,/ownership/);
 assert.equal((await engine.remainingOwned(shared.runId)).containers.length,1);assert.equal(JSON.parse(podman(['inspect',foreignId]))[0].State.Running,true);
 report.steps.push({name:'same-project-foreign-container-refuses-before-export-or-cleanup',passed:true,outcome:denied});
 const volumeOnly=await fixture('unattached-owned-volume',true);await kill(volumeOnly);assert.equal((await volumeOnly.compose.run(['down','--remove-orphans','--timeout','2'])).ok,true);
 const volumeName=volumeOnly.projectName+'-protected';podman(['volume','create','--label','com.docker.compose.project='+volumeOnly.projectName,'--label','com.docker.compose.volume=protected','--label','org.robotics.runtime.run-id='+volumeOnly.runId,volumeName]);
 const volume=JSON.parse(podman(['volume','inspect',volumeName]))[0],protectedPath=join(volume.Mountpoint,'protected.txt');await writeFile(protectedPath,'protected unmounted bytes',{mode:0o400});
 const protectedRef=await referenceFile(protectedPath),attemptRecord=await loadLocalAttempt(volumeOnly.attempt);
 await writeFile(volumeOnly.plan.exportReceiptPath,JSON.stringify({attemptId:attemptRecord.attemptId,status:'complete',refs:[protectedRef]}),{mode:0o400});
 const noContainers=await engine.projectOwnership({runId:volumeOnly.runId,projectName:volumeOnly.projectName});assert.equal(noContainers.inventory.containers.length,0);assert.equal(noContainers.inventory.volumes.Volumes.length,1);
 const protection=await recoverLocalAttempt(ctx.jobs,{...volumeOnly.plan,exportRefs:[protectedRef]});assert.equal(protection.resources,'retained');assert.match(protection.diagnostic,/removed Engine volume/);
 assert.equal(JSON.parse(podman(['volume','inspect',volumeName]))[0].Name,volumeName);assert.equal(await readFile(protectedPath,'utf8'),'protected unmounted bytes');assert.ok(!protection.observations.some(value=>value.cleanup));
 await writeFile(join(output,'protected-unattached-volume.txt'),await readFile(protectedPath),{mode:0o400});
 report.steps.push({name:'unattached-owned-named-volume-protects-data-with-zero-containers-and-no-down',passed:true,outcome:protection});


 const runtimeUnit='rr-attempt-'+randomUUID()+'.service';units.push(runtimeUnit);
 command('/usr/bin/systemd-run',['--user','--unit='+runtimeUnit,'--property=Type=exec','--property=RuntimeMaxSec=2','--property=TimeoutStopSec=1','--property=KillMode=control-group','--property=Restart=no',process.execPath,'-e','process.on("SIGTERM",()=>{});setInterval(()=>{},1000)']);
 const identity={unit:runtimeUnit,invocationId:systemctl(['show',runtimeUnit,'--property=InvocationID','--value'])};let state;
 for(let n=0;n<100;n++){state=await observeCoordinator(ctx.jobs,'/usr/bin/busctl',identity);if(state.status==='quiescent')break;await new Promise(r=>setTimeout(r,100))}
 assert.equal(state.status,'quiescent');assert.equal(state.runtimeMaxUs,2000000);assert.equal(systemctl(['show',runtimeUnit,'--property=Result','--value']),'timeout');
 const missing=await observeCoordinator(ctx.jobs,'/usr/bin/busctl',{unit:'rr-attempt-'+randomUUID()+'.service',invocationId:'11'.repeat(16)});assert.equal(missing.status,'unknown');
 report.steps.push({name:'ready-systemd-runtime-and-stop-bound-kill-hanging-process-missing-unit-unknown',passed:true,observed:state,absent:missing});report.passed=true;
}catch(error){report.passed=false;report.error=String(error);process.exitCode=1}
finally{
 for(const id of foreign){try{const actual=JSON.parse(podman(['inspect',id]))[0];assert.equal(actual.Config.Labels['org.robotics.runtime.fixture'],scope);podman(['rm','--force',id])}catch(error){report.cleanupError=String(error)}}
 for(const {compose,runId,projectName}of projects){try{const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'}),own=await engine.projectOwnership({runId,projectName});assert.equal(own.status,'complete');const result=await compose.run(['down','--volumes','--remove-orphans','--timeout','2']);assert.equal(result.ok,true)}catch(error){report.cleanupError=String(error)}}
 for(const name of [...units,...(apiUnit?[apiUnit]:[])]){try{systemctl(['stop',name]);spawnSync('/usr/bin/systemctl',['--user','reset-failed',name],{encoding:'utf8',timeout:5000})}catch(error){report.cleanupError=String(error)}}
 await ctx.fiber.dispose();if(report.cleanupError){report.passed=false;process.exitCode=1}
 await writeFile(join(output,'local-recovery.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
 assert.equal(root.startsWith(tmpdir()+'/rr-local-recovery-native-'),true);await rm(root,{recursive:true,force:true});
 console.log(JSON.stringify({passed:report.passed,error:report.error,cleanupError:report.cleanupError,steps:report.steps.map(step=>step.name)}));
}
