# Musical Trainer — agent guide

macOS app that trains an autonomous internal pulse. One user: Andrew, 25+ years playing,
theory-strong, timing is the weak axis.

Four documents, four jobs — putting content in the wrong one is a defect:

- **[PLAN.md](PLAN.md)** — design, rationale, findings, roadmap. **The reasoning lives here.**
- **[STANDARDS.md](STANDARDS.md)** — binding engineering rules and the procedures that enforce
  them. Read it before writing code.
- **AGENT.md** (this file) — the operating manual.
- **[README.md](README.md)** — what the app is and how to use it.

## Where the project is

**M0–M12 are done. M13 (experiment runner) is next.** PLAN.md §7 has the milestone table with
a "as built" section for each; §7.13 is the roadmap through M22.

| Done | |
|---|---|
| M0–M1 | Clock bridge validated, calibration |
| M2–M4 | `TimingCore`, groove engine, jam capture |
| M5–M8 | SwiftUI app, continuation drill, trends, tempo calibration |
| M9–M12 | Session builder, cold-vs-warm, recall drill, musical content |

**§7.20 is the current work queue** — a review before M13 that found eleven places where a number
or a rule says more than it can support, with the fix order and the M13 build order. Read it
before starting either.

The two live sessions are §7.17 (4 Aug 2026) and §7.19 (5 Aug, the most recent). Read them
before touching drills: between them they produced two instruction bugs, one reporting bug,
and the project's only retracted finding — none of them maths.

## Surfaces

Both front ends drive `TrainerEngine`; neither contains measurement logic.

**App** (`./build-app.sh`): Session (a planned evening), six single-take modes — Jam, Form,
Alone, Tempo, Recall, Play — and History.

**CLI** (`./.build/release/TimingSpike <command>`): everything the app does, plus calibration
and the M0 diagnostics. `TimingSpike` with no argument prints the full command list; README.md
has the annotated table. The analysis readouts are `review trend | cold | content | feel |
tags | conditions | compare | form | dropout | tempo`.

## Environment constraints — check these before proposing a solution

- **No Docker on this workstation.** Andrew runs containers on his Proxmox nodes. Do not start
  a local daemon; write pipeline config and hand it over.
- **Git remote is self-hosted Gitea**, not GitHub. `gh` is not installed; pull requests are a
  browser step. CI is **Woodpecker**.
- **No macOS CI agent exists.** `.woodpecker/test.yaml` runs the Linux-buildable half — which
  is all 187 tests, because `Package.swift` excludes the Apple-only targets off macOS.
  `.woodpecker/release.yaml.disabled` is parked until a dedicated Mac exists; it must not be
  pointed at this machine (a build during a take can perturb the render thread).
- **Not installed:** `swiftlint`, `swift-format`, `gh`, `tea`, `jq`, `shellcheck`. `scripts/check.sh`
  does the linting with grep, because the rules that matter here are project-specific anyway.
- **bash is 3.2** (macOS). No `mapfile`, no associative arrays, in hooks and scripts.

## Build, test, run

```sh
./scripts/check.sh                      # the gate — must pass before every commit
./scripts/install-hooks.sh              # once per clone, installs the tracked git hooks

swift test                              # 187 unit tests, no hardware needed
swift build -c release                  # CLI
./.build/release/TimingSpike selftest    # analysis maths vs synthetic ground truth
./build-app.sh && open "Musical Trainer.app"
```

**Run `selftest` after any change to analysis or audio.** It has caught six real defects that
would otherwise have surfaced as mysterious live-run failures. If it passes and a live run
fails, the fault is hardware or the clock bridge — not the maths. That separation is the
whole reason it exists.

Toolchain is **Xcode 14.2 / Swift 5.7 on Intel macOS 13**. Xcode 15 will not install on this
machine and is not needed; everything used is verified present in the MacOSX13.1 SDK. Do not
reach for newer language features.

## Module boundaries — these matter

```
TimingCore    pure analysis. NO AVFoundation, CoreMIDI, CoreAudio, or UI.
GrooveCore    pure pattern/sequencer/backing logic. Same purity rule.
TrainerKit    audio, MIDI, synthesis, calibration, sessions, drill runners, console layer.
TimingSpike   CLI front end (main.swift only).
MusicalTrainerApp  SwiftUI front end.
```

Two rules that keep this working:

1. **Anything analysable goes in TimingCore or GrooveCore**, because those run under
   `swift test` against data whose answer is known by construction. Logic that lives in the
   command layer cannot be tested and has repeatedly turned out to be wrong.
