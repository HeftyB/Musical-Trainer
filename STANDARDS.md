# Musical Trainer — Engineering Standards

Binding rules for this repository. Where a rule has a cost, the cost is stated; where a rule
came from a real defect, the defect is named. Nothing here is style for its own sake.

**Enforcement:** `./scripts/check.sh` is the single gate. It must pass before every commit.
Install the hooks once with `./scripts/install-hooks.sh`.

---

## 0. Document map

Five documents, five jobs. Putting content in the wrong one is a defect.

| Document | Holds | Does not hold |
|---|---|---|
| `PLAN.md` | Design, rationale, findings, measured results, roadmap. **The reasoning lives here.** | Procedure, style |
| `AGENT.md` | Operating manual: how to build, run, and not break things | Rationale, roadmap |
| `STANDARDS.md` | These rules, and the procedures that enforce them | Design decisions |
| `LESSONS.md` | The catalogue of failure *shapes* — how things go wrong here, with the instance and the guard | A single defect's history, which is `PLAN.md`'s |
| `README.md` | What the app is and how to use it | Anything internal |

**Reasoning does not go in commit messages.** A commit says *what changed*; `PLAN.md` says
*why it is right*. A reader wanting the argument should find it in one place that stays
current, not scattered across a log that never gets re-read.

**`LESSONS.md` is cited by number and never renumbered.** Code comments and the other documents
refer to a shape by its number, so the numbering is an interface rather than an ordering.
`check.sh` fails when a citation names a shape the file does not define. A shape that turns out to
be wrong keeps its heading and has its body corrected, the way a retracted finding does.

The split between it and `PLAN.md` is a recurrence test: **one defect belongs in `PLAN.md`; the
second instance of the same mistake belongs in `LESSONS.md`.** §7.29 step 0 was the *fifth*
instance of one word with two meanings, and the paragraph explaining that distinction was already
sitting above the line that got it wrong — which is the argument for keeping a catalogue rather
than trusting that a comment will be read.

Code comments carry a sixth job: **invariants and the defects that produced them.** A comment
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
says "real change" or "within noise". Using the wrong bootstrap is a defect, not a preference:

| Data | Bootstrap |
|---|---|
| One serially correlated series (asynchronies within a take) | moving-block |
| Independent trials (drill rounds, minutes apart) | plain |
| Anything pooled across takes or sittings | **two-stage: resample takes, then blocks within each** |
| One value per take, compared across conditions | plain, over the per-take values |
| **A lag-1 autocorrelation, one take** | **not a block bootstrap** — `Bootstrap.lag1Interval` |
| A lag-1 autocorrelation, two takes | `Bootstrap.lag1Difference` — independent, so the variances add |
| A lag-1 autocorrelation, pooled or compared across takes | one value per take, resampled over takes |

`Bootstrap`'s block-resampling entry points take a `SeriesStatistic` — a closed set of `.mean` and
`.sd` — rather than any closure, so the wrong pairing cannot be written rather than merely being
forbidden. **Adding a case is a deliberate act and the question it forces is: does block resampling
preserve what this statistic measures?**

> The block bootstrap is self-defeating for r₁: every join between two resampled blocks is a pair
> that was never adjacent, so the statistic is attenuated by about `1/L` and the interval sits
> below the point estimate. Measured against planted AR(1) series, a nominal 95% interval covered
> the truth 25% of the time at r₁ = 0.64 — and 94% at r₁ = 0.15, which is why thirty takes went by
> without it showing. See PLAN.md §7.32.

> The third row shipped wrong for three milestones. Resampling only within takes leaves each
> take's mean frozen in every iteration, so the interval is blind to between-take variation —
> which is most of the variation. Over the two benchmark jams, whose means sit 16.7 ms apart,
> it produced an interval 6 ms wide and let `review conditions` call a difference real on that
> basis. See PLAN.md §7.20.

**R3.2.1 — A group of one take gets no interval.** The only variation inside a single take is
within-take variation, and offering it as a condition's uncertainty is the same defect in a
smaller form. Say why the number is missing.

