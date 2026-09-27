#!/usr/bin/env bash
# apply_check.sh — verify that patches/platform/*.patch apply cleanly against
# their pinned upstream sources (patches/platform/manifest.yaml).
#
# For each manifest entry:
#   1. fetch the pinned file(s) via the GitHub contents API (gh CLI), caching
#      bytes plus the API blob SHA under .cache/patch-refs/<owner>/<repo>/<ref>/;
#   2. verify content: `git hash-object` == manifest blob_sha == API blob SHA;
#   3. reconstruct a scratch git tree at the pinned state and run
#      `git apply --check` (a --3way fallback is probed and reported, but a
#      plain --check failure is always recorded as a failure);
#   4. write patches/platform/verify/<patch>.log and a stdout summary table.
#
# Every network-derived value (repo, ref, path) is validated against anchored
# regexes before it touches the filesystem: no absolute paths, no ".."
# components, constant-depth cache layout built only from validated
# components. Anything the manifest parser does not recognize aborts the run.
#
# Dependencies: bash, git, gh (authenticated), coreutils, awk.
# Usage: tools/patches/apply_check.sh [--offline]
#   --offline   serve everything from the cache; never touch the network.
# Exit status: 0 iff every manifest patch passes.

set -uo pipefail

usage() { echo "usage: $0 [--offline]" >&2; exit 2; }

OFFLINE=0
for arg in "$@"; do
    case "$arg" in
        --offline) OFFLINE=1 ;;
        *) usage ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$ROOT/patches/platform/manifest.yaml"
PATCH_DIR="$ROOT/patches/platform"
VERIFY_DIR="$ROOT/patches/platform/verify"
CACHE="$ROOT/.cache/patch-refs"

[ -f "$MANIFEST" ] || { echo "error: manifest not found: $MANIFEST" >&2; exit 2; }
mkdir -p "$VERIFY_DIR" "$CACHE"

# ---------------------------------------------------------------- parsing --
# Records are emitted as TAB-separated: id, patch, repo, ref, path, blob_sha.
# One line per (patch, file); the patch fields repeat per file.
MANIFEST_TSV="$(awk '
    /^patches:[[:space:]]*$/ { next }
    /^([[:space:]]*)#/ { next }
    /^[[:space:]]*$/ { next }
    /^- id: /       { id = $0; sub(/^- id: */, "", id)
                      pfile = ""; repo = ""; ref = ""; next }
    /^  patch: /    { pfile = $0; sub(/^  patch: */, "", pfile); next }
    /^  repo: /     { repo  = $0; sub(/^  repo: */, "", repo);  next }
    /^  ref: /      { ref   = $0; sub(/^  ref: */, "", ref);   next }
    /^  files:[[:space:]]*$/ { next }
    /^  - path: /   { path = $0; sub(/^  - path: */, "", path); sha = ""; next }
    /^    blob_sha: / { sha = $0; sub(/^    blob_sha: */, "", sha);
                        if (id != "" && pfile != "" && repo != "" && ref != "" &&
                            path != "" && sha != "")
                            printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, pfile, repo, ref, path, sha
                        else { print "manifest: incomplete entry near: " $0 > "/dev/stderr"; bad = 1 }
                        next }
    /./ { print "manifest parse error at line " NR ": " $0 > "/dev/stderr"; bad = 1 }
    END { exit bad ? 3 : 0 }
' "$MANIFEST")" || exit 3
[ -n "$MANIFEST_TSV" ] || { echo "error: manifest has no entries" >&2; exit 3; }

# ------------------------------------------------------------ validation --
die() { echo "error: $*" >&2; exit 2; }

