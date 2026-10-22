#!/usr/bin/env python3
"""Usage: update-cask.py <cask.rb> <version> <sha256>.

Fails unless exactly one version and one sha256 line are replaced; the file is
only written when everything checks out.
"""
import re
import sys

VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?")
SHA256_RE = re.compile(r"[0-9a-f]{64}")


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit("usage: update-cask.py <cask.rb> <version> <sha256>")
    path, version, sha256 = sys.argv[1:4]
    if not VERSION_RE.fullmatch(version):
        sys.exit(f"error: invalid version {version!r}")
    if not SHA256_RE.fullmatch(sha256):
        sys.exit("error: sha256 must be 64 lowercase hex characters")

    with open(path) as f:
        text = f.read()
    text, n_version = re.subn(r'version "[^"]*"', lambda _: f'version "{version}"', text)
    text, n_sha = re.subn(r'sha256 "[^"]*"', lambda _: f'sha256 "{sha256}"', text)
    if n_version != 1 or n_sha != 1:
        sys.exit(
            f"error: {path}: expected exactly one version and one sha256 line, "
            f"found {n_version}/{n_sha}"
        )
    with open(path, "w") as f:
        f.write(text)
    print(f"Updated {path} to v{version}")


if __name__ == "__main__":
    main()
