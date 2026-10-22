#!/bin/bash
# Decides whether and what to release. Run inside a checkout of the commit under
# consideration with full history and tags.
#
# Inputs (env): EVENT (push|workflow_run|schedule|workflow_dispatch), REF_NAME
# (the pushed tag, for push), DRY_RUN (dispatch), HEAD_SHA (default: HEAD).
# Optional: RELEASE_PRECHECK=false disables the best-effort "already released"
# lookup (it uses gh, GH_TOKEN, GH_REPO and OWNER, and is skipped when unknown).
#
# Outputs (key=value, appended to $GITHUB_OUTPUT, default stdout):
#   release=true|false  reason  [mode=new|resume  version  tag  dry  commit]
# mode new: the tag does not exist yet. resume: it exists (tag push, or HEAD is
# already tagged), so publishing only creates or completes the release.
set -euo pipefail

EVENT="${EVENT:?EVENT is required}"
REF_NAME="${REF_NAME:-}"
DRY_RUN="${DRY_RUN:-}"
RELEASE_PRECHECK="${RELEASE_PRECHECK:-true}"
OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"
HEAD_SHA="${HEAD_SHA:-$(git rev-parse HEAD)}"

stable_re='^v[0-9]+\.[0-9]+\.[0-9]+$'
# Same version syntax as scripts/package.sh.
tag_re='^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$'

out() { echo "$1=$2" >> "$OUTPUT"; }
skip() {
    echo "$1"
    out release false
    out reason "$1"
    exit 0
}

dry=false
mode=new
case "$EVENT" in
    push)
        if [[ ! "$REF_NAME" =~ $tag_re ]]; then
            echo "Tag $REF_NAME is not vMAJOR.MINOR.PATCH[-suffix]" >&2
            exit 1
        fi
        mode=resume
        tag="$REF_NAME"
        version="${tag#v}"
        ;;
    workflow_run | schedule)
        head_tags="$(git tag --points-at "$HEAD_SHA")"
        stable_head="$(grep -E "$stable_re" <<<"$head_tags" | sort -V | tail -n 1 || true)"
        if [ -n "$stable_head" ]; then
            mode=resume
            tag="$stable_head"
            version="${tag#v}"
        else
            latest=""
            while IFS= read -r t; do
                if [[ "$t" =~ $stable_re ]]; then latest="$t"; break; fi
            done < <(git tag --list 'v[0-9]*' --sort=-v:refname)
            if [ -z "$latest" ]; then
                skip "No stable tag yet (the first release is a manual v0.1.0 tag push), skipping."
            fi
            if ! git merge-base --is-ancestor "$latest" "$HEAD_SHA"; then
                skip "Latest tag $latest is not an ancestor of $HEAD_SHA; refusing to release older code."
            fi
            rc=0
            git diff --quiet "$latest" "$HEAD_SHA" -- Cargo.lock app/Package.resolved || rc=$?
            case "$rc" in
                0) skip "No dependency change since $latest, skipping." ;;
                1) ;;
                *) echo "git diff failed" >&2; exit 1 ;;
            esac
            version="$("$(dirname "$0")/next-version.sh")"
            tag="v$version"
        fi
        ;;
    workflow_dispatch)
        if [ "$DRY_RUN" != "true" ]; then
            echo "workflow_dispatch only supports dry runs; push a v* tag to release." >&2
            exit 1
        fi
        dry=true
        version=0.0.0-dryrun
        tag="v$version"
        ;;
    *)
        echo "Unexpected event $EVENT" >&2
        exit 1
        ;;
esac

# Best-effort: nothing to do if the release has its asset and the cask is current.
# Any lookup failure (private tap, no gh) means unknown, so the release proceeds.
if [ "$mode" = resume ] && [ "$RELEASE_PRECHECK" = true ] && command -v gh >/dev/null 2>&1; then
    zip="UsbTether-$version.zip"
    if assets="$(gh release view "$tag" --json assets --jq '.assets[].name' 2>/dev/null)" \
        && grep -Fxq "$zip" <<<"$assets"; then
        if [[ "$version" == *-* ]]; then
            skip "$tag is already released (prerelease, tap untouched), skipping."
        fi
        if content="$(gh api "repos/${OWNER:?OWNER is required}/homebrew-tap/contents/Casks/usbtether.rb" --jq .content 2>/dev/null)" \
            && cask="$(base64 --decode <<<"$content" 2>/dev/null)" \
            && current="$(grep -m1 -E '^  version "' <<<"$cask" | cut -d'"' -f2)" \
            && [ "$current" = "$version" ]; then
            skip "$tag is already released and the cask is at $version, skipping."
        fi
    fi
fi

reason="Release $tag (mode=$mode, dry=$dry)"
echo "$reason"
out release true
out reason "$reason"
out mode "$mode"
out version "$version"
out tag "$tag"
out dry "$dry"
out commit "$HEAD_SHA"