**R3.3 — When a measurement cannot be trusted, say so and say why.** `splitIsReliable`,
`discardedTrials`, `unusableReason` and the comparability notes are the pattern. Silence is not
an acceptable way to express low confidence.

**R3.3.1 — A value that is untrustworthy under a condition is withheld at source, not flagged
for callers.** Return `nil` from the analysis; do not return the number beside a boolean and
expect every reader to check it.

> The recall drill's interference cost is derived in three independent places — the report, the
> history chart, and the planner's input. Built as a flag, two of the three were gated and the
> third was found only because a trend that should have moved did not. A value that is safe
> only when every caller remembers a precondition is R3.1's cached-summary defect in a new
> costume. See PLAN.md §7.20 finding 2.

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

**R5.7 — A rule in `check.sh` is verified by making it fail.** Add the rule, plant a violation,
watch it report FAIL, remove the violation, watch it report PASS. Reading the pattern is not
verification.

> The force-unwrap rule matched `!` only when followed by `.`, so eleven force-unwraps sat in
> `Sources` under a green PASS. Its replacement was then broken the same way — `[A-Za-z0-9_)\]]!`
> closes the bracket expression at the first `]`, because a backslash inside brackets is
> literal — and two rounds of checking at the shell missed it, because the shell and the script
> disagreed. Only planting a violation and running `check.sh` found it. See PLAN.md §7.20.
Audio, MIDI and the drill runners cannot be unit tested; pretending otherwise is worse than
admitting the gap.

**R5.8 — Every stored type has a round-trip test**: save it, load it back, recompute, and require
the report not to move. Add one with the type, not after the first take is lost.

> A whole class of defect lived where nothing had ever written a take. The encoder refusing a
> non-finite `Double` destroyed a form take live; a self-contradictory file trapped on read; two
> takes sharing a timestamp overwrote each other. One property catches all three. Tests write
> through `SessionStore.directoryOverride` into a temporary directory — never the player's
> history, which `check.sh` enforces. See PLAN.md §7.22.

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

### 8.1 Branching and review

`main` is always green — `check.sh` passes at every commit.

**The branch is the unit of work.** It is what gets planned, what gets reviewed, what gets rolled
out, and what the documentation is brought level with. Commits are the steps inside it. Getting
this backwards — treating the commit as the unit and the branch as its wrapper — produces a review
queue nobody can hold in their head and a history that reads as though nothing was ever planned.

> **This rule was in this document and broken nine times running**, PRs #23 to #31, every one of
> them a single commit. It was written as advice, and advice is what a productive afternoon
> ignores. `open-pr.sh` refuses a one-commit branch now unless `--single-commit` says it was meant
> — the same move as `Style.auditioned` being a flag and `check.sh` checking the quoted test
> counts. See `LESSONS.md` shape 21.

#### 8.1.1 Planning a branch

Before the first commit, decide three things and write them in `temp/pr-message.md` as you go:

1. **What whole thing this branch delivers.** Not "the next change" — a capability, a defect and
   the guard that closes it, a format and the two things that prove it, one milestone step. If it
   cannot be said in a sentence without "and also", it is two branches.
2. **The commits it will take, in order.** Two to six is the usual shape. Each is one logical
   change (§8.2.2), each leaves the gate green, and each is separately revertible.
3. **How it lands without breaking anything** — §8.1.2.

A branch is **too small** when its subject and its PR title are the same sentence, when the only
thing in "what this does not cover" is the rest of the same idea, or when the next branch has to
start by explaining the previous one. A branch is **too large** when a reviewer cannot hold its
argument in one sitting, when the commits stop being separately revertible, or when it has been
open long enough that `main` has moved underneath it.

Name it `<type>/<short-description>` using the same types as §8.2 — `feat/content-analysis`,
`fix/form-instructions`, `build/woodpecker`. Name it for the *work*, not for the first commit.

**Open the pull request when the branch is finished, not when the first commit lands.**

**One commit is a declared exception, not a default.** A retraction, a one-file fix, a lone
dependency bump: legitimate, and `open-pr.sh --single-commit` is where that judgement is recorded.
Arriving at one commit because the work was cut to fit is the thing this rule exists to stop.

