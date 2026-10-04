import {platform,release,arch} from 'node:os';
import {readFile} from 'node:fs/promises';
import {EngineMetadata} from '../../engine-metadata.js';
import type {EngineEndpoint,EngineFacts} from '../../engine-metadata.js';

export interface IsaacClientFacts {os:string;architecture:string;kernel:string;distribution?:string;release?:string}
export interface IsaacDeploymentObservation {
  status:'complete'|'incomplete';missing:string[];mismatches:string[];
  engine:EngineFacts;info:unknown;
}
/** Client distro is diagnostic only: the supported Node host is a Debian container. */
export function requireSupportedIsaacClient(client:Readonly<IsaacClientFacts>):void {
  if(client.os!=='linux'||client.architecture!=='x64')throw new Error('Isaac OCI client requires Linux amd64');
  if(!client.kernel||/microsoft|wsl/i.test(client.kernel))throw new Error('Isaac OCI profile does not qualify WSL or an unknown local kernel');
}
export async function observeIsaacClient():Promise<IsaacClientFacts>{
  const text=platform()==='linux'?await readFile('/etc/os-release','utf8'):'';
  const fields=Object.fromEntries(text.split('\n').filter(v=>v.includes('=')).map(v=>{const at=v.indexOf('=');return [v.slice(0,at),v.slice(at+1).replace(/^"|"$/g,'')]}));
  return {os:platform(),architecture:arch(),kernel:release(),distribution:fields.ID??'',release:fields.VERSION_ID??''};
}
const record=(value:unknown):Record<string,unknown>|undefined=>
  value&&typeof value==='object'&&!Array.isArray(value)?value as Record<string,unknown>:undefined;
/** Only fields used by this exact native Ubuntu/NVIDIA profile are projected. */
export function projectIsaacDeployment(observed:{engine:EngineFacts;info:unknown}):IsaacDeploymentObservation {
  const info=record(observed.info),missing:string[]=[],mismatches:string[]=[];
  const field=(name:string):string|undefined=>{
    const value=info?.[name];
    if(typeof value!=='string'||!value){missing.push('engine.info.'+name);return undefined}
    return value;
  };
  const os=field('OperatingSystem'),kernel=field('KernelVersion'),architecture=field('Architecture');
  if(os&&!/^Ubuntu 24\.04(?:\.[0-9]+)?(?:\s|$)/.test(os))mismatches.push('engine.info.OperatingSystem');
  if(kernel&&/microsoft|wsl/i.test(kernel))mismatches.push('engine.info.KernelVersion');
  if(architecture&&!['x86_64','amd64'].includes(architecture))mismatches.push('engine.info.Architecture');
  const runtimes=record(info?.Runtimes);
  if(!runtimes)missing.push('engine.info.Runtimes');
  else if(!Object.hasOwn(runtimes,'nvidia'))mismatches.push('engine.info.Runtimes.nvidia');
  else {
    const nvidia=record(runtimes.nvidia);
    if(typeof nvidia?.path!=='string'||!nvidia.path)missing.push('engine.info.Runtimes.nvidia.path');
  }
  return {status:missing.length||mismatches.length?'incomplete':'complete',missing,mismatches,engine:observed.engine,info:observed.info};
}
export async function admitIsaacDeployment(client:Readonly<IsaacClientFacts>,endpoint:EngineEndpoint,signal:AbortSignal):
Promise<{engine:EngineMetadata;observed:IsaacDeploymentObservation}> {
  requireSupportedIsaacClient(client);signal.throwIfAborted();
  const engine=await EngineMetadata.connect(endpoint,{cancelSignal:signal});
  const observed=projectIsaacDeployment(await engine.deploymentInfo({cancelSignal:signal}));
  if(observed.status!=='complete')throw new Error('Isaac Engine deployment admission is incomplete: '+[...observed.missing,...observed.mismatches].join(', '));
  return {engine,observed};
}
