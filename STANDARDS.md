# Musical Trainer — Engineering Standards

Binding rules for this repository. Where a rule has a cost, the cost is stated; where a rule
came from a real defect, the defect is named. Nothing here is style for its own sake.

**Enforcement:** `./scripts/check.sh` is the single gate. It must pass before every commit.
Install the hooks once with `./scripts/install-hooks.sh`.

---

## 0. Document map

Four documents, four jobs. Putting content in the wrong one is a defect.

| Document | Holds | Does not hold |
|---|---|---|
| `PLAN.md` | Design, rationale, findings, measured results, roadmap. **The reasoning lives here.** | Procedure, style |
| `AGENT.md` | Operating manual: how to build, run, and not break things | Rationale, roadmap |
| `STANDARDS.md` | These rules, and the procedures that enforce them | Design decisions |
| `README.md` | What the app is and how to use it | Anything internal |

**Reasoning does not go in commit messages.** A commit says *what changed*; `PLAN.md` says
*why it is right*. A reader wanting the argument should find it in one place that stays
current, not scattered across a log that never gets re-read.

Code comments carry a fifth job: **invariants and the defects that produced them.** A comment
explaining what a line does is noise; a comment explaining what breaks if the line changes is
the most valuable text in the file.

---

## 1. Architecture

### 1.1 Module boundaries

```
TimingCore          pure analysis            no AVFoundation/CoreMIDI/CoreAudio/UI, no I/O
GrooveCore          pure pattern generation  same, and no dependency on TimingCore
TrainerKit          audio, MIDI, storage, drill runners, console layer
TimingSpike         console front end (main.swift only)
MusicalTrainerApp   SwiftUI front end
```

**R1.1.1 — Anything analysable goes in `TimingCore` or `GrooveCore`.** Only those run under
`swift test` against data whose answer is known by construction. Logic in the command layer
cannot be tested and has repeatedly turned out to be wrong; the trend fitting lived there for
two milestones and was silently reading stale inputs the whole time.

**R1.1.2 — Neither front end contains measurement logic.** `TrainerEngine.run*` are the only
implementations of anything measured. `SessionRunner` sequences drills; it does not measure.

**R1.1.3 — `GrooveCore` depends on nothing, not even `TimingCore`.** It carries its own seeded
RNG rather than importing one. Independence of the two pure modules is worth more than a dozen
shared lines.

**R1.1.4 — Pure modules perform no I/O.** No `print`, no file access, no `Date()` in analysis
paths. Time is a parameter, never a side effect; a report that reads the clock cannot be tested.

### 1.2 Determinism

**R1.2.1 — All randomness is seeded.** `SplitMix64` and `GrooveRandom` take an explicit seed.
An interval or a distractor that changed between runs would make "real change" a coin flip.

**R1.2.2 — Identical inputs produce identical outputs.** Every analysis entry point is a pure
function of its arguments. If a result cannot be reproduced from stored data, it is not a
result.

---

## 2. Real-time safety

The audio render callback is the only clock in this project. These rules are absolute.

**R2.1 — The render thread is the only timing authority.** Never `Timer`,
`DispatchSourceTimer`, `CADisplayLink`, or `Thread.sleep` for beat timing.

**R2.2 — Beat positions come from index arithmetic**, `round(n · fs · 60 / bpm)`, never from
accumulating an interval. Accumulation drifts; a test proves index math does not.

**R2.3 — Nothing in a render callback may allocate, lock, log, or touch ARC.** Render state
lives behind a single `UnsafeMutablePointer`. Violating this produces glitches *and* timing
artefacts that look like the player's own errors — the worst possible failure mode, because it
corrupts the measurement while looking like data.

**R2.4 — Cross-thread communication is lock-free in the audio direction.** MIDI → audio goes
through a single-producer/single-consumer ring. The MIDI delivery thread may take an
`os_unfair_lock`; the render thread may not.

**R2.5 — The full sample↔host map is read only after the engine stops.** Live code reads entry
zero alone, which is written once and immutable thereafter.

---

## 3. Measurement integrity

The app exists to tell the player something true. A confident wrong number is worse than an
honest gap, and every rule here exists because that failed once.

