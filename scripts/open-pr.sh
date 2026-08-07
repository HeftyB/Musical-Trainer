#!/bin/bash
# Push the current branch and open its pull request, so a finished change arrives ready to
# review rather than waiting on a browser trip.
#
#   ./scripts/open-pr.sh                 # push, then open a PR against main
#   ./scripts/open-pr.sh --base <branch> # ...against a branch instead, for stacked work
#   ./scripts/open-pr.sh --dry-run       # print what would be sent, touch nothing
#
# The title is the last commit's subject and the body is temp/pr-message.md, which is written
# as part of the change like the commit message is (STANDARDS.md §8.1, §8.2.3).
#
# The token is read from the macOS keychain, falling back to $GITEA_TOKEN, and is never echoed
# or passed as an argument — arguments are visible to any user via `ps`. Same handling as
# publish-release.sh, which is the other script that talks to this API.
#
# Store it once:
#   security add-generic-password -s musical-trainer-gitea -a "$USER" -w
#
# Needs a Gitea token with write:repository.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="https://git.heftyb.com"
OWNER="HeftyB"
REPO="Musical-Trainer"
API="$HOST/api/v1/repos/$OWNER/$REPO"
BODY_FILE="temp/pr-message.md"

BASE="main"
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="${2:-}"; shift 2 || true ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "usage: $0 [--base <branch>] [--dry-run]" >&2; exit 1 ;;
    esac
done

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" != "$BASE" ] || { echo "Already on $BASE — nothing to open a PR for." >&2; exit 1; }
[ "$BRANCH" != "HEAD" ] || { echo "Detached HEAD; check out a branch first." >&2; exit 1; }

# A PR for a dirty tree describes something that was never pushed. §8.3 says a change is done
# when the gate passes and the documents are level; this is the last chance to notice it is not.
[ -z "$(git status --porcelain)" ] || {
    echo "Working tree is not clean. Commit first — a PR should describe what was pushed." >&2
    git status --short >&2
    exit 1
}

[ -s "$BODY_FILE" ] || {
    echo "$BODY_FILE is missing or empty." >&2
    echo "Write the PR body as part of the change — see STANDARDS.md §8.2.3 for its shape." >&2
    exit 1
}

AHEAD="$(git rev-list --count "$BASE..$BRANCH")"
[ "$AHEAD" -gt 0 ] || { echo "$BRANCH has nothing $BASE does not." >&2; exit 1; }

TITLE="$(git log -1 --pretty=%s)"

# Stacked branches are the normal shape here and the trap is silent: a PR against main carries
# every unmerged commit beneath it, so a four-line change can arrive as a two-thousand-line diff
# and the review it was meant to streamline gets harder. Say so rather than let it surprise.
if [ "$AHEAD" -gt 1 ] && [ "$BASE" = "main" ]; then
    echo "Note: $BRANCH is $AHEAD commits ahead of $BASE, so this PR will contain all of them:"
    git log --oneline "$BASE..$BRANCH" | sed 's/^/    /'
    echo "    If the earlier ones belong to their own PRs, merge those first, or use"
    echo "    --base <parent-branch> to review this change alone."
    echo ""
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Would push:  $BRANCH -> origin"
    echo "Would POST:  $API/pulls"
    echo "  head:  $BRANCH"
    echo "  base:  $BASE"
    echo "  title: $TITLE"
    echo "  body:  $BODY_FILE ($(wc -l < "$BODY_FILE" | tr -d ' ') lines)"
    exit 0
fi

TOKEN="$(security find-generic-password -s musical-trainer-gitea -w 2>/dev/null || true)"
[ -n "$TOKEN" ] || TOKEN="${GITEA_TOKEN:-}"
[ -n "$TOKEN" ] || {
    cat >&2 <<'EOF'
No Gitea token found.

Store one in the keychain — the -w flag prompts, so it never enters shell history:
  security add-generic-password -s musical-trainer-gitea -a "$USER" -w

Or export GITEA_TOKEN for this shell only.
EOF
    exit 1
}

echo "Pushing $BRANCH"
git push -u origin "$BRANCH"

# See publish-release.sh: the auth header goes in on stdin so the token stays out of `ps`.
api_call() {
    printf 'header = "Authorization: token %s"\n' "$TOKEN" | curl -sS -K - "$@"
}

PAYLOAD="$(TITLE="$TITLE" BASE="$BASE" HEAD="$BRANCH" BODY_FILE="$BODY_FILE" python3 -c '
import json, os
with open(os.environ["BODY_FILE"]) as f:
    body = f.read()
print(json.dumps({"title": os.environ["TITLE"], "body": body,
                  "head": os.environ["HEAD"], "base": os.environ["BASE"]}))')"

echo "Opening pull request against $BASE"
RESPONSE="$(api_call -X POST "$API/pulls" -H "Content-Type: application/json" -d "$PAYLOAD")"

printf '%s' "$RESPONSE" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.stderr.write("Gitea returned something that was not JSON.\n")
    sys.exit(1)
if isinstance(data, dict) and "html_url" in data:
    print("  " + data["html_url"])
else:
    message = data.get("message", data) if isinstance(data, dict) else data
    sys.stderr.write("Gitea said: %s\n" % message)
    sys.stderr.write("A pull request for this branch may already be open.\n")
    sys.exit(1)
'
