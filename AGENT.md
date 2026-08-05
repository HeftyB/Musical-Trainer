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

**M0–M13 are done. M14 is in progress — steps 0–3 of 6, planned in §7.23.** The subdivision
ladder, reframed to carry tempo with it because both move the same variable: the inter-onset
interval. PLAN.md §7 has the milestone table with an "as built" section for each; §7.13 is the
roadmap through M22.

| Done | |
|---|---|
| M0–M1 | Clock bridge validated, calibration |
| M2–M4 | `TimingCore`, groove engine, jam capture |
| M5–M8 | SwiftUI app, continuation drill, trends, tempo calibration |
| M9–M12 | Session builder, cold-vs-warm, recall drill, musical content |
| M13 | Experiment runner — preregistered A/B arms, no verdict before the declared n |
| T1 | Test infrastructure: the take factory, storage under test (§7.22) |

**§7.20 is the pre-M13 review** — eleven places where a number or a rule said more than it
could support, all closed. Read it before trusting any statistic here: four of the eleven were
the *enforcement* being fake rather than the code being wrong.

**§7.22 is M13 and T1 as built.** T1 is the test infrastructure that closed the gap finding 11
exposed — nothing had ever tested *writing* a take. It is not an M-number on purpose: it is a
different axis from product capability, and steps d–e of it are done.

**M13 has never run live.** The experiment block appears in the next planned session. Watch that
the arm text on screen matches the arm the debrief reports — the one defect step 4 found lived
exactly in the gap between two tested pieces.

The three *planned* sessions written up are §7.17 (4 Aug 2026), §7.19 (5 Aug morning) and §7.21
(5 Aug afternoon) — one manifest each on disk. Read them before touching drills: between them
they produced two instruction bugs, one reporting bug, and the project's only retracted finding
— none of them maths. Takes recorded from the drill menu since then are in the data but not
written up; 14 of the 21 jams carry no session placement, so they are invisible to
`review cold`.

## Surfaces

Both front ends drive `TrainerEngine`; neither contains measurement logic.

**App** (`./build-app.sh`): Session (a planned evening), six single-take modes — Jam, Form,
Alone, Tempo, Recall, Play — and History.

**CLI** (`./.build/release/TimingSpike <command>`): everything the app does, plus calibration
and the M0 diagnostics. `TimingSpike` with no argument prints the full command list; README.md
has the annotated table. The analysis readouts are `review trend | cold | content | feel |
tags | conditions | compare | form | dropout | tempo | experiment | interval`.

`render [bpm] [bars]` writes every ladder backing to `temp/renders` as a WAV. **A rung the
player has not heard is a rung the planner must not promote them onto** (§7.23), and this is how
that precondition is met without booking a live run.

## Environment constraints — check these before proposing a solution

- **No Docker on this workstation.** Andrew runs containers on his Proxmox nodes. Do not start
  a local daemon; write pipeline config and hand it over.
- **Git remote is self-hosted Gitea**, not GitHub. `gh` is not installed; pull requests are a
  browser step. CI is **Woodpecker**.
- **No macOS CI agent exists.** `.woodpecker/test.yaml` runs the Linux-buildable half — which
  is the 259 pure-module tests, because `Package.swift` excludes the Apple-only targets off
  macOS. `TrainerKitTests` (59 tests) is macOS-only and runs in `check.sh` alone, so a
  green pipeline covers less than a green gate.
  `.woodpecker/release.yaml.disabled` is parked until a dedicated Mac exists; it must not be
  pointed at this machine (a build during a take can perturb the render thread).
- **Not installed:** `swiftlint`, `swift-format`, `gh`, `tea`, `jq`, `shellcheck`. `scripts/check.sh`
  does the linting with grep, because the rules that matter here are project-specific anyway.
- **bash is 3.2** (macOS). No `mapfile`, no associative arrays, in hooks and scripts.

## Build, test, run

```sh
./scripts/check.sh                      # the gate — must pass before every commit
./scripts/install-hooks.sh              # once per clone, installs the tracked git hooks

swift test                              # 318 tests, no hardware needed
swift build -c release                  # CLI
./.build/release/TimingSpike selftest    # analysis maths vs synthetic ground truth
./build-app.sh && open "Musical Trainer.app"
```

Four test targets, and where each runs:

| Target | Runs | Covers |
|---|---|---|
| `TimingCoreTests` | everywhere, including CI | every analysis, against planted ground truth |
| `GrooveCoreTests` | everywhere, including CI | patterns, sequencer, backings |
| `TrainerKitTests` | **`check.sh` only — macOS** | storage, the clock-bridge reduction, config validation, session sequencing |
| `Tests/TestSupport` | not a test target | the shared generators every suite imports; add pathologies here, not per file |