**R3.1 — Raw inputs are stored; everything recomputes from them.** Cached summary fields exist
to keep stored JSON legible. **Nothing reads them back.** Enforced by `check.sh`.

> This was violated three times and each violation shipped. The trend, the app's history and
> `review list` all plotted pre-chord-clustering numbers for the earliest takes — a stored SD
> of 16.7 ms against 18.3 ms recomputed — and fitted slopes through the difference.

**R3.2 — Point estimates carry uncertainty.** Any reported comparison states an interval and
says "real change" or "within noise". The bootstrap is moving-block for serially correlated
series and plain for independent trials; using the wrong one is a defect, not a preference.

**R3.3 — When a measurement cannot be trusted, say so and say why.** `splitIsReliable`,
`discardedTrials`, `unusableReason` and the comparability notes are the pattern. Silence is not
an acceptable way to express low confidence.

**R3.4 — Confounds are named, never blended.** A group that mixes backings, tempos, devices,
difficulty levels or drill parameters says so at the point of display. Both surfaces must warn
identically.

**R3.5 — Drill parameters that feed a trend are locked.** The cold probe and the benchmark jam
never adapt. Every confound in this dataset arrived by a parameter changing between takes.

**R3.6 — Instructions are generated from the configuration that will actually run.** Static
text describing a cue the backing will not produce has cost two takes and one live session.

---

## 4. Swift style

**R4.1 — Swift 5.7, macOS 13, x86_64.** No newer language or SDK features. The toolchain is
Xcode 14.2 and will not be upgraded.

**R4.2 — Line length: 100 target, 120 hard limit.** Enforced.

**R4.3 — Four-space indentation, no tabs, no trailing whitespace, newline at EOF.** Enforced.

**R4.4 — Naming follows the Swift API Design Guidelines.** Types `UpperCamelCase`, everything
else `lowerCamelCase`. Acronyms keep their case (`bpm`, `midi`, `sdMs`).

**R4.5 — Access control is explicit and minimal.** Default to `internal`; `public` only for
what another module genuinely needs; `private` for implementation detail. A `public` symbol is
a commitment.

**R4.6 — Doc comments on every `public` symbol**, stating what it measures or does and any
constraint on its input. Units belong in the name or the comment, always.

**R4.7 — No force-unwrapping or `try!` in `Sources/`.** Tests may force-unwrap to fail loudly.
Where a value cannot be absent, prove it with `guard` and throw or return `nil`.

**R4.8 — Errors are thrown, not printed.** `SpikeError` carries a message the player can act
on. The front end decides how to show it.

**R4.9 — No warnings.** The build is warning-free and stays that way.

**R4.10 — Comment what breaks, not what happens.** Prefer "a crash one bar early inverts what
this measures" over "adds a crash".

---

## 5. Testing

**R5.1 — Every analysable behaviour has a test against synthetic data of known ground truth.**
Planting a known answer and recovering it is the only acceptable proof for a statistic.

**R5.2 — Test names state the claim.** `testBetweenSittingDifferencesDoNotLeakIntoTheWarmUpSlope`,
not `testWarmUp2`. The name is the specification.

**R5.3 — Test the failure the code exists to prevent.** For every rule with a "this went wrong
once" story, there is a test that fails if the fix is reverted.

**R5.4 — Tests are deterministic.** Seeded generators only. A flaky test is deleted or fixed
the day it flakes.

**R5.5 — `selftest` after any change to analysis or audio.** It validates the pipeline against
synthetic ground truth without hardware. If it passes and a live run fails, the fault is
hardware or the clock bridge, not the maths — that separation is the whole reason it exists.

**R5.6 — Hardware paths are verified by a live run**, and the result is recorded in `PLAN.md`.
Audio, MIDI and the drill runners cannot be unit tested; pretending otherwise is worse than
admitting the gap.

---

## 6. Data and schema

**R6.1 — Schema changes are additive.** New fields are `Optional`. Every take ever recorded
must continue to decode. Verified by running `review list` after any storage change.

**R6.2 — Never delete or rewrite a stored take.** They are primary data.

