import assert from 'node:assert/strict';
import {readFile,readdir,stat} from 'node:fs/promises';
import {join} from 'node:path';
import {referenceFile} from '@robotics-runtime/host';
import {legacyLiveParameters} from './qualify-legacy-live.mjs';

export async function installedLegacyFixture(argv){
const parameters=legacyLiveParameters(argv);
const identity=JSON.parse(await readFile('/app/identity.json','utf8'));
assert.equal(parameters.sourceRevision,identity.deploymentRevision);
assert.equal(parameters.sourceVolume,identity.sourceVolume);
assert.equal(parameters.retainedVolume,identity.retainedVolume);
const allFiles=async root=>{
 const files=[];for(const row of await readdir(root,{withFileTypes:true})){const path=join(root,row.name);if(row.isDirectory())files.push(...await allFiles(path));else if(row.isFile())files.push(path)}return files;
};
const socketGid=(await stat('/engine.sock')).gid;
if(identity.engineProfile?.engine==='docker')assert.equal(String(socketGid),process.env.C18_SOCKET_GID,'actual socket group differs from selected Compose group');
const profilePath='/app/profiles/ros.yml';
const files=await Promise.all([...await allFiles('/app'),...await allFiles('/inputs')].map(async path=>({path,sha256:(await referenceFile(path)).sha256})));
const profile={id:'installed-ros-live',profilePath,files,requiredBindings:[{entryId:'gazebo',service:'gazeboRosV1'}],isolatedServices:['gazeboRosV1','legacyFinalization'],deadlineMs:240000};
return {
 profile,engineProfile:identity.engineProfile,socketGid,finalizerPlugin:'@robotics-runtime/infra-host/plugins/legacy-finalization',
 sourceHostRoot:process.env.C18_DEPLOYMENT_HOST_ROOT,postprocessRoot:'/app',
 composeEnvironment:{COMPOSE_PARALLEL_LIMIT:'1'},deferQualification:true,
 imageBindings:identity.observedImages,hostService:'installed-host',
 hostRequirement:{
  runId:process.env.C18_HOST_OWNER,projectName:process.env.C18_HOST_PROJECT,
  imageDigest:process.env.C18_NODE_IMAGE,user:'1000:1000',
  mounts:[{destination:'/run/robotics',readOnly:false,volumeName:identity.sourceVolume},{destination:'/retained',readOnly:false,volumeName:identity.retainedVolume}],
  hostConfig:{Init:true,ReadonlyRootfs:true,NetworkMode:'none',Memory:1073741824,UsernsMode:identity.engineProfile?.expectedUsernsMode??'private'},
 },
};
}