`Tests/TrainerKitTests/TakeFactory.swift` builds stored takes of any type and
`StoreBackedTestCase` redirects storage into a temp directory — **subclass it rather than
calling `SessionStore.save` directly**, or a test will write into the real practice history.
`check.sh` fails if anything outside `Tests/` arms that redirect.

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
              Storage is tested by TrainerKitTests; audio and MIDI still are not.
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

## The codebase, in the order data moves through it

A take goes: **groove scheduled → MIDI captured → both clocks reduced to one timeline → notes
clustered → matched to a grid → analysed → stored → recomputed on every read.** Nothing reads a
stored summary back (R3.1); the review re-runs the analysis from raw taps, which is why a fix
reaches takes recorded before it.

| Stage | Where | What it is |
|---|---|---|
| Schedule the backing | `GrooveCore/Sequencer`, `Pattern`, `Library`, `LadderBackings` | Patterns in steps-per-bar; `Library` holds the named backings (`jamBacking`, `basicRock`), `LadderBackings` one groove per subdivision. **A pattern's step resolution is not the analysis grid** |
| Play it | `TrainerKit/GroovePlayer`, `DrumSynth`, `LiveInstrument` | Render callback owns the sample clock; synthesis is in-app, no samples |
| Capture keys | `TrainerKit/MIDIInput` | One CoreMIDI client per process, never disposed |
| Bridge the clocks | `TrainerKit/HostClock` (`SampleHostMap`), `JamAnalysis.reduce` | Least-squares fit of (hostTime, sample); calibration applied here, sign and all |
| Collapse chords | `TimingCore/TapClustering` | Near-simultaneous note-ons are one rhythmic event |
| Match to the grid | `TimingCore/Grid`, `Matching` | ±40% window (`Matching.defaultWindowFraction`); outside it is an *extra*, never a late note |
| Analyse | `TimingCore/TimingReport`, `WingKristofferson`, `DropoutAnalysis`, `FormAnalysis`, `TempoCalibration`, `TempoMemory`, `MusicalContent` | One analysis per drill, all pure |
| Quantify uncertainty | `TimingCore/Bootstrap`, `Statistics` | Three bootstraps, and picking the wrong one is a defect (R3.2) |
| Store | `TrainerKit/SessionStore` | One JSON per take; raw taps plus a summary nothing reads back |
| Aggregate | `TimingCore/TrendAnalysis`, `WarmUpAnalysis`, `ExperimentAnalysis` | Trends, cold-vs-warm, and the A/B readout |
| Decide what to practise | `TimingCore/SessionPlan` (`SessionPlanner`), `Experiment` | Builds the evening; `ExperimentSchedule` assigns arms |
| Run the evening | `TrainerKit/SessionRunner` | State machine over blocks; stamps placement and arm. Sequences, never measures |
| Drive it all | `TrainerKit/TrainerEngine` | `runJam` / `runForm` / `runDropout` / `runTempo` / `runMemory` — the **only** implementations of anything measured |
| Show it | `TrainerKit/Commands` (console), `Sources/MusicalTrainerApp` (SwiftUI) | Presentation only |

Types worth knowing before changing anything:

- **`Grid`** — index arithmetic, never accumulation. `subdivisions` is grid points per beat.
- **`IntervalRung`** — a rung of M14's ladder, and the tempo ceiling its matching window implies.
- **`TimingReport`** — what a jam produced. `subdivisionStats` is **phase-conditional** (where in
  the beat a note landed), not a measure of note values played.
- **`SessionPlacement`** — where a take sat in a planned evening. Optional; 14 of 21 jams have none.
- **`ExperimentAssignment`** — which experiment and arm a take belongs to. Optional.
- **`DrillInstructions.forBlock(_:)`** — the one mapping from a planned block to its instructions,
  arm included. Both surfaces call it; do not add a second.
- **`Stats.finite(_:)`** — every stored summary goes through it. `JSONEncoder` refuses a
  non-finite `Double` and a take was destroyed live because of it.

## What is not covered, and must be said rather than implied

- **Audio, MIDI and the drill runners have no tests.** `TrainerEngine.run*` past its config
  validation, `GroovePlayer`, `MIDIInput`, `AudioIO`, calibration — all verified only by a live
  run (R5.6), and the result recorded in PLAN.md.
- **`TrainerKitTests` cannot run in CI.** `TrainerKit` is macOS-only, so a green Woodpecker
  pipeline covers *less* than a green `check.sh`.
