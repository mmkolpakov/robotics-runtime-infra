import {platform,release,arch} from 'node:os';
import {readFile} from 'node:fs/promises';
export interface IsaacHostFacts {os:string;architecture:string;kernel:string;distribution:string;release:string}
export function requireNativeIsaacHost(facts:Readonly<IsaacHostFacts>):void {
  if(facts.os!=='linux'||facts.architecture!=='x64'||facts.distribution!=='ubuntu'||facts.release!=='24.04')throw new Error('Isaac OCI profile requires native Ubuntu 24.04 amd64');
  if(!facts.kernel||/microsoft|wsl/i.test(facts.kernel))throw new Error('Isaac OCI profile does not qualify WSL');
}
/** Observe the host running the same Unix Engine endpoint before any launch job. */
export async function observeIsaacHost():Promise<IsaacHostFacts>{
  const text=platform()==='linux'?await readFile('/etc/os-release','utf8'):'';
  const fields=Object.fromEntries(text.split('\n').filter(v=>v.includes('=')).map(v=>{const at=v.indexOf('=');return [v.slice(0,at),v.slice(at+1).replace(/^"|"$/g,'')]}));
  return {os:platform(),architecture:arch(),kernel:release(),distribution:fields.ID??'',release:fields.VERSION_ID??''};
}
