#!/bin/bash
# Tests scripts/update-cask.py against copies of the staged cask.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/update-cask.py"
SRC="$HERE/testdata/usbtether.rb"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$SRC" ] || { echo "fixture not found: $SRC" >&2; exit 2; }

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
    elif ! grep -q '^error:' "$TMP/err"; then
        fail "$name: stderr lacks an 'error:' message"
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

# version "x" inside the caveats text must never be rewritten when the real line is missing.
grep -v '^  version "' "$SRC" | sed 's/^      the first time/      the version "x" first time/;s/^      The first time/      The version "x" first time/' > "$TMP/caveat.rb"
grep -q 'version "x"' "$TMP/caveat.rb" || fail "fixture setup: caveat text not injected"
expect_reject "version only inside caveats text" "$TMP/caveat.rb" 1.2.3 "$SHA"

# CRLF line endings are preserved byte for byte outside the two lines.
sed 's/$/\r/' "$SRC" > "$TMP/crlf.rb"
if python3 -I "$SCRIPT" "$TMP/crlf.rb" 1.2.3 "$SHA" >/dev/null \
    && [ "$(grep -c $'\r$' "$TMP/crlf.rb")" = "$(wc -l < "$TMP/crlf.rb" | tr -d ' ')" ] \
    && grep -q "^  version \"1.2.3\"$(printf '\r')\$" "$TMP/crlf.rb"; then
    pass "CRLF endings preserved"
else
    fail "CRLF endings not preserved"
fi

# Mode and no stray temp files after a successful write.
chmod 640 "$TMP/ok.rb"
python3 -I "$SCRIPT" "$TMP/ok.rb" 1.2.4 "$SHA" >/dev/null
if [ "$(stat -f %Lp "$TMP/ok.rb" 2>/dev/null || stat -c %a "$TMP/ok.rb")" = 640 ] \
    && [ -z "$(find "$TMP" -name '.update-cask-*')" ]; then
    pass "file mode kept, no temp files left"
else
    fail "mode changed or temp file left behind"
fi

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
