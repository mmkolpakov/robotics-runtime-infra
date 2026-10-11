import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import {join} from 'node:path';

const MAX_RECORD_BYTES = 1024 * 1024;
const MAX_TOTAL_BYTES = 8 * 1024 * 1024;
const MAX_RECORDS = 2048;

// Receiver UTC has millisecond resolution; these are not sender or synchronized timestamps.
export function controllerJournal(output, {runId, domainId}, {
  unixNs = () => String(BigInt(Date.now()) * 1000000n),
  monotonicMs = () => performance.now(),
} = {}) {
  assert.match(runId, /^run-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(domainId, 'px4');
  const records = [];
  const started = unixNs();
  let total = 0, closed = false;
  return {
    async retain(kind, value) {
      assert(!closed, 'controller journal is already closed');
      assert.match(kind, /^[a-z][a-z0-9-]{0,63}$/);
      assert(records.length < MAX_RECORDS, 'controller record count exceeds its bound');
      const sequence = records.length;
      const name = String(sequence).padStart(4, '0') + '-' + kind + '.json';
      const raw = Buffer.from(JSON.stringify({
        run_id: runId, domain_id: domainId, sequence, kind,
        receiver_unix_ns: unixNs(), receiver_monotonic_ms: monotonicMs(), value,
      }) + '\n');
      assert(raw.length <= MAX_RECORD_BYTES && total + raw.length <= MAX_TOTAL_BYTES,
        'controller journal byte budget exceeded');
      await writeFile(join(output, name), raw, {flag: 'wx', mode: 0o600});
      total += raw.length;
      records.push({path: name, kind, sha256: createHash('sha256').update(raw).digest('hex'),
        size_bytes: raw.length});
    },
    async close() {
      assert(!closed, 'controller journal is already closed');
      const manifest = {run_id: runId, domain_id: domainId, clock_source: 'controller-utc-ms',
        started_unix_ns: started, finished_unix_ns: unixNs(), complete: true, records,
        total_bytes: total};
      await writeFile(join(output, 'controller-manifest.json'), JSON.stringify(manifest) + '\n',
        {flag: 'wx', mode: 0o600});
      closed = true;
      return manifest;
    },
  };
}