valid_repo()  { [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; }
valid_ref()   { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$1" != *..* && "$1" != */ ]]; }
valid_sha()   { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
valid_id()    { [[ "$1" =~ ^[a-z0-9_]+$ ]]; }
valid_patch() { [[ "$1" =~ ^[A-Za-z0-9._-]+\.patch$ ]]; }

# Reject absolute paths, "..", empty/backslash/whitespace components.
valid_path() {
    local p="$1" comp
    [[ "$p" != /* && "$p" != *\\* && "$p" != *..* && -n "$p" ]] || return 1
    local IFS='/'
    for comp in $p; do
        [[ -n "$comp" && "$comp" != "." && "$comp" != ".." &&
           "$comp" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
    done
    return 0
}

# ------------------------------------------------- pass 1: content checks --
declare -a ORDER=()
declare -A SEEN=() P_PATCH=() P_REPO=() P_REF=() P_FILES=()

while IFS=$'\t' read -r id pfile repo ref path sha; do
    valid_id "$id"        || die "bad id in manifest: '$id'"
    valid_patch "$pfile"  || die "bad patch filename in manifest: '$pfile'"
    valid_repo "$repo"    || die "bad repo in manifest: '$repo'"
    valid_ref "$ref"      || die "bad ref in manifest: '$ref'"
    valid_path "$path"    || die "bad path in manifest: '$path'"
    valid_sha "$sha"      || die "bad blob_sha in manifest: '$sha'"
    [ -f "$PATCH_DIR/$pfile" ] || die "patch file missing: $PATCH_DIR/$pfile"

    if [ -z "${SEEN[$id]:-}" ]; then
        SEEN["$id"]=1
        ORDER+=("$id")
        P_PATCH["$id"]="$pfile"
        P_REPO["$id"]="$repo"
        P_REF["$id"]="$ref"
        P_FILES["$id"]=""
    fi
    P_FILES["$id"]+="${path} ${sha}"$'\n'
done <<< "$MANIFEST_TSV"

# fetch_one <owner/repo> <ref> <path> <expected-sha>
# Populates $CACHE/<owner>/<repo>/<ref>/<path> (plus a .sha sidecar) and
# prints the local git blob sha of the cached bytes. Returns nonzero when
# content cannot be provided or does not match <expected-sha>.
fetch_one() {
    local repo="$1" ref="$2" path="$3" want="$4"
    local dest="$CACHE/$repo/$ref/$path" api_sha="" local_sha=""

    if [ "$OFFLINE" -eq 0 ] && command -v gh >/dev/null 2>&1; then
        mkdir -p "$(dirname "$dest")"
        if api_sha="$(gh api "repos/$repo/contents/$path?ref=$ref" --jq .sha 2>/dev/null)" \
           && valid_sha "$api_sha" \
           && gh api -H "Accept: application/vnd.github.raw" \
                "repos/$repo/contents/$path?ref=$ref" > "$dest" 2>/dev/null \
           && [ -s "$dest" ]; then
            printf '%s\n' "$api_sha" > "$dest.sha"
        else
            api_sha=""
        fi
    fi

    if [ ! -s "$dest" ]; then
        echo "fetch: no network copy and no cache for $path" >&2
        return 1
    fi

    local_sha="$(git hash-object "$dest")"
    if [ "$local_sha" != "$want" ]; then
        echo "content: local=$local_sha want=$want for $path" >&2
        return 1
    fi
    if [ -n "$api_sha" ] && [ "$api_sha" != "$want" ]; then
        echo "content: api=$api_sha want=$want for $path" >&2
        return 1
    fi
    printf '%s\n' "$local_sha"
}

declare -A CONTENT_STATUS=()   # id -> ok|fail
declare -a CONTENT_FAILS=()
pass_count=0
fail_count=0

for id in "${ORDER[@]}"; do
    repo="${P_REPO[$id]}" ref="${P_REF[$id]}"
    CONTENT_STATUS["$id"]=ok
    while read -r path sha; do
        [ -n "$path" ] || continue
        if got="$(fetch_one "$repo" "$ref" "$path" "$sha")"; then
            echo "content OK   $id $path ($got)"
        else
            # distinguish a fetch/transport failure (no network copy, auth,
            # rate limit) from a real hash mismatch: fetch_one prints the
            # reason to stderr ("fetch: ..." vs "content: ...").
            if gh api "repos/$repo/contents/$path?ref=$ref" --jq .sha >/dev/null 2>&1 \
               || [ -s "$CACHE/$repo/$ref/$path" ]; then
                echo "content FAIL $id $path (hash mismatch against $repo@$ref)"
            else
                echo "fetch FAIL   $id $path (no authenticated API access and no cache; set GH_TOKEN or run --offline from a warm cache)"
            fi
            CONTENT_STATUS["$id"]=fail
            CONTENT_FAILS+=("$id $path")
        fi
    done <<< "${P_FILES[$id]}"
done

# ------------------------------------------------- pass 2: apply checks --
declare -a RESULTS=()

for id in "${ORDER[@]}"; do
    pfile="${P_PATCH[$id]}" repo="${P_REPO[$id]}" ref="${P_REF[$id]}"
    log="$VERIFY_DIR/$pfile.log"

    if [ "${CONTENT_STATUS[$id]}" != ok ]; then
        RESULTS+=("FAIL|$id|$pfile|$repo@$ref|content verification failed")
        fail_count=$((fail_count + 1))
        continue
    fi

    scratch="$(mktemp -d "${TMPDIR:-/tmp}/anvil-apply.XXXXXX")"
    git -C "$scratch" init -q -b main 2>/dev/null || git -C "$scratch" init -q
    git -C "$scratch" config user.name "anvil-apply-check"
    git -C "$scratch" config user.email "anvil-apply-check@invalid"
    git -C "$scratch" config commit.gpgsign false

    while read -r path sha; do
        [ -n "$path" ] || continue
        mkdir -p "$scratch/$(dirname "$path")"
        cp "$CACHE/$repo/$ref/$path" "$scratch/$path"
    done <<< "${P_FILES[$id]}"
    git -C "$scratch" add -A -f >/dev/null 2>&1

    {
        printf 'Anvil apply-check log\n'
        printf 'date (utc): %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'patch     : patches/platform/%s\n' "$pfile"
        printf 'taxonomy  : %s\n' "$id"
        printf 'upstream  : %s @ %s\n' "$repo" "$ref"
        printf 'harness   : tools/patches/apply_check.sh\n'
        printf '\n== pinned content ==\n'
        while read -r path sha; do
            [ -n "$path" ] || continue
            local_sha="$(git hash-object "$CACHE/$repo/$ref/$path")"
            api_sha="$(cat "$CACHE/$repo/$ref/$path.sha" 2>/dev/null || echo unavailable)"
            printf 'file: %s\n  manifest blob_sha    : %s\n  api blob_sha         : %s\n  git hash-object      : %s\n' \
                "$path" "$sha" "$api_sha" "$local_sha"
            if [ "$local_sha" = "$sha" ] && [ "$api_sha" = "$sha" ]; then
                printf '  match                : yes\n'
            else
                printf '  match                : NO\n'
            fi
        done <<< "${P_FILES[$id]}"
    } > "$log"

    apply_note=""
    if git -C "$scratch" apply --check "$PATCH_DIR/$pfile" >> "$log" 2>&1; then
        printf '\n== git apply --check ==\nPASS\n' >> "$log"
        printf 'result: PASS\n' >> "$log"
        RESULTS+=("PASS|$id|$pfile|$repo@$ref|clean apply")
        pass_count=$((pass_count + 1))
    else
        if git -C "$scratch" apply --check --3way "$PATCH_DIR/$pfile" >> "$log" 2>&1; then
            apply_note="plain --check FAILED; --3way probe succeeds (context drift, blobs present)"
        else
            apply_note="plain --check FAILED; --3way probe FAILED"
        fi
        printf '\n== git apply --check ==\nFAIL\nnote: %s\n' "$apply_note" >> "$log"
        printf 'result: FAIL\n' >> "$log"
        RESULTS+=("FAIL|$id|$pfile|$repo@$ref|$apply_note")
        fail_count=$((fail_count + 1))
    fi
    rm -rf "$scratch"
done

# ---------------------------------------------------------------- summary --
echo
echo "== apply-check summary =="
printf '%-6s %-42s %-24s %s\n' "RESULT" "TAXONOMY ID" "UPSTREAM" "PATCH"
for r in "${RESULTS[@]}"; do
    IFS='|' read -r status id pfile upstream note <<< "$r"
    printf '%-6s %-42s %-24s %s\n' "$status" "$id" "$upstream" "$pfile"
    [ "$status" = PASS ] || printf '       %s\n' "$note"
done
echo
echo "$pass_count passed, $fail_count failed (logs: patches/platform/verify/)"

[ "$fail_count" -eq 0 ]
