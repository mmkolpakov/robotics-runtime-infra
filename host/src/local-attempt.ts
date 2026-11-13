import {constants} from 'node:fs';
import {open,lstat,realpath} from 'node:fs/promises';
import {dirname,isAbsolute} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {randomUUID,createHash} from 'node:crypto';
import {referenceFile,type ArtifactRef} from '@robotics-runtime/host';
import type {FiniteJobs} from './compose-execution.js';

export interface CoordinatorIdentity {unit:string;invocationId:string}
export interface LocalAttemptRecord {
 version:1;attemptId:string;runId:string;projectName:string;targetEnvironment:'software'|'simulation';
 coordinator:CoordinatorIdentity;admissionRefs:readonly ArtifactRef[];
}
export interface CoordinatorObservation {
 status:'active'|'quiescent'|'unknown';identity?:CoordinatorIdentity;runtimeMaxUs?:number;timeoutStopUs?:number;
 raw:readonly unknown[];state?:string;diagnostic?:string;
}
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const unit=/^rr-attempt-[0-9a-f-]{36}\.service$/;
const invocation=/^[0-9a-f]{32}$/;
const record=(value:unknown):Record<string,unknown>=>{
 if(!value||typeof value!=='object'||Array.isArray(value))throw new Error('attempt metadata must be an object');return value as Record<string,unknown>;
};
function checked(value:unknown):LocalAttemptRecord {
 const v=record(value),c=record(v.coordinator);
 if(Object.keys(v).some(key=>!['version','attemptId','runId','projectName','targetEnvironment','coordinator','admissionRefs'].includes(key))||v.version!==1||typeof v.attemptId!=='string'||!uuid.test(v.attemptId)
  ||typeof v.runId!=='string'||!/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(v.runId)||typeof v.projectName!=='string'||!/^[a-z0-9][a-z0-9_-]{1,62}$/.test(v.projectName)
  ||!['software','simulation'].includes(String(v.targetEnvironment))||Object.keys(c).some(key=>!['unit','invocationId'].includes(key))||typeof c.unit!=='string'||!unit.test(c.unit)
  ||typeof c.invocationId!=='string'||!invocation.test(c.invocationId)||!Array.isArray(v.admissionRefs)||v.admissionRefs.length<1||v.admissionRefs.length>32)throw new Error('invalid local attempt identity');
 const refs=v.admissionRefs.map(value=>{
  const ref=record(value);if(typeof ref.uri!=='string'||!ref.uri.startsWith('file:')||typeof ref.sha256!=='string'||!/^[a-f0-9]{64}$/.test(ref.sha256)
   ||!Number.isSafeInteger(ref.size_bytes)||Number(ref.size_bytes)<0||Number(ref.size_bytes)>67108864)throw new Error('invalid local attempt input identity');
  if(pathToFileURL(fileURLToPath(ref.uri)).href!==ref.uri)throw new Error('attempt reference URI is not canonical');return Object.freeze({uri:ref.uri,sha256:ref.sha256,size_bytes:Number(ref.size_bytes)});
 });
 if(new Set(refs.map(ref=>ref.uri)).size!==refs.length)throw new Error('attempt admission references alias one input');
 return Object.freeze({version:1,attemptId:v.attemptId,runId:v.runId,projectName:v.projectName,targetEnvironment:v.targetEnvironment,
  coordinator:Object.freeze({unit:c.unit,invocationId:c.invocationId}),admissionRefs:Object.freeze(refs)}) as LocalAttemptRecord;
}
export async function verifyAttemptInputs(refs:readonly ArtifactRef[]):Promise<void>{
 for(const expected of refs){
  const path=fileURLToPath(expected.uri);
  if(await realpath(path)!==path||!(await lstat(path)).isFile())throw new Error('attempt input is not a canonical regular file');
  const actual=await referenceFile(path,{maxBytes:67108864});
  if(actual.sha256!==expected.sha256||actual.size_bytes!==expected.size_bytes)throw new Error('admitted attempt input changed');
 }
}
/** Writes once before native effects; it stores identities, never commands or credentials. */
export async function createLocalAttempt(path:string,input:Omit<LocalAttemptRecord,'version'|'attemptId'>,os:{jobs:FiniteJobs;busctl:string}):Promise<ArtifactRef>{
 const value=checked({...structuredClone(input),version:1,attemptId:randomUUID()});
 const coordinator=await observeCoordinator(os.jobs,os.busctl,value.coordinator);
 if(coordinator.status!=='active'||coordinator.state!=='active')throw new Error('creation requires the admitted active bounded coordinator');
 if(!isAbsolute(path)||await realpath(dirname(path))!==dirname(path))throw new Error('attempt directory must be canonical');
 const parent=await lstat(dirname(path));if(!parent.isDirectory()||(parent.mode&0o022))throw new Error('attempt directory must deny foreign writes');
 await verifyAttemptInputs(value.admissionRefs);
 const bytes=Buffer.from(JSON.stringify(value)+'\n');if(bytes.length>65536)throw new Error('attempt record exceeds its byte bound');
 const file=await open(path,'wx',0o600);
 try{await file.writeFile(bytes);await file.sync();await file.chmod(0o400);await file.sync()}finally{await file.close()}
 const directory=await open(dirname(path),constants.O_RDONLY|constants.O_DIRECTORY);try{await directory.sync()}finally{await directory.close()}
 return referenceFile(path,{maxBytes:65536});
}
export async function loadLocalAttempt(expected:ArtifactRef):Promise<LocalAttemptRecord>{
 const path=fileURLToPath(expected.uri);if(await realpath(path)!==path)throw new Error('attempt record is not canonical');
 const file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);
 try{
  const before=await file.stat({bigint:true});if(!before.isFile()||(before.mode&0o222n)||(before.mode&0o077n)||before.size>65536n)throw new Error('attempt record must be private immutable regular bytes');
  const bytes=Buffer.alloc(Number(before.size)+1);let position=0;
  while(position<bytes.length){const read=await file.read(bytes,position,bytes.length-position,position);if(!read.bytesRead)break;position+=read.bytesRead}
  const after=await file.stat({bigint:true}),named=await lstat(path,{bigint:true});
  if(position!==Number(before.size)||['dev','ino','size','mtimeNs','ctimeNs'].some(key=>before[key as keyof typeof before]!==after[key as keyof typeof after]||before[key as keyof typeof before]!==named[key as keyof typeof named]))throw new Error('attempt record changed during capture');
  const captured=bytes.subarray(0,position);if(createHash('sha256').update(captured).digest('hex')!==expected.sha256||captured.length!==expected.size_bytes)throw new Error('attempt record differs from admitted identity');
  return checked(JSON.parse(captured.toString('utf8')));
 }finally{await file.close()}
}
/** Typed systemd D-Bus values avoid parsing human duration strings. No systemd writes. */
export async function observeCoordinator(jobs:FiniteJobs,busctl:string,expected:CoordinatorIdentity,signal?:AbortSignal):Promise<CoordinatorObservation>{
 if(!isAbsolute(busctl)||!unit.test(expected.unit)||!invocation.test(expected.invocationId))throw new Error('admitted coordinator identity required');
 const raw:unknown[]=[];
 const read=async(args:string[])=>{
  const result=await jobs.run({executable:busctl,args:['--user','--json=short','--timeout=5',...args],timeoutMs:5000,maxBufferBytes:65536,cancelSignal:signal,extendEnv:false,
   env:{PATH:'/usr/bin:/bin',LANG:'C.UTF-8',XDG_RUNTIME_DIR:process.env.XDG_RUNTIME_DIR??'/run/user/'+process.getuid!()}});
  raw.push(result);if(!result.ok)throw new Error('coordinator metadata unavailable');return result.stdout.trim().split('\n').map(line=>record(JSON.parse(line)));
 };
 try{
  const location=(await read(['call','org.freedesktop.systemd1','/org/freedesktop/systemd1','org.freedesktop.systemd1.Manager','GetUnit','s',expected.unit]))[0]!;
  if(location.type!=='o'||!Array.isArray(location.data)||location.data.length!==1||typeof location.data[0]!=='string')throw new Error('coordinator object path unavailable');
  const path=location.data[0],prefix=['get-property','org.freedesktop.systemd1',path];
  const native=await read([...prefix,'org.freedesktop.systemd1.Unit','Id','InvocationID','LoadState','ActiveState','SubState']);
  const service=await read([...prefix,'org.freedesktop.systemd1.Service','RuntimeMaxUSec','TimeoutStopUSec','KillMode','SendSIGKILL','Type','MainPID','ControlPID','Restart']);
  const [id,inv,load,active]=native,[runtime,stop,kill,send,type,pid,control,restart]=service;
  if(native.length!==5||service.length!==8||id!.type!=='s'||id!.data!==expected.unit||inv!.type!=='ay'||!Array.isArray(inv!.data)||inv!.data.length!==16||inv!.data.some(value=>!Number.isInteger(value)||value<0||value>255))throw new Error('coordinator identity incomplete');
  const identity={unit:expected.unit,invocationId:Buffer.from(inv!.data).toString('hex')};
  if(identity.invocationId!==expected.invocationId||load!.data!=='loaded'||runtime!.type!=='t'||!Number.isSafeInteger(runtime!.data)||Number(runtime!.data)<=0||Number(runtime!.data)>300000000
   ||stop!.type!=='t'||!Number.isSafeInteger(stop!.data)||Number(stop!.data)<=0||Number(stop!.data)>30000000||kill!.data!=='control-group'||send!.data!==true||type!.data!=='exec'||restart!.type!=='s'||restart!.data!=='no')throw new Error('coordinator invocation or finite control-group bounds mismatch');
  const quiescent=['inactive','failed'].includes(String(active!.data))&&pid!.type==='u'&&pid!.data===0&&control!.type==='u'&&control!.data===0;
  return {status:quiescent?'quiescent':'active',identity,state:String(active!.data),runtimeMaxUs:Number(runtime!.data),timeoutStopUs:Number(stop!.data),raw};
 }catch(error){return {status:'unknown',raw,diagnostic:String(error instanceof Error?error.message:error)}}
}
