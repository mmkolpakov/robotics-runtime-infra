import {writeFile} from 'node:fs/promises';
import {EngineMetadata} from '../dist/src/index.js';
const engine = await EngineMetadata.connect({socketPath: process.argv[2], operationMinApi: '1.24', operationMaxApi: '1.53'});
await writeFile(process.argv[3], JSON.stringify(engine.facts, null, 2)+'\n');
console.log(JSON.stringify({endpoint:engine.facts.endpoint,serverApi:engine.facts.serverApi,clientApi:engine.facts.clientApi}));