#### 8.1.2 Rollout

**Every merge into `main` is a state the repository could sit in indefinitely.** Not merely green:
a branch may not leave a half-built feature reachable from a surface the player uses, and it may
not leave stored data in a shape nothing can read back.

Work that cannot land in one safe piece lands in several, in this order:

| Order | Lands | Why first |
|---|---|---|
| 1 | **Storage and identity** — new fields, optional, written by nothing | R6.3: a take recorded without a field is lost to that question for good, and an unused optional breaks nothing |
| 2 | **Analysis and grouping** — how the new data will be read | It has to be right *before* data exists, or the first takes are scored by a rule that then changes |
| 3 | **The mechanism** — the thing that produces the data | Now everything downstream of it already handles it |
| 4 | **The surfaces** — CLI, then app | Last, because a surface is what makes it reachable |

M19 step 7 is the worked example: `PlannedBacking` before the trend split, the trend split before
the CLI could produce a take, and the planner last of all. Each merge changed no behaviour the
player could see until the one that was supposed to.

Three rules for the parts that cannot be finished:

- **Gate rather than hide.** An unfinished capability is reachable only behind an explicit flag —
  `Style.auditioned`, `--probe` — and the flag's default is the safe answer. A capability that is
  merely undocumented is not gated.
- **State the gate in the PR.** "What this does not cover" is a required section, and it names what
  is unreachable and what turns it on.
- **Never leave a measurement half-wired.** A drill that records a take under a task it did not
  perform is worse than a drill that does not exist (§7.24 step 8). Either the whole path stores
  what it played, or none of it ships.

**Rolling back is part of planning it.** Each commit is separately revertible, so state in the PR
what reverting the branch would cost — usually nothing, sometimes stored takes that would no longer
decode, which is the case R6.1 exists to prevent arising.

**A finished branch opens its own pull request.** `./scripts/open-pr.sh` pushes it and creates
the PR from `temp/pr-message.md`, titled with the last commit's subject. The hand-over is one
line, and review starts from a written argument rather than from a diff and a guess:

```sh
git add -A && git commit -F temp/current-git-commit-message.txt && ./scripts/open-pr.sh
```

`--single-commit` declares that one commit really is the whole branch; without it a one-commit
branch is refused, and the refusal names the commit so the judgement is made against the actual
work rather than in the abstract. `--dry-run` prints what it would send and touches nothing.
`--base <branch>` targets a branch
instead of `main`, which is what stacked work needs — a PR against `main` carries every unmerged
commit beneath it, so a four-line change can arrive as a two-thousand-line diff and the review it
was meant to streamline gets harder. The script says so when it detects the case rather than
letting it surprise anyone.

It refuses a dirty tree and an empty body: a PR that describes something never pushed, or that
describes nothing, is worse than no PR. It fetches the base before counting how far ahead the
branch is, because `origin/<base>` is a cache and a clone that has not pulled since the last merge
measures against a base the server no longer has — that misreported a branch as three commits ahead
instead of two, listing one already on `main`.

**Use it for every hand-over, never a bare `git push`** — including for a second commit on a branch
that already had a pull request. Whether one is open is a fact about the server; a merged PR is
closed, so a push after it lands leaves nothing pending and the next PR has to be opened by hand.
`open-pr.sh` opens one if none exists and says so if one does, which is right in both cases.

It also notes a PR body with no `## Review notes` section, which §8.2.3 requires last: a warning
rather than a refusal, because the shape is a discipline and a gate here would only teach people to
paste the heading.

The verification pipeline runs on the PR and must be green before merge. Self-review is still
review: read the diff in the PR view before merging — it catches things the editor does not.

