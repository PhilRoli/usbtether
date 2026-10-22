#!/bin/bash
# Tests scripts/release-plan.sh against throwaway git repos.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILURES=0
gg() { git -c user.name=t -c user.email=t@t "$@"; }

# plan <commit> <event> [ref_name] [dry_run]: runs the plan at <commit> in $REPO and
# leaves its outputs in $TMP/out (key=value lines) and its stderr in $TMP/err.
plan() {
    git -C "$REPO" checkout -q "$1"
    : > "$TMP/out"
    PLAN_RC=0
    (cd "$REPO" && GITHUB_OUTPUT="$TMP/out" EVENT="$2" REF_NAME="${3:-main}" DRY_RUN="${4:-}" \
        RELEASE_PRECHECK=false "$HERE/release-plan.sh" >"$TMP/stdout" 2>"$TMP/err") || PLAN_RC=$?
}
get() { grep -m1 "^$1=" "$TMP/out" | cut -d= -f2- || true; }

# expect <name> <rc> <release> <mode> <version>: empty mode/version means "not checked".
expect() {
    local name="$1" rc="$2" release="${3:-}" mode="${4:-}" version="${5:-}" ok=1
    [ "$PLAN_RC" = "$rc" ] || ok=0
    if [ "$rc" = 0 ]; then
        [ "$(get release)" = "$release" ] || ok=0
        [ -z "$mode" ] || [ "$(get mode)" = "$mode" ] || ok=0
        [ -z "$version" ] || [ "$(get version)" = "$version" ] || ok=0
        [ -n "$(get reason)" ] || ok=0
    else
        grep -q . "$TMP/err" || ok=0
    fi
    if [ "$ok" = 1 ]; then
        echo "ok   $name"
    else
        echo "FAIL $name: rc=$PLAN_RC outputs: $(tr '\n' ' ' < "$TMP/out") stderr: $(tr '\n' ' ' < "$TMP/err")" >&2
        FAILURES=$((FAILURES + 1))
    fi
}

REPO="$TMP/repo"
mkdir -p "$REPO/scripts" "$REPO/app"
cp "$HERE/next-version.sh" "$REPO/scripts/"
git -C "$REPO" init -q
cd "$REPO"
echo 1 > Cargo.lock; echo a > app/Package.resolved; echo x > README
gg add -A; gg commit -qm base; gg tag v1.0.0
echo y > README; gg commit -qam docs; DOCS="$(git rev-parse HEAD)"
echo 2 > Cargo.lock; gg commit -qam "dep A"; A="$(git rev-parse HEAD)"
echo 3 > Cargo.lock; gg commit -qam "dep B"; B="$(git rev-parse HEAD)"
cd "$TMP"

plan "$A" workflow_run;  expect "dependency change since tag -> new patch release" 0 true new 1.0.1
[ "$(get tag)" = v1.0.1 ] && [ "$(get commit)" = "$A" ] || { echo "FAIL tag/commit outputs" >&2; FAILURES=$((FAILURES + 1)); }
plan "$A" schedule;      expect "schedule behaves like workflow_run" 0 true new 1.0.1
plan "$DOCS" workflow_run; expect "no dependency change since tag -> skip" 0 false

git -C "$REPO" -c user.name=t -c user.email=t@t tag v1.1.0 "$B"
plan "$B" schedule;      expect "tagged HEAD -> resume with that tag" 0 true resume 1.1.0
plan "$A" workflow_run;  expect "latest tag not an ancestor (old run) -> skip" 0 false
grep -q 'not an ancestor' "$TMP/stdout" || { echo "FAIL ancestor message missing" >&2; FAILURES=$((FAILURES + 1)); }

plan "$B" push v1.1.0-rc.1;  expect "tag push v1.1.0-rc.1 accepted" 0 true resume 1.1.0-rc.1
plan "$B" push v1.1.0-rc-1;  expect "tag push v1.1.0-rc-1 rejected" 1
plan "$B" push v1.1;         expect "tag push v1.1 rejected" 1
plan "$B" push v1.2.3;       expect "tag push v1.2.3 accepted" 0 true resume 1.2.3

plan "$B" workflow_dispatch "" true; expect "dispatch dry run" 0 true "" 0.0.0-dryrun
[ "$(get dry)" = true ] || { echo "FAIL dry output" >&2; FAILURES=$((FAILURES + 1)); }
plan "$B" workflow_dispatch "" false; expect "dispatch without dry run rejected" 1
plan "$B" bogus;                       expect "unknown event rejected" 1

# No stable tag yet: skip (first release is a manual tag push).
git -C "$REPO" tag -d v1.0.0 v1.1.0 >/dev/null
git -C "$REPO" tag v2.0.0-rc.1 "$A"
plan "$A" schedule; expect "no stable tag -> skip" 0 false
plan "$A" workflow_run; expect "no stable tag (prerelease tag only) -> skip" 0 false

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) failed" >&2
    exit 1
fi
echo "all release-plan tests passed"
