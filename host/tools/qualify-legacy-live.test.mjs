import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,access,rm,writeFile,chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {legacyLiveParameters,validateLegacyLiveFixture,retainHomeComposeQualification,qualifyLegacyLive} from './qualify-legacy-live.mjs';

const image='sha256:'+'a'.repeat(64),reference='localhost/fixture@sha256:'+'b'.repeat(64);
const argv=output=>['/source','/engine.sock','/tools/docker-compose','run-12345678-1234-1234-1234-123456789abc','rr-source-fixture','rr-retained-fixture',image,reference,reference,reference,output,'c'.repeat(40)];
const fixture=()=>({
 profile:{id:'installed-ros-live',profilePath:'/app/profiles/ros.yml',files:[{path:'/app/profiles/ros.yml',sha256:'d'.repeat(64)}],requiredBindings:[{entryId:'gazebo',service:'gazeboRosV1'}],isolatedServices:['gazeboRosV1','legacyFinalization'],deadlineMs:1000},
 finalizerPlugin:'@robotics-runtime/infra-host/plugins/legacy-finalization',hostService:'installed-host',
 imageBindings:{simulation:{imageId:image,reference},finalizer:{reference},evidence:{reference}},
 hostRequirement:{runId:'fixture-owner',projectName:'fixture-project',imageDigest:reference,user:'1000:1000',mounts:[{destination:'/run/robotics',readOnly:false,volumeName:'rr-source-fixture'},{destination:'/retained',readOnly:false,volumeName:'rr-retained-fixture'}]},
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
 ['host config ID mistaken for RepoDigest',value=>{value.hostRequirement.imageDigest=image}],
 ['wrong selected image',value=>{value.imageBindings.simulation.imageId='sha256:'+'e'.repeat(64)}],
 ['mutable helper reference',value=>{value.imageBindings.finalizer.reference='localhost/helper:latest'}],
 ['reserved run owner override',value=>{value.composeEnvironment={ROBOTICS_RUN_ID:'foreign-owner'}}],
 ['reserved source storage override',value=>{value.composeEnvironment={LEGACY_SHARED_VOLUME:'foreign-volume'}}],
 ['reserved helper image override',value=>{value.composeEnvironment={LEGACY_COORDINATOR_IMAGE:'foreign-image'}}],
 ['zero Compose concurrency',value=>{value.composeEnvironment={COMPOSE_PARALLEL_LIMIT:'0'}}],
 ['invalid Compose concurrency',value=>{value.composeEnvironment={COMPOSE_PARALLEL_LIMIT:'1; command'}}],
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
  await chmod(path,0o444);
  const selected=fixture();selected.profile.profilePath=path;selected.profile.files=[{path,sha256:'0'.repeat(64)}];
  await assert.rejects(qualifyLegacyLive(argv(output),selected),/immutable file digest mismatch/);
  await assert.rejects(access(output),{code:'ENOENT'});
 }finally{await rm(root,{recursive:true,force:true})}
});

test('fixture Compose concurrency is explicit while source default remains unchanged',()=>{
 const parameters=legacyLiveParameters(argv('/output'));
 assert.deepEqual(validateLegacyLiveFixture(parameters),{});
 assert.deepEqual(validateLegacyLiveFixture(parameters,{composeEnvironment:{COMPOSE_PARALLEL_LIMIT:'1'}}),{composeEnvironment:{COMPOSE_PARALLEL_LIMIT:'1'}});
});

test('accepted bare and prefixed simulation IDs become one expected metadata identity without changing argv',()=>{
 const args=argv('/output'),bare=[...args];bare[6]=image.slice(7);
 const before=[...bare],parameters=legacyLiveParameters(bare);
 assert.equal(parameters.simulationImage,image);
 assert.deepEqual(parameters,legacyLiveParameters(args));
 assert.deepEqual(bare,before);
 for(const selectedId of [image,image.slice(7)]){
  const selected=fixture();selected.imageBindings.simulation.imageId=selectedId;
  assert.deepEqual(validateLegacyLiveFixture(parameters,selected),selected);
 }
 const mismatched=fixture();mismatched.imageBindings.simulation.imageId='e'.repeat(64);
 assert.throws(()=>validateLegacyLiveFixture(parameters,mismatched),/simulation image binding mismatch/);
 for(const invalid of ['sha256:'+image,'a'.repeat(63),'A'.repeat(64)]){
  const changed=[...args];changed[6]=invalid;assert.throws(()=>legacyLiveParameters(changed));
 }
});

test('HOME Compose receipt retains the existing API validated probe and declared environment',async()=>{
 const {ComposeExecution}=await import('@robotics-runtime/infra-host');
 const probe={ok:true,exitCode:0,stdout:'5.3.1\n',stderr:'actual probe diagnostic',timedOut:false,canceled:false};
 const requests=[],saved=[],environment={COMPOSE_PARALLEL_LIMIT:'1'};
 const compose=new ComposeExecution({run:async request=>{requests.push(request);return probe}},{
  executable:'/tools/docker-compose',socketPath:'/engine.sock',projectName:'fixture-home',
  files:['/source/fixture.json'],cwd:'/source',env:environment,
 });
 await retainHomeComposeQualification(compose,async(name,value)=>saved.push({name,value}),environment);
 assert.equal(requests.length,1);assert.deepEqual(requests[0].args.slice(-2),['version','--short']);
 assert.equal(requests[0].env.COMPOSE_PARALLEL_LIMIT,'1');
 assert.equal(requests[0].env.DOCKER_HOST,'unix:///engine.sock');assert.equal(requests[0].extendEnv,false);
 assert.deepEqual(saved,[{name:'home-compose-qualification',value:{
  version:'5.3.1',versionProbe:probe,environment,scope:'HOME source qualification only',
 }}]);
});