2. **Neither front end contains measurement logic.** `TrainerEngine.runJam` / `runForm` /
   `runDropout` / `runTempo` / `runMemory` are the only implementations, so the CLI and app
   can never measure differently. `SessionRunner` sequences them; it does not measure.

## Non-negotiables

- **The audio render thread is the only clock.** Never `Timer` or `DispatchSourceTimer` for
  beat timing. Beat positions come from index arithmetic (`round(n · fs · 60 / bpm)`), never
  from accumulating an interval — accumulation drifts, and a test proves index math doesn't.
- **Nothing in a render callback may allocate, lock, log, or touch ARC.** Render state lives
  behind a single `UnsafeMutablePointer`. Violating this produces glitches *and* timing
  artefacts that look like the player's own errors.
- **No numbers on screen during a take.** A live meter recruits exactly the analytical loop
  this project exists to quiet. One deliberate exception: the tempo drill, which *is* a
  feedback loop — and its feedback lands during click bars, never during a measured silence.
- **Rate before results.** The player rates a take 1–5 *before* seeing any number. A rating
  shown after the measurement is a rationalisation of it.
- **Bias is not failure.** Playing 20–40 ms ahead of a click is normal. Variance is the skill.
  Never conflate them in copy or scoring.

## Hard-won invariants

Each of these came from a real bug. Breaking one silently corrupts data.

| Invariant | What happened without it |
|---|---|
| One CoreMIDI client per process, never disposed | `MIDIServer` is on-demand; disposing the last client lets it exit, and the next create fails with −50. First take worked, second didn't. |
| Take length comes from the config, not the last scheduled sound | Drills ending in silence were truncated — the tempo drill lost its entire final round (9.6 s). |
| Collapse near-simultaneous onsets before measuring | One accidental double-hit turned a true 11 ms clock SD into 55 ms, and another into 92 ms. |
| Match against a *window*, never nearest-grid-point alone | A note 60% of a beat late snaps forward and reports as early — sign inverted. |
| Wing–Kristofferson needs isochronous, stationary input | Mixed note values produced a confident 143 ms "clock SD". Motor SD at 0 means the model hit its floor, not that the player is perfect. |
| Nothing louder than the groove except on the beat being marked | A crash one bar early made the form drill measure reaction to a decoy. Two takes wasted. |
| Confounds get named, not blended | A changed backing produced a "real" 8 ms spread change that was partly just different music. |

## Data and analysis conventions

- Sessions live in `~/Library/Application Support/MusicalTrainer/sessions/`, one JSON per
  take, prefixed `jam-` / `form-` / `dropout-` / `tempo-` / `memory-`, plus a `session-`
  manifest per planned session (what the planner chose, why, and what was skipped).
- **Every take carries an optional `SessionPlacement`** — session id, block index, role, and
  seconds elapsed into the sitting. That is what lets a cold take and a take twenty minutes in
  be told apart, and it is why M9 changed storage before it changed anything else.
- **Jam takes also store the raw note-ons** (`rawTimes` / `rawNotes` / `rawVelocities`) beside
  the clustered timing series, so *what* was played is recoverable and not just *when*.
  `review content` (M12) reads them; takes before 4 Aug 2026 have none and are skipped.
- **Raw taps are stored and everything recomputes from them.** Cached summary fields exist to
  keep the JSON readable but nothing reads them back. This is deliberate: analysis fixes reach
  takes recorded before the fix, which has already mattered twice.
- Uncertainty is not optional. Point estimates get bootstrap confidence intervals
  (`Bootstrap`), and comparisons say "real change" or "within noise". Within one take the
  bootstrap is **moving-block**, because asynchronies are serially correlated — that
  correlation is the r₁ the app reports. **Anything pooled across takes is two-stage**: takes
  resampled with replacement, then blocks within each. Picking the wrong one is a defect
  (STANDARDS R3.2); the pooled path had it wrong for three milestones (§7.20).
- When a measurement can't be trusted, say so and say why. `splitIsReliable`,
  `discardedTrials`, `unusableReason`, and the comparability notes all exist because a
  confident wrong number is worse than an honest gap.

## What the data says about this player

Current as of 51 takes across 6 sittings — 19 jams, 10 form, 10 continuation, 7 tempo, 5 recall,
3 planned sessions. The figures below predate the third planned session (5 Aug, 21.6 min),
whose takes are stored but not yet written up. **Recompute rather than trusting any of this:**
`review trend`, `review dropout`, `review feel`, `review cold`, `review content`.

