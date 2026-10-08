import {qualifyLegacyLive} from './qualify-legacy-live.mjs';
import {installedLegacyFixture} from './installed-fixture.mjs';
const argv=process.argv.slice(2);
const result=await qualifyLegacyLive(argv,await installedLegacyFixture(argv));
console.log(JSON.stringify(result));if(result.status!=='passed')process.exitCode=1;
