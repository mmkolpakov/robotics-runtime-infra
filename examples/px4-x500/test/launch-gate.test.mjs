import assert from 'node:assert/strict';
import {existsSync} from 'node:fs';
import {mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {test} from 'node:test';

test('source document profile refuses native startup before operator reads or output', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'px4-launch-gate-'));
  try {
    const output = join(directory, 'capture');
    const result = spawnSync(process.execPath, ['src/run.mjs', 'land',
      join(directory, 'missing-operator.json'), output, join(directory, 'missing-inputs.json')], {
      cwd: new URL('..', import.meta.url), encoding: 'utf8', timeout: 5000,
    });
    assert.equal(result.error, undefined);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /native launch requires an admitted/);
    assert.equal(existsSync(output), false);
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});
