import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {controllerJournal} from '../src/journal.mjs';

const identity = {runId: 'run-11111111-2222-4333-8444-555555555555', domainId: 'px4'};

test('journal binds original decoded SDK response and receiver timestamps before closure', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'px4-journal-'));
  try {
    let tick = 10n;
    const journal = controllerJournal(directory, identity, {
      unixNs: () => String(tick++ * 1000000n), monotonicMs: () => 12.5,
    });
    const response = {action_result: {result: 'RESULT_SUCCESS'}};
    await journal.retain('action-takeoff', response);
    const manifest = await journal.close();
    const raw = await readFile(join(directory, manifest.records[0].path));
    const record = JSON.parse(raw);
    assert.deepEqual(record.value, response);
    assert.equal(record.run_id, identity.runId);
    assert.equal(record.receiver_monotonic_ms, 12.5);
    assert.equal(record.receiver_unix_ns, '11000000');
    assert.equal(manifest.records[0].sha256, createHash('sha256').update(raw).digest('hex'));
    await assert.rejects(journal.retain('telemetry-armed', {}), /already closed/);
    await assert.rejects(journal.close(), /already closed/);
  } finally {await rm(directory, {recursive: true, force: true});}
});

test('oversized record refuses before a file or successful manifest is written', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'px4-journal-'));
  try {
    const journal = controllerJournal(directory, identity);
    await assert.rejects(journal.retain('telemetry-position', {value: 'x'.repeat(1024 * 1024)}),
      /byte budget/);
    await assert.rejects(readFile(join(directory, '0000-telemetry-position.json')), {code: 'ENOENT'});
    await assert.rejects(readFile(join(directory, 'controller-manifest.json')), {code: 'ENOENT'});
  } finally {await rm(directory, {recursive: true, force: true});}
});