**Delete a branch once it is merged.** `./scripts/prune-branches.sh` lists every branch fully
merged into `main` and deletes them with `--delete`, locally and on the remote. Listing is the
default because a branch deleted by surprise is somebody's unpushed work, and it uses `git branch
-d` rather than `-D`, so a branch git disagrees about is kept and reported. Twenty-five accumulated
over M19 alone; a merged branch that still exists reads as work still in flight.

Merge with a merge commit, not a squash. The commits are already one-logical-change each, and
squashing them destroys that.

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

Enforced by `.githooks/commit-msg`. Note the hook measures line length in **bytes**, so an
em-dash or a `→` costs three against the 72 — wrap a little short rather than counting.

**The reference message is `695478d`** (`build(build): clear the rolling commit message once it
lands`). Read it before writing one. Its shape, which is the house style:

- **Prose paragraphs, never bullet lists.** One paragraph per distinct part of the change.
- **Open with the symptom, in the past tense, as something that happened** — not with the
  mechanism, and not with "this commit". *"The message file kept its contents after the commit
  that used it, so the next change inherited a message describing the previous one."*
- **Back it with the instance and its evidence, immediately.** *"That is not hypothetical: the
  §7.19 message was still in the file two changes later and was staged for a commit it did not
  describe."* A body that could have been written before the work was done is too abstract.
- **Then the mechanism, plainly**, including the one implementation detail a reader would
  otherwise wonder about, and why it is that way — *"using `git stripspace` so the comparison
  sees the message the way git stored it."*
- **Every later paragraph names its part and carries its own justification** — *"§8.2.1 also
  drops the `---` separator convention…"*, *"New §8.2.2: …"* — so the reader can stop at any
  paragraph boundary and have a whole thought.
- **Close on the cost that motivated it**, measured: *"which cost two rounds of exactly that
  while landing §7.20 and this."*
- Backticks for identifiers, `§` for sections, no headings, no bold, no "we".

The rule against rationale essays still binds. The argument for *why the design is right* lives
in `PLAN.md`; what belongs here is the symptom, the mechanism, and what it cost — the things a
reader needs when the log is the only thing in front of them.

### 8.2.1 The rolling commit message

`temp/current-git-commit-message.txt` always holds the message for whatever is currently
uncommitted. It is gitignored: it describes a change in progress, and once the change lands the
commit itself is the record.

- **Write it as soon as there is something to commit**, not at the end. A message you cannot
  write yet is a change you cannot yet describe, which usually means it is really two changes.
- **Update it whenever the working tree changes.** A stale message is worse than none, because
  it will be used.
- **Clearing it is automatic.** The `post-commit` hook compares what landed against the file
  and empties it when they match. A message left behind is worse than an empty file: the next
  change inherits it and `git commit -F` uses it unread, which has happened. The hook leaves
  the file alone when the commit was made some other way, so a message for still-uncommitted
  work survives a `git commit -m` on something else.
- Commit with `git commit -F temp/current-git-commit-message.txt` so the file that was reviewed
  is the message that lands.

**More than one commit, which is the normal case.** `git commit -F` reads the whole file, so
several messages cannot share one. A branch that lands as three commits has
`temp/current-git-commit-message.txt`, `-2.txt` and `-3.txt`, numbered in the order they will be
committed. Each file holds one message and nothing else — no `git add` lines, no separators,
nothing that would end up in the log if the file were used as-is. The hook clears whichever one
matched.

Write each one **when its commit is ready**, not all of them up front: a message you cannot write
yet is a commit whose boundary you have not found. If two of them say nearly the same thing, the
split is not real and they are one commit; if one of them needs "and also", it is two.

The commits stay one logical change each (§8.2.2) and the branch is what broadens (§8.1) — so a
handful of message files is the shape of a well-planned branch, not a warning sign. What *is* a
warning sign is a single file on a branch that took a week.

### 8.2.2 One branch at a time, and where the documentation goes

**Take a branch all the way to merge-ready before starting the next one.** Merge-ready means §8.3:
the gate passes, all five documents are level, the message files describe the commits, and
`temp/pr-message.md` makes the argument.

**Within a branch, the documentation lands with the commit that completes it, not with each
commit.** That is what makes a multi-commit branch practical here: `PLAN.md` and `AGENT.md` are
touched by nearly every change, so documenting each commit separately puts several changes' edits
in one file and no `git add` can separate them. Documenting the *branch* once, at the end, is one
coherent set of edits describing one coherent piece of work — which is what §8.1 says a branch is.

The code commits before it stay green and separately revertible; what they do not carry is prose
about a thing that is not finished yet.

> Three times while landing §7.31 a listening verdict had to ride along in an unrelated commit,
> because it arrived after the branch it belonged to had merged and the next branch was already
> editing the same section of `PLAN.md`. Each was named in the PR rather than passed off, and each
> was avoidable by the rule above: the verdict belonged to the branch still open, not to the one
> after it.

The mechanical reason is not obvious until it bites. Every change here updates
`PLAN.md` and usually `AGENT.md` — that is §8.3 item 4, and it is not optional. Do two *branches*
before merging either and both sets of edits are sitting in the same files, at which point
`git add PLAN.md` cannot stage one without the other. The commits can no longer be separated by
file, and splitting them means either hunk surgery or rewriting one change's documentation out
of the file, committing, and putting it back.

> This cost two rounds of exactly that surgery in one sitting: the §7.20 review and the step-0
> bootstrap fix were both written before either was committed, so the review's section and the
> fix's as-built subsection were interleaved in one `PLAN.md`, and the same again for the fix
> and the hook you are reading about. Both were separable only by hand.

So: finish the branch, merge it, then start the next. If something genuinely urgent arrives
mid-branch, branch for it off `main` rather than layering it on top — the cost of a branch is
nothing next to the cost of untangling two pieces of work out of one document.

`check.sh` warns when the tree is dirty and this file is missing or older than the most
recently changed file. It is a warning, not a failure: the standard is a discipline, not a
gate, and a gate here would only teach people to write the file badly.

### 8.2.3 Pull request bodies

Different job, different form. A commit message is read in a terminal beside forty others; a PR
body is read once, in a browser, by someone deciding whether the change is safe. So a PR body
**is** rich markdown — headings, tables, bold — where a commit message is plain prose.

The shape that works here:

- **Title**: what the *branch* delivers, which on a multi-commit branch is not any one commit's
  subject. `open-pr.sh` defaults it to the last commit's subject; override it in the browser when
  that is narrower than the work.
- **`## What this is`** — one paragraph, then a stat line: `3 commits · 6 files · +181 / −7 ·
  489 → 494 tests`.
- **`## How this lands`** on anything that arrives in stages — the commits in order, what each one
  leaves reachable, and what stays gated until a later branch (§8.1.2). One line per commit is
  usually enough; the point is that a reviewer can see the rollout rather than infer it.
