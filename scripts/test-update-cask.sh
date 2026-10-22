#!/bin/bash
# Tests scripts/update-cask.py against copies of the staged cask.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/update-cask.py"
SRC="${CASK_SRC:-$HERE/../../homebrew-tap/Casks/usbtether.rb}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$SRC" ] || { echo "staged cask not found: $SRC (set CASK_SRC)" >&2; exit 2; }

FAILURES=0
fail() { echo "FAIL $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "ok   $*"; }

SHA="$(printf 'a%.0s' $(seq 1 64))"

# Success: only the version and sha256 lines change.
cp "$SRC" "$TMP/ok.rb"
if python3 -I "$SCRIPT" "$TMP/ok.rb" 1.2.3 "$SHA" >/dev/null; then
    changed="$(diff "$SRC" "$TMP/ok.rb" | grep -c '^[<>]' || true)"
    if [ "$changed" = 4 ] \
        && grep -qx '  version "1.2.3"' "$TMP/ok.rb" \
        && grep -qx "  sha256 \"$SHA\"" "$TMP/ok.rb"; then
        pass "rewrites exactly the version and sha256 lines"
        diff "$SRC" "$TMP/ok.rb" | sed 's/^/       /' || true
    else
        fail "unexpected diff ($changed changed lines)"
    fi
else
    fail "valid update exited non-zero"
fi

# expect_reject <name> <file> <version> <sha>: must exit non-zero and leave the file untouched.
expect_reject() {
    local name="$1" file="$2" version="$3" sha="$4" before
    before="$(shasum -a 256 "$file")"
    if python3 -I "$SCRIPT" "$file" "$version" "$sha" >/dev/null 2>"$TMP/err"; then
        fail "$name: expected non-zero exit"
    elif [ ! -s "$TMP/err" ]; then
        fail "$name: no error message"
    elif [ "$(shasum -a 256 "$file")" != "$before" ]; then
        fail "$name: file was modified"
    else
        pass "$name rejected, file unmodified"
    fi
}

cp "$SRC" "$TMP/two.rb"
echo '  version "9.9.9"' >> "$TMP/two.rb"
expect_reject "two version lines" "$TMP/two.rb" 1.2.3 "$SHA"

cp "$SRC" "$TMP/twosha.rb"
echo "  sha256 \"$SHA\"" >> "$TMP/twosha.rb"
expect_reject "two sha256 lines" "$TMP/twosha.rb" 1.2.3 "$SHA"

grep -v '^  version "' "$SRC" > "$TMP/none.rb"
expect_reject "no version line" "$TMP/none.rb" 1.2.3 "$SHA"

cp "$SRC" "$TMP/bad.rb"
for v in "v1.2.3" "1.2" "1.2.3-" "1.2.3 x" '1.2.3"' ""; do
    expect_reject "bad version '$v'" "$TMP/bad.rb" "$v" "$SHA"
done
for s in "${SHA:1}" "${SHA}a" "$(printf 'A%.0s' $(seq 1 64))" "$(printf 'g%.0s' $(seq 1 64))" ""; do
    expect_reject "bad sha '${s:0:12}...'" "$TMP/bad.rb" 1.2.3 "$s"
done

# Prerelease versions are valid.
cp "$SRC" "$TMP/pre.rb"
if python3 -I "$SCRIPT" "$TMP/pre.rb" 1.2.3-rc.1 "$SHA" >/dev/null; then
    pass "prerelease version accepted"
else
    fail "prerelease version rejected"
fi

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) failed" >&2
    exit 1
fi
echo "all update-cask tests passed"
