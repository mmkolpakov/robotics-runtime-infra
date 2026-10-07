import assert from 'node:assert/strict';
import {qualifyLegacyLive} from './qualify-legacy-live.mjs';
import {installedLegacyFixture} from './installed-fixture.mjs';
import {interruptedMeasurement} from './measurement-negative.mjs';
const [mode,...argv]=process.argv.slice(2);
assert.ok(['startup-cancel','foreign-cleanup','cancel','timeout'].includes(mode));
if(['startup-cancel','foreign-cleanup'].includes(mode))await import('./startup-negative-bootstrap.mjs');
else{
 const result=await qualifyLegacyLive(argv,await installedLegacyFixture(argv),bindings=>interruptedMeasurement(mode,bindings));
 console.log(JSON.stringify(result));if(result.status!=='passed')process.exitCode=1;
}
