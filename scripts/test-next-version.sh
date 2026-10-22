#!/bin/bash
# Tests scripts/next-version.sh against throwaway git repos.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/next-version.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILURES=0
N=0

# check <expected> <tag>...: builds a repo with the given tags and asserts the output.
check() {
    local expected="$1"
    shift
    N=$((N + 1))
    local repo="$TMP/repo$N"
    mkdir "$repo"
    git -C "$repo" init -q
    git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    local tag
    for tag in "$@"; do
        git -C "$repo" -c user.name=t -c user.email=t@t tag "$tag"
    done
    local actual
    actual="$(cd "$repo" && "$SCRIPT")"
    if [ "$actual" = "$expected" ]; then
        echo "ok   tags [$*] -> $actual"
    else
        echo "FAIL tags [$*]: expected '$expected', got '$actual'" >&2
        FAILURES=$((FAILURES + 1))
    fi
}

check 0.1.0
check 1.2.4 v1.2.3
check 1.10.1 v1.2.3 v1.10.0
check 1.2.4 v1.2.3 v2.0.0-rc1
check 1.2.4 v1.2.3 v1.2.4-beta
check 1.2.4 v1.2.3 foo

# Annotated tags count like lightweight ones.
N=$((N + 1))
repo="$TMP/repo$N"
mkdir "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$repo" -c user.name=t -c user.email=t@t tag -a v3.4.5 -m release
if [ "$(cd "$repo" && "$SCRIPT")" = 3.4.6 ]; then
    echo "ok   annotated tag v3.4.5 -> 3.4.6"
else
    echo "FAIL annotated tag" >&2
    FAILURES=$((FAILURES + 1))
fi

# Shallow clones may lack tags: refuse instead of answering wrongly.
git clone -q --depth 1 "file://$repo" "$TMP/shallow" 2>/dev/null
if (cd "$TMP/shallow" && "$SCRIPT" >/dev/null 2>"$TMP/err"); then
    echo "FAIL shallow clone: expected non-zero exit" >&2
    FAILURES=$((FAILURES + 1))
elif grep -qi shallow "$TMP/err"; then
    echo "ok   shallow clone fails with message"
else
    echo "FAIL shallow clone: no shallow message on stderr" >&2
    FAILURES=$((FAILURES + 1))
fi

# Outside a git repo: must fail with a message on stderr.
mkdir "$TMP/plain"
if (cd "$TMP/plain" && GIT_CEILING_DIRECTORIES="$TMP" "$SCRIPT" >/dev/null 2>"$TMP/err"); then
    echo "FAIL outside a git repo: expected non-zero exit" >&2
    FAILURES=$((FAILURES + 1))
elif [ -s "$TMP/err" ]; then
    echo "ok   outside a git repo fails with message"
else
    echo "FAIL outside a git repo: no message on stderr" >&2
    FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) failed" >&2
    exit 1
fi
echo "all next-version tests passed"