- **The defect, then what it reported, then why the tests did not catch it.** Before-and-after
  goes in a table with the wrong numbers in bold. Quote the readout's own words where they are
  the tell.
- **The fix and its guard**, naming what fails if the fix is reverted.
- **What the data says now**, with the limits stated at least as loudly as the result — *"Read
  no further into these than that."*
- **`## Review notes`** last: the gate's output, what is byte-identical against what changed and
  why that is correct, what reverting the branch would cost, and what the change still does not
  cover. `open-pr.sh` says so when this heading is missing.

Write it in `temp/pr-message.md`, which is gitignored for the same reason the commit message
file is.

### 8.3 Definition of done

**Done is a property of the branch.** A commit inside it is done when the gate passes and its
message describes it; the branch is done when all of the following are true:

1. `./scripts/check.sh` passes — at every commit, not only the last.
2. New analysable behaviour has tests that would fail without it, checked by reverting it.
3. Any hardware path is exercised by a live run, or the gap is stated explicitly.
4. **Documentation is brought level with the code — this is a closing step, every time.**
   Walk all five documents and correct anything the change made untrue:
   - `PLAN.md` — design decisions, findings, measured results, milestone status
   - `AGENT.md` — operating procedure, environment constraints, project state
   - `STANDARDS.md` — a rule that changed, or a new procedure
   - `LESSONS.md` — only when the change was the **second** instance of a failure shape, or a
     new shape. One defect is a `PLAN.md` entry; a pattern is a `LESSONS.md` one
   - `README.md` — any user-facing surface, and the command table

   Counts and figures quoted in prose are claims like any other: re-derive them from the code
   rather than trusting the previous value. **Five separate doc-accuracy passes have each found
   stale numbers copied forward unchecked** — `LESSONS.md` shape 17, the failure mode of a
   project that documents well.

   `check.sh`'s **Documentation** section holds the mechanical half of this: the test counts
   quoted in `AGENT.md`, `STANDARDS.md` and `README.md` are re-derived and compared, and every
   `LESSONS.md` shape citation must resolve. That is the enforceable subset and nothing more —
   a figure a script cannot check is still yours to re-derive. Prefer writing claims a script
   *can* check.
