import assert from 'node:assert/strict';
import { constants } from 'node:fs';
import { open, lstat } from 'node:fs/promises';

const LIMIT = 4 * 1024 * 1024;
const same = (a, b) => ['dev', 'ino', 'mode', 'size', 'mtimeNs', 'ctimeNs'].every(k => a[k] === b[k]);

export async function readOperatorInput(path) {
  const fd = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const before = await fd.stat({ bigint: true });
    assert(before.isFile() && before.size <= BigInt(LIMIT), 'bounded regular operator file required');
    const bytes = Buffer.alloc(LIMIT + 1);
    let length = 0;
    while (length < bytes.length) {
      const { bytesRead } = await fd.read(bytes, length, bytes.length - length, length);
      if (!bytesRead) break;
      length += bytesRead;
    }
    const after = await fd.stat({ bigint: true });
    const current = await lstat(path, { bigint: true });
    assert(length <= LIMIT && BigInt(length) === before.size && same(before, after) && same(after, current),
      'operator file changed or exceeded its bound during capture');
    return JSON.parse(bytes.subarray(0, length).toString('utf8'));
  } finally { await fd.close(); }
}