- **M13 has never run live.** See the warning above.
- **`selftest` covers the analysis pipeline against synthetic ground truth**, not storage — that
  moved to `TrainerKitTests` with T1.
- **Backings are tested for pattern structure only.** Whether a groove is playable-along-to is a
  live-run question.

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
- **Every take carries an optional `ExperimentAssignment`** — experiment id, name, arm, run
  index — written since M13 step 1 and read by nothing yet. Same reasoning as the two below: a
  take recorded without its arm is lost to the comparison for good.
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

Current as of 59 takes across 8 sittings — 21 jams, 12 form, 11 continuation, 8 tempo, 7 recall,
3 planned sessions. **Recompute rather than trusting any of this:** `review trend`,
`review dropout`, `review feel`, `review cold`, `review content`.

- **r₁ is positive in all 21 jams (+0.13 … +0.47).** He *under-corrects* — placement floats and
  wanders. He does not chase the click. Do not suggest counting harder; that is the documented
  way to make this worse, and he already reports it feels worse. The lowest reading in the whole
  set is +0.13, an untracked `relaxed` take on 3 Aug; the lowest in the *locked benchmark slot* —
  the only one a trend may be read from — is +0.20 on 5 Aug (§7.21), which is the direction §10
  defines as success. One take, in one slot.
- **The benchmark jam is bouncing, not trending**: 24.1 → 17.4 → 22.0 ms across three sittings
  at locked settings. §7.19 recorded the first step as a real tightening and it did not hold
  (§7.21). Each pairwise comparison was measured correctly; none of them is a trend. The 21-take
  jam trend remains flat on every metric.
- **A large placement shift held for one long sitting and then eased.** Bias went −5.9 ms on
  4 Aug to −22.6, −16.1, −20.8, −22.4 through the 5 Aug 01:00–04:30 sittings, then −15.1 and
  −13.5 that morning. Unexplained either way. Bias is not failure (§2) and spread did not move
  with it.
- **Clock is the looser half in every trustworthy split.** Do not pool across silence lengths:
  4-bar runs ~11–22 / 4–12 ms across five takes, 8-bar 40.7 / 20.9, 16-bar 22.1 / 6.8. Longer is
  a harder task. The newest 4-bar take has the lowest motor figure recorded (4.2 ms).
- **"Runs ~5% slow unaccompanied" is dead.** The last two 16-bar continuation takes produced
  99 BPM (−1%) and 100 BPM (−0%). Controlled cold probes read −7.9%, −4.2%, −3.3% and are still
  fitted flat; the −1.8% on 5 Aug was recorded *warm*, third in its sitting, and is not a fourth
  cold point however much it looks like one.
- **Feel tracks the measurement** (r = −0.66 over 19 rated takes) and reads "well calibrated" —
  but fatigue broke it once: two jams with identical spread rated 4 and 1 twenty minutes apart
  (§7.17). It has not recurred.
- **Tempo is not analysed anywhere.** It is only ever *controlled for* — trends split mixed-tempo
  groups and `review tags` warns about them. His stated hypothesis is that faster is easier to a
  point and that slow tempos make him rush, and no readout can currently ask it. The data cannot
  either: 16 jams at 100 BPM, 4 at 110 (all one evening, six minutes apart), 1 at 120. M14 is
  where this gets built — see §7.23, including why raw spread cannot be compared across tempos.
- **The recall drill's interference cost is not established.** §7.19 read it as the distractor
  *helping*; since the attrition rule landed (§7.20 finding 2), three of the four takes are
  withheld as non-comparable and one remains. Treat it as unmeasured, not as a direction.
- **M12's first data contradicts his hunch**: busier playing went with *looser* timing within a
  take, and the censoring bias runs against that result rather than producing it. His hunch is
  about the mode of playing across a take, which M12 cannot test and M13's `steady-vs-melodic`
  experiment is now collecting for.
- **Two tags now pool across tempos** — `focused` (100 and 110) and `relaxed` (100 and 120). Both
  are flagged as mixed pools at the point of display, which is the only reason they are not
  quietly wrong.
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

Checklists for the things with more than one moving part: **a drill** is STANDARDS.md §9.5,
**an experiment** is §9.5.1, **a finding** is §9.6. After a storage change, §9.3. After analysis
or audio, §9.2.

Inspecting the data is what `review` is for — `review list`, `review <n>`, and the readouts in
Surfaces above. Prefer it to reading the JSON: every readout recomputes from raw taps, so it
shows what the current analysis says rather than what was true when the take was recorded.

`./scripts/install-hooks.sh` once per clone, or none of the above is enforced.