5. `temp/current-git-commit-message.txt` describes exactly what is about to be committed.
6. `temp/pr-message.md` makes the argument for the branch as a whole (§8.2.3), including how it
   rolls out and what it deliberately leaves unreachable (§8.1.2).
7. The branch is a coherent piece of work rather than one change with a branch around it (§8.1.1).
   If it is genuinely one commit, `open-pr.sh --single-commit` records that judgement.

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

It checks all six stored types, not just the jams it lists, and **exits non-zero** if any file
fails to decode. `check.sh` reads that status. For most of its life this command printed a note
and exited 0, so the check could not fail.

### 9.4 Releasing a build to yourself

```sh
./build-app.sh && open "Musical Trainer.app"
```

### 9.4.1 Cutting a release

Releases are cut **locally and deliberately**, because there is no macOS CI agent and this
workstation must not become one — see `.woodpecker/release.yaml.disabled` for why.

```sh
git tag -s v0.2.0 -m 'v0.2.0'
./scripts/package-release.sh v0.2.0     # runs the full gate, then packages
git push origin v0.2.0
./scripts/publish-release.sh v0.2.0     # creates the Gitea release, uploads dist/
```

`package-release.sh` runs `check.sh` before it packages anything, so a release still cannot be
cut from an unverified tree. That guarantee comes from the script, not from CI, and survives
the absence of a Mac runner.

The Gitea token lives in the macOS keychain, never in the repository:

```sh
security add-generic-password -s musical-trainer-gitea -a "$USER" -w
```

When a dedicated macOS machine exists, rename `.woodpecker/release.yaml.disabled` back to
`release.yaml` and the last two steps become automatic on tag. **Do not point it at the
workstation**: a release build pegs every core for about a minute, and an unattended build
firing during a take could perturb the render thread and corrupt a measurement in a way that
looks like the player's own timing.

### 9.4.2 Continuous integration

| Pipeline | Runs on | Where | Covers |
|---|---|---|---|
| `.woodpecker/test.yaml` | push, PR | Linux container, `swift:5.7-jammy` | Hygiene, invariants, build, the 496 pure-module tests |
| `.woodpecker/release.yaml.disabled` | — | parked | Needs a macOS agent that does not exist yet |

**`TrainerKitTests` does not run in CI.** `TrainerKit` is macOS-only, so its 221 tests
run only in `./scripts/check.sh`, which the pre-commit hook enforces. A green pipeline therefore
covers less than a green `check.sh`, and saying so is the point: the gap that destroyed a take
existed because the split between tested and untested had stopped being visible.

The Linux leg is possible because `Package.swift` excludes the Apple-only targets off macOS.
That is the strictest available check of §1.1: an accidental `import AVFoundation` in a pure
module stops compiling rather than merely tripping a grep. Every test lives in `TimingCoreTests`
and `GrooveCoreTests`, so the Linux leg runs the whole suite.

What CI cannot cover today: `TrainerKit`, both front ends, `selftest`, and the stored-session
decode check. Those run in `./scripts/check.sh` locally, which the pre-commit hook enforces.

### 9.5 Adding a drill

1. Pattern/layout logic → `GrooveCore`, with tests.
2. Scoring → `TimingCore`, with tests against planted ground truth.
3. Runner → `TrainerEngine.run*`; storage type in `SessionStore` with optional fields.
4. Instructions → `DrillInstructions`, generated from the configuration that will run.
5. Both surfaces: CLI command and app mode.
6. Planner rule in `SessionPlanner`, with a test for when it must *not* fire.
7. `PLAN.md` section; `README.md` command table; `AGENT.md` if procedure changed.

