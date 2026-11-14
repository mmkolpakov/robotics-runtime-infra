import assert from 'node:assert/strict';
import { constants } from 'node:fs';
import { open, lstat, realpath } from 'node:fs/promises';
import { dirname, isAbsolute, relative, resolve } from 'node:path';

const LIMIT = 4 * 1024 * 1024;
const same = (a, b) => ['dev', 'ino', 'mode', 'size', 'mtimeNs', 'ctimeNs'].every(k => a[k] === b[k]);

export async function readOperatorInput(path, { trustedOutside, readOnly = false } = {}) {
  let outside;
  if (trustedOutside !== undefined) {
    assert(isAbsolute(path) && await realpath(path) === resolve(path), 'canonical absolute trusted file required');
    outside = await realpath(trustedOutside);
    const part = relative(outside, path);
    assert(part && (part.startsWith('../') || isAbsolute(part)), 'trusted file must be outside the evidence archive');
    const parent = await lstat(dirname(path));
    assert(parent.isDirectory() && !(parent.mode & 0o022), 'trusted file directory must not be group or other writable');
  }
  const fd = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const before = await fd.stat({ bigint: true });
    assert(before.isFile() && before.size <= BigInt(LIMIT), 'bounded regular operator file required');
    if (outside !== undefined) assert(!(before.mode & 0o022n), 'trusted file must not be group or other writable');
    if (readOnly) assert(!(before.mode & 0o222n), 'trusted profile must be read-only');
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
    if (outside !== undefined) assert(await realpath(path) === resolve(path), 'trusted file location changed during capture');
    return JSON.parse(bytes.subarray(0, length).toString('utf8'));
  } finally { await fd.close(); }
}