test('HOME Compose receipt cannot precede actual failed or incompatible version admission',async()=>{
 const {ComposeExecution}=await import('@robotics-runtime/infra-host');
 for(const [ok,stdout] of [[true,'5.3.0\n'],[true,'5.3.1-suffix\n'],[true,''],[false,'5.3.1\n']]){
  const saved=[];
  const compose=new ComposeExecution({run:async()=>({ok,stdout})},{
   executable:'/tools/docker-compose',socketPath:'/engine.sock',projectName:'fixture-home',
   files:['/source/fixture.json'],cwd:'/source',
  });
  await assert.rejects(retainHomeComposeQualification(compose,async(name,value)=>saved.push({name,value}),{}),/Compose 5.3.1 required/);
  assert.deepEqual(saved,[]);
 }
});

test('explicit Docker profile retains the exact default namespace and snapshots its identity',()=>{
 const parameters=legacyLiveParameters(argv('/output')),selected=fixture();
 selected.engineProfile={engine:'docker',expectedUsernsMode:''};
 selected.socketGid=998;
 selected.hostRequirement.hostConfig={UsernsMode:''};
 const copy=validateLegacyLiveFixture(parameters,selected);
 selected.engineProfile.expectedUsernsMode='private';
 selected.socketGid=999;
 assert.equal(copy.socketGid,998);
 assert.deepEqual(copy.engineProfile,{engine:'docker',expectedUsernsMode:''});
 assert.equal(copy.hostRequirement.hostConfig.UsernsMode,'');
 const podman=fixture();podman.engineProfile={engine:'podman',expectedUsernsMode:'private'};
 podman.hostRequirement.hostConfig={UsernsMode:'private'};
 assert.deepEqual(validateLegacyLiveFixture(parameters,podman),podman);
});
for(const [name,engineProfile,hostMode] of [
 ['Docker default relabelled private',{engine:'docker',expectedUsernsMode:'private'},'private'],
 ['foreign observed host namespace',{engine:'docker',expectedUsernsMode:''},'private'],
 ['Podman relabelled Docker default',{engine:'podman',expectedUsernsMode:''},''],
 ['unrecognised engine',{engine:'remote',expectedUsernsMode:''},''],
 ['extra namespace declaration',{engine:'docker',expectedUsernsMode:'',rootless:true},''],
]){
 test(name+' refuses before any admission or output effect',async()=>{
  const root=await mkdtemp(join(tmpdir(),'legacy-live-engine-')),output=join(root,'output');
  try{
   const selected=fixture();selected.engineProfile=engineProfile;selected.hostRequirement.hostConfig={UsernsMode:hostMode};
   await assert.rejects(qualifyLegacyLive(argv(output),selected));
   await assert.rejects(access(output),{code:'ENOENT'});
  }finally{await rm(root,{recursive:true,force:true})}
 });
}

test('native Docker default namespace must be observed exactly before it satisfies the profile',async()=>{
 const {validateObservation}=await import('@robotics-runtime/infra-host');
 const facts={endpoint:'unix:///fixture.sock',serverApi:'1.41',serverMinApi:'1.24',clientApi:'1.41',versionResponse:{}};
 const native={Id:'a'.repeat(64),Image:image,Config:{User:'1000:1000',Labels:{'org.robotics.runtime.run-id':'fixture-owner','com.docker.compose.project':'fixture-project'}},
  State:{Status:'running',Running:true,ExitCode:0},Mounts:[],HostConfig:{NetworkMode:'none',UsernsMode:''},NetworkSettings:{Networks:{}}};
 const requirement={runId:'fixture-owner',projectName:'fixture-project',imageId:image,user:'1000:1000',mounts:[],hostConfig:{UsernsMode:''}};
 assert.equal(validateObservation(facts,native,{Id:image},[],requirement).status,'complete');
 for(const mode of ['private','host',undefined]){
  const changed=structuredClone(native);changed.HostConfig.UsernsMode=mode;
  const observed=validateObservation(facts,changed,{Id:image},[],requirement);
  assert.equal(observed.status,'incomplete');
  assert.ok(observed.mismatches.includes('container.HostConfig.UsernsMode'));
 }
});

for(const socketGid of [undefined,-1,1.5,'998']){
 test('Docker socket group '+String(socketGid)+' cannot become an admitted native group',async()=>{
  const root=await mkdtemp(join(tmpdir(),'legacy-live-socket-')),output=join(root,'output');
  try{
   const selected=fixture();selected.engineProfile={engine:'docker',expectedUsernsMode:''};
   selected.hostRequirement.hostConfig={UsernsMode:''};selected.socketGid=socketGid;
   await assert.rejects(qualifyLegacyLive(argv(output),selected),/actual Docker socket group required/);
   await assert.rejects(access(output),{code:'ENOENT'});
  }finally{await rm(root,{recursive:true,force:true})}
 });
}