### 9.5.1 Adding an experiment

1. Declare it in `ExperimentLibrary` with a **fixed** UUID. The arm schedule is seeded from the
   id; a fresh one each launch reshuffles an experiment already half collected.
2. Pick a metric a take can actually produce. One declared on a metric nothing derives collects
   takes forever while reporting "still collecting" — there is a test holding that line.
3. Set `takesPerArm` before any data exists, and do not revise it afterwards. That number is the
   stopping rule, and moving it once collection has started is optional stopping with extra steps.
4. If the arms differ only in what the player is *told*, write both texts in
   `DrillInstructions.jam(arm:)` — the instruction is then the independent variable, not a
   description of one.
5. Leave the benchmark and any other experiment's block alone (R3.5).
6. `PLAN.md` gets the question, the arms and what would falsify it, before the first take.

### 9.6 Recording a finding

Findings go in `PLAN.md` with the numbers that support them, the sample size, and what would
falsify them. A finding without a sample size is an anecdote.

### 9.6.1 The working itinerary

`temp/WORKING.md` is the scratch pad: **gitignored on purpose, and blunt on purpose.** It holds what
is in flight, what just landed, what comes next, and the questions waiting on an answer — so that a
session can start without asking for direction, and an agent arriving cold can see the state of play
in one read.

Being outside the repository is what lets it be useful. It can name a half-formed idea, an
unattractive option, or a doubt about work already merged. **Nothing in the tracked documents may
depend on it**, and anything that turns out to matter is moved into `PLAN.md` in the form that
belongs there. The public record stays professional; the scratch pad is where the thinking is
allowed to be untidy.

**It is rolled forward, not archived.** As a milestone closes, its finished items come out and the
work between milestones goes in, so that by the time a milestone is genuinely done the next one
already has a plan. A `WORKING.md` still listing last milestone's steps is a stale file, and a stale
one is worse than none — the next reader acts on it.

### 9.7 Keeping the templates current

The cross-project templates in `temp/Guidelines & Standards/` are where this repository's rules
become reusable somewhere else. They drift the moment a rule here changes and nobody carries it
across.

**When `STANDARDS.md`, `LESSONS.md` or `AGENT.md` changes materially, update the template in the
same branch.** Materially means a rule added, removed or reversed; a new failure shape; a change to
the document map or the procedures. Not a corrected figure, not a reworded sentence.

The templates are generalised, not copied: the rule travels, this project's instances stay here.
`LESSONS.md` is the model — the same shapes, with the specifics stripped out.

> This is the one procedure here with no gate behind it. The templates live outside the tree, so
> `check.sh` cannot see them, and until a project of their own exists this rule is enforced by
> whoever is reading it. `LESSONS.md` shape 21 says what that is worth; saying so is better than
> implying a guard that does not exist.

### 9.8 Recording a failure shape

When a defect is found, ask one question: **has this shape happened here before?**

- **No** — it goes in `PLAN.md` with its instance and its fix, and nowhere else. A single defect
  is not a pattern, and a catalogue that admits everything stops being read.
- **Yes** — add the new instance to the existing shape in `LESSONS.md`, with its numbers, beside
  the ones already there. Do not open a second entry: shape 1 is a loud warning because it lists
  four instances, and it would be four quiet ones if they had been filed separately.
- **Yes, but no shape describes it** — add one at the end, numbered next, never inserted. Give it
  the shape in one line, the real instance with its numbers, and the guard.

A shape earns its place by recurring, so the bar for a new one is that two instances already
exist. Shapes 18, 19 and 20 were each added when a milestone produced the second instance and no
existing shape fitted.

**Cite it from the code.** A comment saying `LESSONS.md` shape 10 at the site where that mistake
is available costs one line and is the only mechanism that puts the catalogue in front of someone
at the moment it matters. `check.sh` checks that every citation resolves.
