#!/usr/bin/env python3
"""Usage: update-cask.py <cask.rb> <version> <sha256>.

Fails unless exactly one `version "..."` line and one `sha256 "..."` line are
replaced (a line must consist of just the stanza, so text inside the caveats
heredoc is never touched). Line endings are preserved and the file is replaced
atomically, only when everything checks out.
"""
import os
import re
import shutil
import sys
import tempfile

VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?")
SHA256_RE = re.compile(r"[0-9a-f]{64}")


def stanza(name: str) -> re.Pattern:
    return re.compile(rf'^([ \t]*){name} "[^"\n]*"[ \t]*(?=\r?$)', re.M)


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit("error: usage: update-cask.py <cask.rb> <version> <sha256>")
    path, version, sha256 = sys.argv[1:4]
    if not VERSION_RE.fullmatch(version):
        sys.exit(f"error: invalid version {version!r}")
    if not SHA256_RE.fullmatch(sha256):
        sys.exit("error: sha256 must be 64 lowercase hex characters")

    try:
        with open(path, newline="") as f:
            text = f.read()
    except OSError as e:
        sys.exit(f"error: cannot read {path}: {e}")
    text, n_version = stanza("version").subn(
        lambda m: f'{m.group(1)}version "{version}"', text
    )
    text, n_sha = stanza("sha256").subn(
        lambda m: f'{m.group(1)}sha256 "{sha256}"', text
    )
    if n_version != 1 or n_sha != 1:
        sys.exit(
            f"error: {path}: expected exactly one version and one sha256 line, "
            f"found {n_version}/{n_sha}"
        )

    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".update-cask-")
    try:
        with os.fdopen(fd, "w", newline="") as f:
            f.write(text)
        shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    print(f"Updated {path} to v{version}")


if __name__ == "__main__":
    main()
