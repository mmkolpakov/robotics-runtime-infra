import {mkdir,chown,chmod} from 'node:fs/promises';
for(const path of ['/run/robotics','/retained']) {await chown(path,1000,1000);await chmod(path,0o2770)}
await mkdir('/run/robotics/output',{recursive:false});await chown('/run/robotics/output',10001,1000);await chmod('/run/robotics/output',0o2770);
console.log(JSON.stringify({initialized:['/run/robotics','/retained'],outputGroup:1000,scoped:true}));
