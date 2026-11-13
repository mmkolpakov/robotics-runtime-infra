import {open,realpath,lstat} from 'node:fs/promises';
import {constants} from 'node:fs';
import {dirname,isAbsolute} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {referenceFile,type ArtifactRef} from '@robotics-runtime/host';
import {ComposeExecution,type ComposeOptions,type FiniteJobs,type FiniteJobRequest} from './compose-execution.js';
import {EngineMetadata,type ContainerRequirement} from './engine-metadata.js';
import {loadLocalAttempt,observeCoordinator,verifyAttemptInputs} from './local-attempt.js';
export interface LocalRecoveryPlan {
 attempt:ArtifactRef;busctl:string;compose:ComposeOptions;requirements:Readonly<Record<string,ContainerRequirement>>;
 networkNamespaceContainerId?:string;exportRequest:FiniteJobRequest;exportRefs:readonly ArtifactRef[];
 exportReceiptPath:string;deadlineMs:number;
}
export interface LocalRecoveryOutcome {
 resources:'released'|'retained';nativeFinalState:'unknown';robotStop:'unknown';cancellation:'unknown';
 evidenceRefs:readonly ArtifactRef[];observations:readonly unknown[];diagnostic?:string;
}
const object=(value:unknown):Record<string,unknown>=>{
 if(!value||typeof value!=='object'||Array.isArray(value))throw new Error('recovery metadata must be an object');return value as Record<string,unknown>;
};
async function retained(refs:readonly ArtifactRef[]):Promise<'present'|'absent'> {
 if(!refs.length||refs.length>4096)throw new Error('finite nonempty retained inventory required');
 let present=0;
 for(const expected of refs){
  if(!Number.isSafeInteger(expected.size_bytes)||expected.size_bytes<0||expected.size_bytes>1024**4)throw new Error('invalid retained byte bound');
  const path=fileURLToPath(expected.uri);let facts;
  try{facts=await lstat(path)}catch(error){if((error as NodeJS.ErrnoException).code==='ENOENT')continue;throw error}
  if(!facts.isFile()||await realpath(path)!==path)throw new Error('retained output must be canonical regular bytes');
  const actual=await referenceFile(path,{maxBytes:Math.max(1,expected.size_bytes)});
  if(actual.sha256!==expected.sha256||actual.size_bytes!==expected.size_bytes)throw new Error('retained output differs from admitted source identity');present++;
 }
 if(present!==0&&present!==refs.length)throw new Error('partial retained inventory cannot authorize cleanup');
 return present?'present':'absent';
}
/** Invoke under a finite user systemd unit and an operator-owned flock. Never starts an action. */
export async function recoverLocalAttempt(jobs:FiniteJobs,plan:LocalRecoveryPlan):Promise<LocalRecoveryOutcome>{
 const externalCancel=plan.exportRequest.cancelSignal;
 plan=structuredClone({...plan,exportRequest:{...plan.exportRequest,cancelSignal:undefined}});
 const refs:ArtifactRef[]=[],observations:unknown[]=[];
 const outcome=(resources:'released'|'retained',diagnostic?:string):LocalRecoveryOutcome=>({resources,nativeFinalState:'unknown',robotStop:'unknown',cancellation:'unknown',evidenceRefs:refs,observations,...(diagnostic?{diagnostic}:{})});
 if(!Number.isSafeInteger(plan.deadlineMs)||plan.deadlineMs<1||plan.deadlineMs>120000)throw new Error('invalid finite recovery bound');
 const deadline=AbortSignal.timeout(plan.deadlineMs),signal=externalCancel?AbortSignal.any([deadline,externalCancel]):deadline;
 try{
  const attempt=await loadLocalAttempt(plan.attempt);refs.push(plan.attempt);
  if(plan.compose.projectName!==attempt.projectName)throw new Error('recovery Compose project differs from admitted attempt');
  if(!isAbsolute(plan.exportReceiptPath)||await realpath(dirname(plan.exportReceiptPath))!==dirname(plan.exportReceiptPath))throw new Error('canonical export receipt directory required');
  const parent=await lstat(dirname(plan.exportReceiptPath));if(!parent.isDirectory()||(parent.mode&0o022))throw new Error('export receipt directory must deny foreign writes');
  for(const file of plan.compose.files)if(!attempt.admissionRefs.some(ref=>ref.uri===pathToFileURL(file).href))throw new Error('Compose file has no recorded admission identity');
  await verifyAttemptInputs(attempt.admissionRefs);
  const coordinator=await observeCoordinator(jobs,plan.busctl,attempt.coordinator,signal);observations.push({coordinator});
  if(coordinator.status!=='quiescent')throw new Error('coordinator is active or its exact invocation cannot be observed');
  const engine=await EngineMetadata.connect({socketPath:plan.compose.socketPath,operationMinApi:'1.24',operationMaxApi:'1.53'},{cancelSignal:signal,deadlineMs:plan.deadlineMs});
  const owner={runId:attempt.runId,projectName:attempt.projectName,...(plan.networkNamespaceContainerId?{networkNamespaceContainerId:plan.networkNamespaceContainerId}:{})};
  const ownership=async()=>{
   const observed=await engine.projectOwnership(owner,{cancelSignal:signal,deadlineMs:plan.deadlineMs});
   const protectedPaths=[...attempt.admissionRefs,...plan.exportRefs,plan.attempt].map(ref=>fileURLToPath(ref.uri)).concat(plan.exportReceiptPath);
   const protect=(mountpoint:unknown)=>{
    if(typeof mountpoint!=='string'||!isAbsolute(mountpoint))throw new Error('native owned volume mountpoint is incomplete');
    if(protectedPaths.some(path=>path===mountpoint||path.startsWith(mountpoint.replace(/\/$/,'')+'/')))throw new Error('retained/control files cannot live inside a removed Engine volume');
   };
   const volumes=object(observed.inventory.volumes).Volumes;
   if(volumes!==null&&!Array.isArray(volumes))throw new Error('native owned volume inventory is incomplete');
   for(const volume of Array.isArray(volumes)?volumes:[])protect(object(volume).Mountpoint);

   observations.push({project:owner.projectName,status:observed.status,missing:observed.missing,mismatches:observed.mismatches,containers:observed.containerDetails.map(value=>object(value).Id),clientApi:observed.engine.clientApi});
   if(observed.status!=='complete')throw new Error('recovery refuses foreign or incomplete project ownership');
   for(const raw of observed.containerDetails){
    const container=object(raw),labels=object(object(container.Config).Labels),service=labels['com.docker.compose.service'];
    if(typeof service!=='string'||!plan.requirements[service])throw new Error('resource has no freshly admitted service requirement');
    const requirement=plan.requirements[service]!;
    if(requirement.runId!==attempt.runId||requirement.projectName!==attempt.projectName)throw new Error('native requirement belongs to another attempt');
    const actual=await engine.inspect(String(container.Id),requirement,{cancelSignal:signal,deadlineMs:plan.deadlineMs});
    observations.push({nativeResource:container.Id,status:actual.status,missing:actual.missing,mismatches:actual.mismatches});
    if(actual.status!=='complete')throw new Error('native resource differs from freshly admitted requirement');
    for(const mount of Array.isArray(container.Mounts)?container.Mounts:[]){
     const value=object(mount);if(value.Type==='volume')protect(value.Source);
    }
   }
   return observed;
  };
  const before=await ownership();
  let receipt:Record<string,unknown>|undefined;
  try{
   const file=await open(plan.exportReceiptPath,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);try{
    const before=await file.stat({bigint:true});if(!before.isFile()||before.size>65536n||(before.mode&0o222n)||(before.mode&0o077n))throw new Error('private immutable bounded export receipt required');
    const bytes=Buffer.alloc(Number(before.size)+1);let position=0;while(position<bytes.length){const read=await file.read(bytes,position,bytes.length-position,position);if(!read.bytesRead)break;position+=read.bytesRead}
    const after=await file.stat({bigint:true}),named=await lstat(plan.exportReceiptPath,{bigint:true});
    if(position!==Number(before.size)||['dev','ino','size','mtimeNs','ctimeNs'].some(key=>before[key as keyof typeof before]!==after[key as keyof typeof after]||before[key as keyof typeof before]!==named[key as keyof typeof named]))throw new Error('export receipt changed during capture');
    receipt=object(JSON.parse(bytes.subarray(0,position).toString('utf8')));
   }finally{await file.close()}
  }catch(error){if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error}
  if(receipt){
   if(receipt.attemptId!==attempt.attemptId||receipt.status!=='complete'||JSON.stringify(receipt.refs)!==JSON.stringify(plan.exportRefs))throw new Error('prior export incomplete or belongs to different retained inputs');
   if(await retained(plan.exportRefs)!=='present')throw new Error('completed retained inventory is absent');refs.push(await referenceFile(plan.exportReceiptPath),...plan.exportRefs);
  }else{
   if(await retained(plan.exportRefs)!=='absent')throw new Error('unreceipted retained bytes need explicit operator review');
   if(!before.inventory.containers.length)throw new Error('owned source containers are absent before evidence export');
   const started=await open(plan.exportReceiptPath,'wx',0o600);
   try{
    // Presence without a complete receipt refuses replay after coordinator loss.
    await started.writeFile(JSON.stringify({attemptId:attempt.attemptId,status:'started'})+'\n');await started.sync();
    const directory=await open(dirname(plan.exportReceiptPath),constants.O_RDONLY|constants.O_DIRECTORY);try{await directory.sync()}finally{await directory.close()}
    const exported=await jobs.run({...plan.exportRequest,timeoutMs:Math.min(plan.exportRequest.timeoutMs??plan.deadlineMs,plan.deadlineMs),cancelSignal:signal});
    observations.push({export:{ok:exported.ok,exitCode:exported.exitCode,timedOut:exported.timedOut,canceled:exported.canceled,code:exported.code}});
    if(!exported.ok)throw new Error('bounded evidence export did not complete');
    if(await retained(plan.exportRefs)!=='present')throw new Error('evidence export did not retain every admitted byte');
    const bytes=Buffer.from(JSON.stringify({attemptId:attempt.attemptId,status:'complete',refs:plan.exportRefs})+'\n');if(bytes.length>65536)throw new Error('export receipt exceeds byte bound');
    let position=0;while(position<bytes.length){const written=await started.write(bytes,position,bytes.length-position,position);if(!written.bytesWritten)throw new Error('export receipt write incomplete');position+=written.bytesWritten}
    await started.truncate(bytes.length);await started.sync();await started.chmod(0o400);await started.sync();
    const actual=await referenceFile(plan.exportReceiptPath);if(actual.sha256!==createHash('sha256').update(bytes).digest('hex')||actual.size_bytes!==bytes.length)throw new Error('export receipt bytes did not commit');
   }finally{await started.close()}
   refs.push(await referenceFile(plan.exportReceiptPath),...plan.exportRefs);
  }
  await verifyAttemptInputs(attempt.admissionRefs);await ownership();
  const compose=new ComposeExecution(jobs,plan.compose);await compose.requireVersion(signal);
  const beforeVolumes=object(before.inventory.volumes).Volumes;
  const requireQuiescent=async()=>{if((await observeCoordinator(jobs,plan.busctl,attempt.coordinator,signal)).status!=='quiescent')throw new Error('coordinator ownership changed before cleanup')};
  if(before.inventory.containers.length||before.inventory.networks.length||Array.isArray(beforeVolumes)&&beforeVolumes.length){
   await requireQuiescent();
   const stopped=await compose.run(['stop','--timeout','5'],signal);observations.push({stop:stopped});if(!stopped.ok)throw new Error('owned Compose stop incomplete');
   await ownership();await requireQuiescent();
   const down=await compose.run(['down','--volumes','--remove-orphans','--timeout','5'],signal);observations.push({cleanup:down});if(!down.ok)throw new Error('owned Compose cleanup incomplete');
  }
  const after=await ownership(),remaining=await engine.remainingOwned(attempt.runId,{cancelSignal:signal,deadlineMs:plan.deadlineMs});
  const volumes=object(after.inventory.volumes).Volumes,remainingVolumes=object(remaining.volumes).Volumes;
  if(after.inventory.containers.length||after.inventory.networks.length||!(volumes===null||Array.isArray(volumes)&&volumes.length===0)
   ||remaining.containers.length||remaining.networks.length||!(remainingVolumes===null||Array.isArray(remainingVolumes)&&remainingVolumes.length===0))throw new Error('owned native inventory remains after cleanup');
  if(await retained(plan.exportRefs)!=='present')throw new Error('retained evidence did not survive cleanup');
  return outcome('released');
 }catch(error){return outcome('retained',String(error instanceof Error?error.message:error))}
}
