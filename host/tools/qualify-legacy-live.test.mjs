import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,access,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {legacyLiveParameters,validateLegacyLiveFixture,qualifyLegacyLive} from './qualify-legacy-live.mjs';

const image='sha256:'+'a'.repeat(64),reference='localhost/fixture@sha256:'+'b'.repeat(64);
const argv=output=>['/source','/engine.sock','/tools/docker-compose','run-12345678-1234-1234-1234-123456789abc','rr-source-fixture','rr-retained-fixture',image,reference,reference,reference,output,'c'.repeat(40)];
const fixture=()=>({
 profile:{id:'installed-ros-live',profilePath:'/app/profiles/ros.yml',files:[{path:'/app/profiles/ros.yml',sha256:'d'.repeat(64)}],requiredBindings:[{entryId:'gazebo',service:'gazeboRosV1'}],isolatedServices:['gazeboRosV1','legacyFinalization'],deadlineMs:1000},
 finalizerPlugin:'@robotics-runtime/infra-host/plugins/legacy-finalization',hostService:'installed-host',
 imageBindings:{simulation:{imageId:image,reference},finalizer:{reference},evidence:{reference}},
 hostRequirement:{runId:'fixture-owner',projectName:'fixture-project',imageDigest:image,user:'1000:1000',mounts:[{destination:'/run/robotics',readOnly:false,volumeName:'rr-source-fixture'},{destination:'/retained',readOnly:false,volumeName:'rr-retained-fixture'}]},
});
test('source wrapper retains all twelve positional bindings and default source route',()=>{
 const args=argv('/output'),parameters=legacyLiveParameters(args);
 assert.deepEqual(Object.values(parameters),args);
 assert.deepEqual(validateLegacyLiveFixture(parameters),{});
 assert.throws(()=>legacyLiveParameters(args.slice(0,-1)),/twelve positional arguments/);
});
test('installed binding snapshots do not follow caller mutation',()=>{
 const original=fixture(),copy=validateLegacyLiveFixture(legacyLiveParameters(argv('/output')),original);
 original.hostRequirement.mounts[0].volumeName='foreign';
 original.profile.files[0].sha256='0'.repeat(64);
 assert.equal(copy.hostRequirement.mounts[0].volumeName,'rr-source-fixture');
 assert.equal(copy.profile.files[0].sha256,'d'.repeat(64));
});
for(const [name,change] of [
 ['profile Include not bound',value=>{value.profile.files[0].path='/foreign/profile.yml'}],
 ['profile hash malformed',value=>{value.profile.files[0].sha256='mutable'}],
 ['foreign host storage',value=>{value.hostRequirement.mounts[0].volumeName='foreign-volume'}],
 ['wrong selected image',value=>{value.imageBindings.simulation.imageId='sha256:'+'e'.repeat(64)}],
 ['mutable helper reference',value=>{value.imageBindings.finalizer.reference='localhost/helper:latest'}],
]){
 test(name+' is rejected before output or runtime work',async()=>{
  const root=await mkdtemp(join(tmpdir(),'legacy-live-bindings-')),output=join(root,'output');
  try{
   const selected=fixture();change(selected);
   await assert.rejects(qualifyLegacyLive(argv(output),selected));
   await assert.rejects(access(output),{code:'ENOENT'});
  }finally{await rm(root,{recursive:true,force:true})}
 });
}
test('positional source CLI rejects an invalid owner before effects',async()=>{
 const root=await mkdtemp(join(tmpdir(),'legacy-live-source-')),output=join(root,'output');
 try{
  const args=argv(output);args[3]='foreign-owner';
  const result=spawnSync(process.execPath,[fileURLToPath(new URL('./qualify-legacy-live.mjs',import.meta.url)),...args],{encoding:'utf8'});
  assert.notEqual(result.status,0);assert.match(result.stderr,/AssertionError/);
  await assert.rejects(access(output),{code:'ENOENT'});
 }finally{await rm(root,{recursive:true,force:true})}
});

test('changed immutable Include bytes are refused by public Admission before Jobs or Engine',async()=>{
 const root=await mkdtemp(join(tmpdir(),'legacy-live-admission-')),output=join(root,'output'),path=join(root,'profile.json');
 try{
  await writeFile(path,JSON.stringify([{id:'gazebo',name:'@robotics-runtime/infra-host/plugins/gazebo-ros-v1'}]));
  const selected=fixture();selected.profile.profilePath=path;selected.profile.files=[{path,sha256:'0'.repeat(64)}];
  await assert.rejects(qualifyLegacyLive(argv(output),selected),/changed|digest|hash|immutable/i);
  await assert.rejects(access(output),{code:'ENOENT'});
 }finally{await rm(root,{recursive:true,force:true})}
});
