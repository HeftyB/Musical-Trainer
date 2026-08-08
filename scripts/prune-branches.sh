#!/bin/bash
# Delete branches that are fully merged into main, locally and on the remote.
#
#   ./scripts/prune-branches.sh            # list what would go, delete nothing
#   ./scripts/prune-branches.sh --delete   # actually delete them
#   ./scripts/prune-branches.sh --delete --local-only
#
# **Listing is the default and deleting is the flag**, which is the opposite way round from most
# tools and deliberate: a branch is cheap to keep and a branch deleted by surprise is somebody's
# unpushed work. Nothing here touches a branch that is not an ancestor of the base.
#
# Why it exists: twenty-five merged branches accumulated over M19 alone. That is not untidiness for
# its own sake — `git branch` stops being readable, `--base <parent>` for stacked work gets harder
# to aim, and a branch name that still exists reads as work still in flight (STANDARDS.md §8.1).
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="main"
DELETE=0
REMOTE=1
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="${2:-}"; shift 2 || true ;;
        --delete) DELETE=1; shift ;;
        --local-only) REMOTE=0; shift ;;
        *) echo "usage: $0 [--base <branch>] [--delete] [--local-only]" >&2; exit 1 ;;
    esac
done

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'

CURRENT="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT" = "$BASE" ] || {
    echo "On $CURRENT. Switch to $BASE first — pruning from inside a branch is how the wrong" >&2
    echo "one goes." >&2
    exit 1
}

# Measure against the server's base for the same reason open-pr.sh does: `origin/<base>` is a cache,
# and a clone that has not pulled since the last merge would think a merged branch is unmerged —
# which here means keeping it, so the failure is safe rather than destructive. Said either way.
if ! git fetch -q --prune origin "$BASE" 2>/dev/null; then
    echo "${DIM}Could not fetch $BASE; judging against this clone's $BASE, which may be behind." \
         "Anything merged since your last pull will simply not be listed.${OFF}" >&2
    echo "" >&2
fi

# `--merged` is the whole safety property: a branch is listed only when its tip is an ancestor of
# the base, so every commit on it is already on main. An unmerged branch cannot appear here however
# stale its name looks.
MERGED="$(git branch --merged "$BASE" --format='%(refname:short)' \
          | grep -vxF "$BASE" | grep -vxF "$CURRENT" || true)"

if [ -z "$MERGED" ]; then
    printf '%sNothing to prune — every local branch has unmerged work.%s\n' "$GREEN" "$OFF"
    exit 0
fi

COUNT="$(echo "$MERGED" | wc -l | tr -d ' ')"
printf '%d branch(es) fully merged into %s:\n\n' "$COUNT" "$BASE"
echo "$MERGED" | sed 's/^/    /'
echo ""

if [ "$DELETE" -eq 0 ]; then
    printf '%sListed only. Pass --delete to remove them.%s\n' "$DIM" "$OFF"
    exit 0
fi

echo "$MERGED" | while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    # `-d`, never `-D`. If git refuses, the branch is not merged after all and that disagreement is
    # worth stopping for rather than forcing past.
    if git branch -d "$branch" >/dev/null 2>&1; then
        printf '  %sdeleted%s  %s\n' "$GREEN" "$OFF" "$branch"
    else
        printf '  %skept%s     %s — git refused; check it by hand\n' "$RED" "$OFF" "$branch"
        continue
    fi
    if [ "$REMOTE" -eq 1 ] && git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
        if git push -q origin --delete "$branch" 2>/dev/null; then
            printf '           %sorigin/%s%s\n' "$DIM" "$branch" "$OFF"
        else
            printf '           %scould not delete origin/%s — do it in the browser%s\n' \
                   "$DIM" "$branch" "$OFF"
        fi
    fi
done
