import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {access,readFile,stat,readlink} from 'node:fs/promises';
import {EngineMetadata} from '/opt/robotics/infra/dist/src/index.js';
import {Context,Jobs} from '/opt/robotics/infra/node_modules/@robotics-runtime/host/dist/src/index.js';
const pid1=await readFile('/proc/1/comm','utf8');
assert.notEqual(process.pid,1);
const pid1Command=await readFile('/proc/1/cmdline');
const pid1Executable=await readlink('/proc/1/exe');
const initBinary=await readFile('/proc/1/exe');
const initSha256=createHash('sha256').update(initBinary).digest('hex');
assert.equal(pid1Command.toString().split('\0')[0],pid1Executable);
assert.equal(initSha256,process.env.ROBOTICS_EXPECTED_INIT_SHA256);
const uidMap=await readFile('/proc/self/uid_map','utf8'),gidMap=await readFile('/proc/self/gid_map','utf8');
const mapping=(text,inside)=>{for(const l of text.trim().split('\n')) {const[a,b,n]=l.trim().split(/\s+/).map(Number);if(a<=inside&&inside<a+n)return b+inside-a} throw new Error('native mapping absent')};
const capabilities=(await readFile('/proc/self/status','utf8')).split('\n').filter(l=>/^Cap(Inh|Prm|Eff|Bnd|Amb):/.test(l));
assert.equal(process.getuid(),1000);

assert.equal(mapping(uidMap,1000),0);
assert.equal(mapping(gidMap,1000),0);
assert.ok(capabilities.every(l=>/:\s+0+$/.test(l)));
const socket=await stat('/run/engine.sock');
assert.ok(socket.isSocket());
assert.equal(socket.uid,1000);assert.equal(socket.gid,1000);assert.equal(socket.mode&0o777,0o600);
// Only after the native namespace/group/socket checks may the host access Engine.
const engine=await EngineMetadata.connect({socketPath:'/run/engine.sock',operationMinApi:'1.24',operationMaxApi:'1.53'});
await access('/opt/robotics/infra/node_modules/.bin/cordis');
const ctx=new Context();const fiber=ctx.plugin(Jobs,{timeoutMs:10000});await fiber.await();
try {
 const compose=await ctx.jobs.run({executable:'/usr/local/bin/docker-compose',args:['version','--short']});
 const python=await ctx.jobs.run({executable:'python3',args:['--version']});
 assert.equal(compose.ok,true);assert.equal(compose.stdout.trim(),'5.3.1');assert.equal(python.code,'ENOENT');
 console.log(JSON.stringify({kind:'host-image-native',pid:process.pid,pid1:pid1.trim(),pid1Command:pid1Command.toString().split('\0'),pid1Executable,initSha256,uid:process.getuid(),gid:process.getgid(),groups:process.getgroups(),uidMap,gidMap,capabilities,socket:{uid:socket.uid,gid:socket.gid,mode:socket.mode&0o777},node:process.version,os:await readFile('/etc/os-release','utf8'),compose,python,engine:engine.facts}));
} finally {await fiber.dispose()}
