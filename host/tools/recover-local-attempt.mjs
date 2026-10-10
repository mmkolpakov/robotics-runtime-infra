import {constants} from 'node:fs';
import {open,realpath} from 'node:fs/promises';
import {Context,Jobs} from '@robotics-runtime/host';
import {recoverLocalAttempt} from '../dist/src/index.js';
async function privateJson(path){
 if(await realpath(path)!==path)throw new Error('operator input must be canonical');
 const file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);
 try{
  const before=await file.stat({bigint:true});if(!before.isFile()||(before.mode&0o022n)||before.size>1048576n)throw new Error('bounded private operator input required');
  const bytes=Buffer.alloc(Number(before.size)+1);let position=0;
  while(position<bytes.length){const read=await file.read(bytes,position,bytes.length-position,position);if(!read.bytesRead)break;position+=read.bytesRead}
  const after=await file.stat({bigint:true});if(position!==Number(before.size)||['dev','ino','size','mtimeNs','ctimeNs'].some(key=>before[key]!==after[key]))throw new Error('operator input changed');
  return JSON.parse(bytes.subarray(0,position).toString('utf8'));
 }finally{await file.close()}
}
const [referencePath,planPath,...extra]=process.argv.slice(2);
if(!referencePath||!planPath||extra.length)throw new Error('expected attempt reference and freshly admitted operator plan');
const attempt=await privateJson(referencePath),plan=await privateJson(planPath);
const ctx=new Context();await ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:1048576,killTimeoutMs:2000}).await();
try{
 const result=await recoverLocalAttempt(ctx.jobs,{...plan,attempt});console.log(JSON.stringify(result));
 process.exitCode=result.resources==='released'?0:2;
}finally{await ctx.fiber.dispose()}