**R6.3 — Record what a future question will need, before the analysis exists.** Session
placement was stored before M10 could use it; pitch was stored before M12 could. A take
recorded without a field is lost to that question for good, and the cost of the field is bytes.

**R6.4 — Decode failures are reported, never swallowed.** Silently dropping unreadable sessions
is how a schema change quietly erases history.

---

## 7. Security and privacy

**R7.1 — The app is local-only.** No network calls, no analytics, no telemetry, no crash
reporting. Practice data never leaves the machine. Enforced by `check.sh`, which fails on
`URLSession`, `NWConnection` and `Network` imports.

**R7.2 — Zero third-party dependencies.** `Package.swift` declares none and adds none without
an explicit decision recorded in `PLAN.md`. Every dependency is code you did not read running
with your privileges.

**R7.3 — No secrets in the repository.** No keys, tokens, or credentials, including in test
fixtures. `check.sh` scans staged content for common key patterns.

**R7.4 — Player data stays in Application Support** at
`~/Library/Application Support/MusicalTrainer/`, and is never committed. `.gitignore` covers
scratch work; session JSON lives outside the repo by design.

**R7.5 — The `.app` is ad-hoc signed** so macOS keeps a stable TCC identity between builds.
The only entitlement requested is microphone access, used solely by calibration to record the
app's own test tone.

**R7.6 — Untrusted input is validated at the boundary.** Every drill config validates its
ranges and throws before any audio is scheduled. MIDI is bounds-checked; a device sending
malformed packets must not index out of range.

**R7.7 — Commits are signed.** SSH signing is configured; do not disable it.

---

## 8. Version control

### 8.1 Branching

`main` is always green — `check.sh` passes at every commit. Work that spans more than one
sitting goes on a branch named `<area>/<short-description>`.

### 8.2 Commit format

```
<type>(<scope>): <subject>

<body — what changed, imperative, wrapped at 72>

Refs: PLAN.md §<n>
```

**Types:** `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `chore`.

**Scopes:** `timing-core`, `groove-core`, `trainer-kit`, `app`, `cli`, `docs`, `build`.

**Rules:**

- Subject: imperative, no trailing period, ≤ 72 characters.
- Body: what changed and any consequence a reader needs. **No rationale essays** — the
  argument belongs in `PLAN.md`, and `Refs:` points at it.
- One logical change per commit. A milestone is one commit only if it is genuinely one change.
- A `fix:` body states the observable symptom in one line.
- Never mention tooling, agents, or how the change was produced.

Enforced by `.githooks/commit-msg`.

### 8.3 Definition of done

A change is done when all of the following are true:

1. `./scripts/check.sh` passes.
2. New analysable behaviour has tests that would fail without it.
3. `PLAN.md` records any design decision, finding, or measured result.
4. `AGENT.md` is accurate if the operating procedure changed.
5. `README.md` is accurate if a user-facing surface changed.
6. Any hardware path is exercised by a live run, or the gap is stated explicitly.

---

## 9. Procedures

### 9.1 Before every commit

```sh
./scripts/check.sh
```

### 9.2 After changing analysis or audio

```sh
swift build -c release && ./.build/release/TimingSpike selftest
```

### 9.3 After changing storage

```sh
./.build/release/TimingSpike review list     # every historical take must still decode
```

### 9.4 Releasing a build to yourself

```sh
./build-app.sh && open "Musical Trainer.app"
```

### 9.5 Adding a drill

1. Pattern/layout logic → `GrooveCore`, with tests.
2. Scoring → `TimingCore`, with tests against planted ground truth.
3. Runner → `TrainerEngine.run*`; storage type in `SessionStore` with optional fields.
4. Instructions → `DrillInstructions`, generated from the configuration that will run.
5. Both surfaces: CLI command and app mode.
6. Planner rule in `SessionPlanner`, with a test for when it must *not* fire.
7. `PLAN.md` section; `README.md` command table; `AGENT.md` if procedure changed.

### 9.6 Recording a finding

Findings go in `PLAN.md` with the numbers that support them, the sample size, and what would
falsify them. A finding without a sample size is an anecdote.
