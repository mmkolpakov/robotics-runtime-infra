import assert from 'node:assert/strict';
import {Context,Jobs} from '@robotics-runtime/host';
import {ComposeExecution,EngineMetadata} from '../dist/src/index.js';
import {mkdir,writeFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
const [root,socket,volume,subjectRun,output]=process.argv.slice(2);await mkdir(output,{recursive:true});const runId='run-'+randomUUID(),projectName='rr-rosreview-'+randomUUID().slice(0,8),image='sha256:3edaa11f2d8d6a127bda54ec251c5436f472723c34eb3f6198ec329cfd811519';
const ctx=new Context(),jobs=ctx.plugin(Jobs,{timeoutMs:120000,maxBufferBytes:16777216});await jobs.await();const options={executable:root+'/host/.tools/docker-compose',socketPath:socket,projectName,files:[root+'/host/test/fixtures/ros-cohort/retained-review.yaml'],cwd:root,env:{ROBOTICS_RUN_ID:runId,ROS_REVIEW_IMAGE:image,ROS_REVIEW_SOURCE_ROOT:root,ROS_REVIEW_RETAINED_VOLUME:volume,ROS_REVIEW_SUBJECT_RUN:subjectRun}};const compose=new ComposeExecution(ctx.jobs,options),engine=await EngineMetadata.connect({socketPath:socket,operationMinApi:'1.24',operationMaxApi:'1.53'});
const save=async(name,value)=>writeFile(output+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');let passed=false;
try{
 await compose.requireVersion();const launch=await compose.run(['run','--detach','--no-deps','reader']);await save('launch',launch);assert.equal(launch.ok,true);const id=launch.stdout.trim();assert.match(id,/^[a-f0-9]{64}$/);
 const required={runId,projectName,imageId:image,user:'1000:1000',mounts:[{destination:'/retained',readOnly:true,volumeName:volume}],hostConfig:{Init:true,ReadonlyRootfs:true,Privileged:false,NetworkMode:'none',Memory:268435456}};
 let actual;const end=Date.now()+120000;do{actual=await engine.inspect(id,required);if(!actual.container.State.Running)break;await new Promise(resolve=>setTimeout(resolve,50))}while(Date.now()<end);await save('native-metadata',actual);assert.equal(actual.status,'complete');assert.equal(actual.container.State.ExitCode,0);assert.equal(actual.container.State.Running,false);assert.equal(actual.container.Mounts.some(m=>m.Destination==='/run/robotics'),false);
 const read=await compose.run(['run','--rm','--no-deps','reader']);await save('worker',read);assert.equal(read.ok,true);await writeFile(output+'/independent-retained-review.json',read.stdout);passed=true;
}finally{
 const before=await engine.projectOwnership({runId,projectName});await save('cleanup-before',before);assert.equal(before.status,'complete');const cleanup=await compose.run(['down','--volumes','--remove-orphans']);await save('cleanup',cleanup);assert.equal(cleanup.ok,true);const after=await engine.projectOwnership({runId,projectName});await save('cleanup-after',after);assert.equal(after.status,'complete');assert.equal(after.inventory.containers.length,0);assert.equal(after.inventory.networks.length,0);await save('result',{passed,runId,projectName,subjectRun,volume,sourceMounted:false});await jobs.dispose();await ctx.fiber.dispose();
}
