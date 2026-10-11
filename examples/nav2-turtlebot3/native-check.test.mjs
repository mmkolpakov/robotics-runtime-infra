import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import test from 'node:test';

test('source document profile refuses native launch before loading host or acquiring actors', () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('./native-check.mjs', import.meta.url))], {encoding: 'utf8', timeout: 5000});
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /requires an admitted v2 SDK\/image composition/);
  assert.doesNotMatch(result.stderr, /ERR_MODULE_NOT_FOUND/);
});
