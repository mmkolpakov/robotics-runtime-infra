import assert from 'node:assert/strict';
import {Context,Jobs} from '@robotics-runtime/host';
import {ComposeExecution,EngineMetadata} from '../dist/src/index.js';
import {mkdir,writeFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
const [root,socket,image,imageId,output]=process.argv.slice(2);await mkdir(output,{recursive:true});
const runId='run-'+randomUUID(),projectName='rr-ros124-'+randomUUID().slice(0,8);
const ctx=new Context(),jobs=ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:4194304});await jobs.await();
const compose=new ComposeExecution(ctx.jobs,{executable:root+'/host/.tools/docker-compose',socketPath:socket,projectName,files:[root+'/host/test/fixtures/ros-cohort/compose.yaml'],cwd:root,env:{ROS_COHORT_IMAGE:image,ROBOTICS_RUN_ID:runId}});
const engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
const save=async(name,value)=>writeFile(output+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const finite=async(name,args)=>{const result=await compose.run(args);await save(name,result);if(!result.ok)throw new Error(result.diagnostic);return result};
let passed=false,failure;
try {
 await compose.requireVersion();const launch=await finite('facts-launch',['run','--detach','--no-deps','facts']);const id=launch.stdout.trim();assert.match(id,/^[a-f0-9]{64}$/);
 const required={runId,projectName,imageDigest:image,imageId,user:'1000:1000',mounts:[],hostConfig:{Init:true,Privileged:false,ReadonlyRootfs:true,NetworkMode:'none',Memory:268435456}};
 let actual;const end=Date.now()+30000;
 do{actual=await engine.inspect(id,required);if(actual.container.State.Status==='exited')break;await new Promise(resolve=>setTimeout(resolve,50))}while(Date.now()<end);
 await save('native-metadata',actual);assert.equal(actual.status,'complete');assert.equal(actual.container.State.Running,false);assert.equal(actual.container.State.ExitCode,0);
 const versions=await finite('installed-versions',['run','--rm','--no-deps','facts']);const fact=JSON.parse(versions.stdout);assert.equal(fact.contracts,'0.18.2');assert.equal(fact.harness,'0.19.1');assert.equal(fact.ros_gz_sim,'1.0.24');assert.equal(fact.simulation_interfaces,'1.5.1');
 const files={packages:'/usr/share/robotics-runtime/ros-cohort/deb-packages.tsv',gazebo:'/usr/share/robotics-runtime/ros-cohort/gazebo-versions.txt',stockOwner:'/usr/share/robotics-runtime/ros-cohort/stock-create-owner.txt'};
 for(const [name,path]of Object.entries(files)){const result=await finite(name,['run','--rm','--no-deps','--entrypoint','/bin/cat','facts',path]);await writeFile(output+'/'+name+'.txt',result.stdout);assert.ok(result.stdout.trim())}
 const verified=await finite('dpkg-verify',['run','--rm','--no-deps','--entrypoint','/usr/bin/dpkg','facts','--verify','ros-jazzy-ros-gz-sim','ros-jazzy-simulation-interfaces']);assert.equal(verified.stdout,'');passed=true;
} catch(error){failure=String(error);await save('failure',{failure});}
finally {
 const before=await engine.projectOwnership({runId,projectName});await save('cleanup-before',before);if(before.status!=='complete')throw new Error('foreign cleanup resource');
 await finite('cleanup',['down','--volumes','--remove-orphans']);const after=await engine.projectOwnership({runId,projectName});await save('cleanup-after',after);assert.equal(after.status,'complete');assert.equal(after.inventory.containers.length,0);assert.equal(after.inventory.networks.length,0);assert.ok(after.inventory.volumes.Volumes===null||after.inventory.volumes.Volumes?.length===0);
 await save('result',{passed,runId,projectName,image,imageId,failure,scope:'native installed package and stock file ownership; strict B3 remains separate'});await jobs.dispose();await ctx.fiber.dispose();
}
if(!passed)throw new Error(failure);console.log(JSON.stringify({passed,runId,projectName}));
