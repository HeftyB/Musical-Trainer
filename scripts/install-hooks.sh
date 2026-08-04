#!/bin/bash
# Point git at the tracked hooks in .githooks/. Run once per clone.
#
# Hooks are tracked in the repo rather than left in .git/hooks so the standard travels with
# the code instead of living only on one machine.
set -euo pipefail
cd "$(dirname "$0")/.."

chmod +x .githooks/* scripts/*.sh
git config core.hooksPath .githooks

echo "Hooks installed:"
for h in .githooks/*; do echo "  $(basename "$h")"; done
echo
echo "pre-commit runs ./scripts/check.sh --fast"
echo "commit-msg enforces STANDARDS.md §8.2"
