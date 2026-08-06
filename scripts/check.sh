#!/bin/bash
# The single verification gate. See STANDARDS.md.
#
#   ./scripts/check.sh          full run: hygiene, invariants, build, tests, selftest
#   ./scripts/check.sh --fast   skip the release build and selftest (pre-commit default)
#
# Exit code 0 means the tree meets the standard. Anything else means it does not.
#
# The static checks below exist because no Swift linter is installed on this machine and the
# rules that matter here are project-specific anyway — no linter knows that reading a cached
# summary field is a defect in this codebase.
set -uo pipefail
cd "$(dirname "$0")/.."

FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
FAILURES=0

pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$OFF" "$1"; }
fail() { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$1"; FAILURES=$((FAILURES + 1)); }
warn() { printf '  %sWARN%s  %s\n' "$YELLOW" "$OFF" "$1"; }
head2() { printf '\n%s\n%s\n' "$1" "$(printf '─%.0s' $(seq 1 ${#1}))"; }

SWIFT_FILES=$(find Sources Tests -name '*.swift')

# check <description> <command...>   — fails when the command produces any output
expect_empty() {
    local desc="$1"; shift
    local out
    out="$("$@" 2>/dev/null)"
    if [ -z "$out" ]; then
        pass "$desc"
    else
        fail "$desc"
        printf '%s%s%s\n' "$DIM" "$(echo "$out" | sed 's/^/        /' | head -12)" "$OFF"
    fi
}

grep_sources() { grep -rnE "$1" Sources --include='*.swift' "${@:2}"; }

# ── 1. Module purity (STANDARDS §1.1) ────────────────────────────────────────────
head2 "Module boundaries"

expect_empty "pure modules import no audio, MIDI or UI framework" \
    grep -rnE '^import (AVFoundation|CoreMIDI|CoreAudio|AudioToolbox|AppKit|SwiftUI|UIKit)' \
        Sources/TimingCore Sources/GrooveCore --include='*.swift'

expect_empty "GrooveCore does not depend on TimingCore" \
    grep -rn '^import TimingCore' Sources/GrooveCore --include='*.swift'

expect_empty "pure modules perform no console I/O" \
    grep -rnE '(^|[^a-zA-Z])(print|NSLog|debugPrint)\(' \
        Sources/TimingCore Sources/GrooveCore --include='*.swift'

expect_empty "pure modules do not read the clock" \
    grep -rnE 'Date\(\)|mach_absolute_time\(' \
        Sources/TimingCore Sources/GrooveCore --include='*.swift'

# ── 2. Real-time safety (STANDARDS §2) ───────────────────────────────────────────
head2 "Real-time safety"

expect_empty "no wall-clock timer is used for beat timing" \
    grep_sources '\b(Timer\.scheduledTimer|DispatchSourceTimer|CADisplayLink)\b'

expect_empty "audio engine files contain no logging" \
    grep -rnE '(^|[^a-zA-Z])(print|NSLog|debugPrint)\(' \
        Sources/TrainerKit/GroovePlayer.swift \
        Sources/TrainerKit/AudioIO.swift \
        Sources/TrainerKit/LiveInstrument.swift

# ── 3. Measurement integrity (STANDARDS §3.1) ────────────────────────────────────
head2 "Measurement integrity"

# The defect this catches shipped three times: history, trends and `review list` all plotted
# cached summaries that predate a later analysis fix. Reads must go through report().
expect_empty "no cached summary field is read outside SessionStore" \
    bash -c "grep -rnE '\\b(s|session|take|entry)\\.(sdAsynchronyMs|meanAsynchronyMs|lag1Autocorrelation|driftMsPerBeat|onFormCount|marksPlaced|tightCount|meanAbsFormErrorBars|phaseErrorMeanMs|slipBarsPerPhrase|clockSDms|motorSDms|pacedSDms|unpacedIntervalSDms|reentryErrorMeanMs|tempoBiasBpm|playedBpm|usableCount|meanErrorPercent|meanAbsErrorPercent|improvementPerRound|interferenceCost|silentMeanAbsErrorPercent|filledMeanAbsErrorPercent)\\b' Sources --include='*.swift' | grep -v 'SessionStore.swift'"

# The test suite writes takes, so it needs somewhere to write them that is not the player's
# practice history. That redirect must never be armed by shipping code: R6.2 says stored takes
# are primary data, and the one thing worse than an untested storage layer is a tested one that
# overwrites the data it exists to protect.
expect_empty "only tests redirect the session store" \
    grep -rn 'directoryOverride *=' Sources --include='*.swift'

# What a take is *scored* on and what the music is *authored* at are different quantities that
# happened to be the same number — both 4 — for the whole life of the project, so no test can
# tell them apart (LESSONS.md shape 9, a constant that happens to match). M19 re-voices every
# pattern onto a 24-step grid; reading the analysis grid off a pattern would silently re-score
# all thirty takes on record. A grep is the only guard that can bite before that lands.
# GrooveCore *must* read it — it is the sequencer. The rule is that the measurement layer must
# not: TrainerKit decides what a take is scored on, and that decision may not come from how the
# drums happen to be written. Comment lines are excluded so the doc comment explaining this rule
# does not trip it.
expect_empty "the analysis grid is never read off a pattern's step resolution" \
    bash -c "grep -rn '\.stepsPerBeat' Sources/TrainerKit --include='*.swift' | grep -vE ':[[:space:]]*(///|//)'"

# ── 4. Privacy and supply chain (STANDARDS §7) ───────────────────────────────────
head2 "Privacy and supply chain"

expect_empty "the app makes no network calls" \
    grep_sources '\b(URLSession|NWConnection|NWBrowser|CFStream|Network\.)\b'

expect_empty "no network framework is imported" \
    grep_sources '^import (Network|CFNetwork)'

if grep -q 'dependencies: \[$' Package.swift && \
   grep -A2 'let package' Package.swift | grep -q '\.package('; then
    fail "third-party dependencies declared in Package.swift"
else
    pass "zero third-party dependencies"
fi

expect_empty "no credential-shaped strings in the source tree" \
    grep_sources '(BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})'

# ── 5. Style (STANDARDS §4) ──────────────────────────────────────────────────────
head2 "Style"

LONG=$(echo "$SWIFT_FILES" | xargs awk 'length > 120 { printf "%s:%d (%d chars)\n", FILENAME, FNR, length }')
if [ -z "$LONG" ]; then pass "no line exceeds 120 characters"
else fail "lines exceed 120 characters"; printf '%s%s%s\n' "$DIM" "$(echo "$LONG" | sed 's/^/        /' | head -10)" "$OFF"; fi

NEAR=$(echo "$SWIFT_FILES" | xargs awk 'length > 100 && length <= 120 { n++ } END { print n+0 }')
[ "$NEAR" -gt 0 ] && warn "$NEAR line(s) over the 100-character target (limit is 120)"

expect_empty "no tab indentation" \
    bash -c "grep -rlP '^\\t' Sources Tests --include='*.swift' 2>/dev/null || grep -rl '	' Sources Tests --include='*.swift' 2>/dev/null"

expect_empty "no trailing whitespace" \
    grep -rn ' $' Sources Tests --include='*.swift'

MISSING_EOL=$(for f in $SWIFT_FILES; do [ -n "$(tail -c1 "$f")" ] && echo "$f"; done)
if [ -z "$MISSING_EOL" ]; then pass "every file ends with a newline"
else fail "files missing a trailing newline"; printf '%s%s%s\n' "$DIM" "$(echo "$MISSING_EOL" | sed 's/^/        /')" "$OFF"; fi

# The old pattern only matched a `!` followed by `.`, so it saw `x!.foo` and missed `x!` used
# as a value — which is most of them. Six lived in Sources while this reported PASS, including
# two implicitly-unwrapped node declarations. It now matches a postfix `!` after any identifier,
# `)` or `]`, which also catches `Type!` declarations.
#
# `!=` is excluded because that is not an unwrap. Prefix negation (`!ok`, `!$0.isEmpty`) never
# matches, since the character before the `!` is a space or a delimiter. A `!` inside a string
# literal would be a false positive; there are none today, and the honest fix if one appears is
# to reword the string rather than to loosen the rule back to uselessness.
#
# `]!` is its own alternative rather than a `\]` inside the bracket expression. Inside brackets
# a backslash is literal, so `[...\]]` closes the set at the first `]` and silently means
# something else entirely — a rule that looks right, matches nothing, and reports PASS. That is
# the same failure being fixed here, so it is worth not reintroducing while fixing it.
force_unwraps() {
    grep -rnE '(\btry!|[A-Za-z0-9_)]!|\]!)' Sources --include='*.swift' | grep -vE '!='
}
expect_empty "no force-unwrap or try! in Sources" force_unwraps

# ── 6. Build and test (STANDARDS §5) ─────────────────────────────────────────────
head2 "Build and test"

# Each command runs once and its output is captured. Piping straight into `grep -q` looks
# tidier and is wrong: grep exits on the first match, the upstream process takes SIGPIPE, and
# `pipefail` then reports a passing test run as a failure.
#
# Every failure branch below prints *something*. An earlier version only echoed lines matching
# `error:|XCTAssert`, so a run that died without either — SwiftPM losing the `.build` lock, a
# test binary that never launched — reported "tests failed" and nothing else, which is a dead
# end for whoever has to diagnose it.
detail() {
    local out="$1" pattern="$2"
    local lines
    lines=$(echo "$out" | grep -E "$pattern" | head -10)
    [ -z "$lines" ] && lines=$(echo "$out" | tail -15)
    [ -z "$(echo "$lines" | tr -d '[:space:]')" ] && lines="(the command produced no output)"
    printf '%s%s%s\n' "$DIM" "$(echo "$lines" | sed 's/^/        /')" "$OFF"
}

BUILD_OUT=$(swift build 2>&1); BUILD_STATUS=$?
if [ "$BUILD_STATUS" -eq 0 ] && ! echo "$BUILD_OUT" | grep -qE 'warning:|error:'; then
    pass "debug build is clean"
else
    fail "debug build failed or is not warning-free (exit $BUILD_STATUS)"
    detail "$BUILD_OUT" 'warning:|error:'
fi

# Both conditions matter. A zero exit with no summary line means the suite never ran, which is
# not the same thing as passing.
TEST_OUT=$(swift test 2>&1); TEST_STATUS=$?
TEST_SUMMARY=$(echo "$TEST_OUT" | grep -oE 'Executed [0-9]+ tests, with [0-9]+ failures?' | tail -1)
if [ "$TEST_STATUS" -eq 0 ] && echo "$TEST_SUMMARY" | grep -q 'with 0 failures'; then
    pass "all tests pass ($(echo "$TEST_SUMMARY" | grep -oE '[0-9]+' | head -1))"
elif [ -n "$TEST_SUMMARY" ]; then
    fail "tests failed — $TEST_SUMMARY"
    detail "$TEST_OUT" 'error:|XCTAssert|failed \('
else
    # No summary at all: the run did not finish. Retry once before reporting, because the
    # commonest cause is a transient SwiftPM lock rather than anything in the code — but say
    # so either way rather than quietly passing on the second attempt.
    warn "the test run produced no summary; retrying once"
    TEST_OUT=$(swift test 2>&1); TEST_STATUS=$?
    TEST_SUMMARY=$(echo "$TEST_OUT" | grep -oE 'Executed [0-9]+ tests, with [0-9]+ failures?' | tail -1)
    if [ "$TEST_STATUS" -eq 0 ] && echo "$TEST_SUMMARY" | grep -q 'with 0 failures'; then
        pass "all tests pass on retry ($(echo "$TEST_SUMMARY" | grep -oE '[0-9]+' | head -1))"
        warn "the first attempt did not complete — if this repeats, it is not transient"
    else
        fail "the test run did not complete (exit $TEST_STATUS)"
        detail "$TEST_OUT" 'error:|XCTAssert|Fatal|signal|lock'
    fi
fi

if [ "$FAST" -eq 0 ]; then
    RELEASE_OUT=$(swift build -c release 2>&1)
    if echo "$RELEASE_OUT" | grep -qE 'warning:|error:'; then
        fail "release build is not warning-free"
        echo "$RELEASE_OUT" | grep -E 'warning:|error:' | sed 's/^/        /' | head -10
    else
        pass "release build is clean"
    fi

    SELFTEST_OUT=$(./.build/release/TimingSpike selftest 2>&1)
    if echo "$SELFTEST_OUT" | grep -q 'Analysis pipeline verified'; then
        CHECKS=$(echo "$SELFTEST_OUT" | grep -c 'PASS')
        pass "selftest verifies the analysis pipeline ($CHECKS checks)"
    else
        fail "selftest did not verify the analysis pipeline"
    fi

    # STANDARDS §6.1: every take ever recorded must still decode.
    if ./.build/release/TimingSpike review list >/dev/null 2>&1; then
        pass "stored sessions still decode"
    else
        fail "stored sessions failed to decode — a schema change broke history"
    fi
else
    printf '  %sSKIP%s  release build, selftest and decode check (--fast)\n' "$DIM" "$OFF"
fi

# ── 7. Workflow (STANDARDS §8.2.1) ───────────────────────────────────────────────
head2 "Workflow"

MSG="temp/current-git-commit-message.txt"
DIRTY="$(git status --porcelain 2>/dev/null | grep -v '^??' || true)"
if [ -z "$DIRTY" ]; then
    pass "working tree is clean"
elif [ ! -s "$MSG" ]; then
    warn "$MSG is missing or empty — write the message for the change in progress"
else
    # A message older than the code it describes has been overtaken by events.
    NEWEST="$(git status --porcelain | grep -v '^??' | awk '{print $NF}' \
              | while IFS= read -r f; do [ -f "$f" ] && echo "$f"; done \
              | xargs -I{} stat -f '%m {}' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    if [ -n "$NEWEST" ] && [ "$NEWEST" -nt "$MSG" ]; then
        warn "$MSG is older than $NEWEST — update it before committing"
    else
        pass "commit message describes the current tree"
    fi
fi

# ── Verdict ──────────────────────────────────────────────────────────────────────
echo
if [ "$FAILURES" -eq 0 ]; then
    printf '%sReady to commit.%s\n' "$GREEN" "$OFF"
    exit 0
fi
printf '%s%d check(s) failed.%s See STANDARDS.md.\n' "$RED" "$FAILURES" "$OFF"
exit 1
