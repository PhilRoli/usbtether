#!/bin/bash
# Prints the next patch version (without the leading v) to stdout.
# Latest stable tag vX.Y.Z -> X.Y.(Z+1); no stable tags -> 0.1.0.
# Tags containing '-' (prereleases) and non-version tags are ignored.
set -euo pipefail

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "next-version.sh: not inside a git repository" >&2
    exit 1
fi

latest=""
while IFS= read -r tag; do
    if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        latest="$tag"
        break
    fi
done < <(git tag --list 'v[0-9]*' --sort=-v:refname)

if [ -z "$latest" ]; then
    echo "0.1.0"
    exit 0
fi

IFS=. read -r major minor patch <<<"${latest#v}"
echo "$major.$minor.$((10#$patch + 1))"
