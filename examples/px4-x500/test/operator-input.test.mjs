import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readOperatorInput } from '../src/operator-input.mjs';

async function fixture(t) {
  const directory = await fs.mkdtemp(join(tmpdir(), 'x500-input-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  return join(directory, 'operator.json');
}
test('captures actual regular JSON bytes', async t => {
  const path = await fixture(t);
  await fs.writeFile(path, '{"px4Id":"actual"}');
  assert.deepEqual(await readOperatorInput(path), { px4Id: 'actual' });
});
test('oversize regular input refuses', async t => {
  const path = await fixture(t);
  await fs.writeFile(path, Buffer.alloc(4 * 1024 * 1024 + 1));
  await assert.rejects(readOperatorInput(path));
});
test('symlink refuses without following it', async t => {
  const path = await fixture(t);
  await fs.writeFile(path + '.target', '{}');
  await fs.symlink(path + '.target', path);
  await assert.rejects(readOperatorInput(path));
});
test('FIFO refuses without awaiting a writer', { timeout: 2000 }, async t => {
  const path = await fixture(t);
  execFileSync('mkfifo', [path], { timeout: 1000 });
  await assert.rejects(readOperatorInput(path));
});
test('actual opened-file growth refuses the captured bytes', async t => {
  const path = await fixture(t);
  await fs.writeFile(path, '{}');
  const handle = await fs.open(path, 'r');
  const prototype = Object.getPrototypeOf(handle);
  await handle.close();
  const original = prototype.read;
  let changed = false;
  const interception = mock.method(prototype, 'read', async function (...args) {
    if (!changed) {
      changed = true;
      await fs.appendFile(path, Buffer.alloc(4 * 1024 * 1024 + 1, 32));
    }
    return original.apply(this, args);
  });
  try { await assert.rejects(readOperatorInput(path)); }
  finally { interception.mock.restore(); }
  assert.equal(changed, true);
  assert.equal((await fs.stat(path)).size, 4 * 1024 * 1024 + 3);
});

test('same-byte pathname replacement refuses the originally opened file', async t => {
  const path = await fixture(t);
  await fs.writeFile(path, '{}');
  await fs.writeFile(path + '.replacement', '{}');
  const handle = await fs.open(path, 'r');
  const prototype = Object.getPrototypeOf(handle);
  await handle.close();
  const original = prototype.read;
  let changed = false;
  const interception = mock.method(prototype, 'read', async function (...args) {
    const result = await original.apply(this, args);
    if (!changed) {
      changed = true;
      await fs.rename(path + '.replacement', path);
    }
    return result;
  });
  try { await assert.rejects(readOperatorInput(path)); }
  finally { interception.mock.restore(); }
  assert.equal(changed, true);
});
