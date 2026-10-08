"""Observe diagnostic state access before retained export."""

from __future__ import annotations

import argparse
import json
import os
import stat
from pathlib import Path


def private_state_inventory(state: Path, uid: int, gid: int) -> dict:
    facts = state.lstat()
    if not stat.S_ISDIR(facts.st_mode) or (facts.st_uid, facts.st_gid) != (uid, gid):
        raise ValueError("private state directory type or ownership differs")
    if facts.st_mode & 0o022:
        raise ValueError("state directory permits foreign writes")
    if not os.access(state, os.R_OK | os.X_OK, effective_ids=True):
        raise PermissionError("state directory is unreadable")
    files = []
    pending = [state]
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as entries:
            for entry in sorted(entries, key=lambda row: row.name):
                path = Path(entry.path)
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    pending.append(path)
                elif stat.S_ISREG(info.st_mode):
                    with path.open("rb") as stream:
                        stream.read(1)
                    files.append(path.relative_to(state).as_posix())
                else:
                    raise ValueError(
                        "private state entry is not a regular file or directory"
                    )
    return {
        "stateUid": facts.st_uid,
        "stateGid": facts.st_gid,
        "stateMode": oct(stat.S_IMODE(facts.st_mode)),
        "stateDirectoryReadable": True,
        "presentStateFilesRead": files,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--retained", type=Path, required=True)
    args = parser.parse_args()
    if (os.getuid(), os.getgid()) != (10001, 1000):
        raise ValueError("diagnostic exporter identity differs")
    retained = args.retained.stat()
    if retained.st_gid != 1000 or retained.st_mode & 0o070 != 0o070:
        raise ValueError("retained directory group access differs")
    result = private_state_inventory(args.state, 10001, 1000)
    result.update(
        uid=os.getuid(),
        gid=os.getgid(),
        retainedGid=retained.st_gid,
        retainedMode=oct(retained.st_mode & 0o7777),
    )
    print(json.dumps(result))


if __name__ == "__main__":
    main()
