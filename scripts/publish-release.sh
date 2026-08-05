#!/bin/bash
# Create a Gitea release for a tag and upload the artifacts in dist/.
#
#   ./scripts/package-release.sh v0.2.0     # build first — this script does not
#   git push origin v0.2.0
#   ./scripts/publish-release.sh v0.2.0
#
# This is the manual half of the release procedure while there is no macOS CI agent. See
# STANDARDS.md §9.4.1 and .woodpecker/release.yaml.disabled for why that is deliberate.
#
# The token is read from the macOS keychain, falling back to $GITEA_TOKEN. It is never written
# to the repository, never echoed, and never passed as a command-line argument — arguments are
# visible to any user via `ps`, so curl reads its auth header from stdin instead.
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
DIST="dist"
API="$HOST/api/v1/repos/$OWNER/$REPO"

TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: $0 <tag>    e.g. $0 v0.2.0" >&2; exit 1; }

git rev-parse "$TAG" >/dev/null 2>&1 || {
    echo "Tag $TAG does not exist locally. Create it first:" >&2
    echo "  git tag -s $TAG -m '$TAG'" >&2
    exit 1
}

git ls-remote --tags origin "refs/tags/$TAG" | grep -q "$TAG" || {
    echo "Tag $TAG is not on origin. A release can only point at a pushed tag:" >&2
    echo "  git push origin $TAG" >&2
    exit 1
}

[ -d "$DIST" ] && [ -n "$(ls -A "$DIST" 2>/dev/null)" ] || {
    echo "$DIST/ is empty. Build the artifacts first:" >&2
    echo "  ./scripts/package-release.sh $TAG" >&2
    exit 1
}

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

# curl reads the auth header from a config on stdin, keeping the token out of the process
# argument list. `--fail-with-body` is not in macOS curl 7.79, so status is checked by hand.
api_call() {
    printf 'header = "Authorization: token %s"\n' "$TOKEN" | curl -sS -K - "$@"
}

echo "Creating release $TAG on $OWNER/$REPO"
NOTES="$(cat "$DIST/VERSION.txt" 2>/dev/null || echo "$TAG")"
PAYLOAD="$(TAG="$TAG" NOTES="$NOTES" python3 -c '
import json, os
print(json.dumps({"tag_name": os.environ["TAG"], "name": os.environ["TAG"],
                  "body": os.environ["NOTES"], "draft": False, "prerelease": False}))')"

RESPONSE="$(api_call -X POST "$API/releases" \
    -H "Content-Type: application/json" -d "$PAYLOAD")"

RELEASE_ID="$(printf '%s' "$RESPONSE" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.stderr.write("Gitea returned something that was not JSON.\n")
    sys.exit(1)
if isinstance(data, dict) and "id" in data:
    print(data["id"])
else:
    message = data.get("message", data) if isinstance(data, dict) else data
    sys.stderr.write("Gitea said: %s\n" % message)
    sys.exit(1)
')" || {
    echo "Could not create the release — one for $TAG may already exist." >&2
    exit 1
}

FAILED=0
for file in "$DIST"/*; do
    [ -f "$file" ] || continue
    name="$(basename "$file")"
    printf '  %-40s ' "$name"
    code="$(api_call -o /dev/null -w '%{http_code}' \
        -X POST "$API/releases/$RELEASE_ID/assets?name=$name" \
        -F "attachment=@$file")"
    if [ "$code" = "201" ] || [ "$code" = "200" ]; then
        echo "ok"
    else
        echo "FAILED (HTTP $code)"
        FAILED=$((FAILED + 1))
    fi
done

echo
if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED asset(s) failed to upload. The release exists but is incomplete:" >&2
    echo "  $HOST/$OWNER/$REPO/releases/tag/$TAG" >&2
    exit 1
fi
echo "Published: $HOST/$OWNER/$REPO/releases/tag/$TAG"
