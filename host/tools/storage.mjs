import {mkdir,writeFile,readFile,chown,chmod} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const input='/run/robotics/input/exact.json';
const bytes=Buffer.from('{"ns":9007199254740993}\n');
const mode=process.argv[2];
const nativeNamespace=async()=>({uidMap:await readFile('/proc/self/uid_map','utf8'),gidMap:await readFile('/proc/self/gid_map','utf8'),capabilities:(await readFile('/proc/self/status','utf8')).split('\n').filter(l=>/^Cap(Inh|Prm|Eff|Bnd|Amb):/.test(l))});
if(mode==='init') {
  await mkdir('/run/robotics/output',{recursive:true});
  await chown('/run/robotics/output',10001,1000);
  await chmod('/run/robotics/output',0o2770);
  await chown('/run/robotics/input',1000,1000);
  await writeFile(input,bytes);
  await chown(input,1000,1000);
  await chmod(input,0o444);
} else if(mode==='worker') {
  assert.equal(process.getuid(),10001);
  const observed=await readFile(input);
  assert.deepEqual(observed,bytes);
  let readOnlyError;
  try {await writeFile(input,'tamper')} catch(error) {readOnlyError=error.code}
  assert.equal(readOnlyError,'EROFS');
  await writeFile('/run/robotics/output/exact.json',observed);
  const report={namespace:await nativeNamespace(),uid:process.getuid(),gid:process.getgid(),inputPath:input,outputPath:'/run/robotics/output/exact.json',sha256:createHash('sha256').update(observed).digest('hex'),readOnlyError};
  await writeFile('/run/robotics/output/worker.json',JSON.stringify(report)+'\n');
  console.log(JSON.stringify(report));
} else if(mode==='host') {
  assert.equal(process.getuid(),1000);
  assert.deepEqual(await readFile('/run/robotics/output/exact.json'),bytes);
  assert.deepEqual(await readFile(input),bytes);
  console.log(JSON.stringify({namespace:await nativeNamespace(),uid:process.getuid(),gid:process.getgid(),worker:JSON.parse(await readFile('/run/robotics/output/worker.json','utf8')),sameAbsolutePaths:true,exactBytes:true,payloadBase64:bytes.toString('base64')}));
} else throw new Error('unknown finite storage fixture mode');