- **r₁ is positive in all 17 jams (+0.13 … +0.47).** He *under-corrects* — placement floats and
  wanders. He does not chase the click. Do not suggest counting harder; that is the documented
  way to make this worse, and he already reports it feels worse.
- **The benchmark jam tightened for real**: 24.1 → 17.4 ms spread between the two planned
  sessions, bootstrapped interval [−9.41, −3.82], same device and calibration. Bias moved the
  other way in the same take, −5.9 → −22.6 ms. Variance is the skill; treat this as a good
  session with a large placement shift, not a mixed one. n = 2 — the 13-take trend is still flat.
- **Clock is the looser half in every trustworthy split.** Do not pool across silence lengths:
  4-bar gives ~14.9 / 9.3 ms, 8-bar 40.7 / 20.9, 16-bar 22.1 / 6.8. Longer is a harder task.
- **Unaccompanied tempo is converging on target.** Historically ~5% slow; the latest
  continuation take produced 99 BPM (−1%). The controlled cold probe read −7.9% then −4.0%.
- **Feel tracks the measurement** (r ≈ −0.63 over 13 rated takes) — but fatigue breaks it: two
  jams with identical spread were rated 4 and 1 twenty minutes apart (§7.17).
- **The recall drill's interference cost flipped sign** once he stopped playing through the
  silent waits (§7.19). The current reading is that a distractor *helps*, plausibly because an
  empty gap invites counting. Two takes per direction — do not state it as settled.
- **M12's first data contradicts his hunch**: busier playing went with *looser* timing within a
  take, and the censoring bias runs against that result rather than producing it. His hunch is
  about the mode of playing across a take, which M12 cannot test and M13 can.
- He thinks in feel and sound, not bar counts. He is a strong developer — pitch technical
  explanations high, but never explain music theory to him.

## Working style

- He commits and pushes himself (signed). **Do not commit.** Leave changes in the tree and say
  what's ready.
- **Commit messages are terse.** `<type>(<scope>): <subject>`, a short body of what changed,
  and `Refs: PLAN.md §<n>`. No rationale essays — the argument belongs in PLAN.md, which stays
  current, not in a log nobody re-reads. STANDARDS.md §8.2 has the format and the hook that
  enforces it.
- Two displays — `screencapture` may grab the wrong one. Ask for a screenshot instead of
  guessing what the UI looks like.
- Verify claims against the machine rather than asserting them. Several conclusions in this
  project were wrong until a probe was written; the probes are cheap and have paid for
  themselves every time.
- When results look surprising, **check the raw data before reporting them**. Two "findings"
  so far were measurement artefacts, and both were visible in the taps within a minute.
- **Say what you could not verify.** Hardware paths (audio, MIDI, the drill runners) have no
  unit tests and neither pipeline has ever been executed. Naming the gap is part of the work;
  implying coverage that does not exist is worse than the gap itself.

## Procedure

Full rules in [STANDARDS.md](STANDARDS.md); this is the short form.

1. **Branch.** `<type>/<short-description>`, same types as the commit format.
2. **Work.** Anything analysable goes in `TimingCore` or `GrooveCore` with a test that plants
   a known answer and recovers it.
3. **Write the message as you go.** `temp/current-git-commit-message.txt` (gitignored) holds
   the message for whatever is currently uncommitted, and is updated whenever the tree changes.
   A change you cannot describe yet is usually two changes. The `post-commit` hook empties it
   once that message lands, so a stale one never gets committed unread. If a change genuinely
   needs two commits, add `-2.txt` alongside it — STANDARDS.md §8.2.1, and rarely.
4. **Update the documentation — always a closing step.** Walk PLAN.md, AGENT.md, STANDARDS.md
   and README.md and correct anything the change made untrue. Re-derive any count or figure
   quoted in prose rather than trusting it; four separate accuracy passes have each found
   numbers copied forward unchecked.
5. **`./scripts/check.sh`** last. The pre-commit hook runs the fast half; run the whole thing
   after touching analysis or audio.
6. **Hand over.** Andrew commits and pushes; leave the tree ready and give him the commands.

**Run these to the end before starting the next change.** Every change updates PLAN.md and
usually AGENT.md, so two uncommitted changes put both sets of edits in the same files — and
`git add PLAN.md` cannot then stage one without the other. Splitting them afterwards means
editing one change's documentation back out, committing, and putting it back. That has already
cost two rounds of it in a single sitting (STANDARDS.md §8.2.2). Finish, hand over, then start.

Adding a drill has its own seven-step checklist — STANDARDS.md §9.5.

`./scripts/install-hooks.sh` once per clone, or none of the above is enforced.
