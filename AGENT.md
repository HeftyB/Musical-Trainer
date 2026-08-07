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

**M0–M15 are built. M14 has had one live run; M15 has had two swung takes and one offbeat take.**

M14 (§7.23) is the interval ladder — subdivision and tempo built as one axis, because both move
the inter-onset interval. M15 (§7.24) is the feels: where within the beat a note is *expected*,
plus the offbeat drill. PLAN.md §7 has the milestone table with an "as built" section for each;
§7.13 is the roadmap through M22, plus M23 (jazz timing, deferred behind the instrument
milestones for the reason given there) and M24 (voice — onsets from the microphone, no
instrument, and the only milestone that can ask whether the "clock" this project measures is
the timekeeper or partly the hands) and M25 (harmony — its own milestone because a key and a
progression are a different problem from rhythm, with the framework for it already in
`Hit.note`).

**M19 is in progress** (§7.29), ahead of M16 because a 32-bar phrase needs a backing that
sustains 32 bars and M16.5's organ bubble needs the pattern format settled. Steps 0 and 1 are
done and changed no audio by design: the grid a free jam is scored on is a named constant rather
than the drum programming's resolution, and every arrangement now speaks **one grid of 24 steps
to the beat** so a triplet section and a straight one can share a piece of music. Patterns are
still authored at whatever reads naturally and `Arrangement` lifts them.

The band now has a **bass** — `BackingVoice.bass`, pitch on the hit, `BassSynth` — and a
**style format**: layers that enter at an intensity, plus fills, `playerVoices` for M20 and
`density` for M21/M24. `rock` and `motown` are authored. **Nothing frozen carries any of it** and
no planner or drill can reach a style yet; `jamBacking` is the music every take was measured
against and stays exactly as it is. Hear all of it with `render`, which writes `bass-demo` and
every style at every intensity.

**A style that clips is heard as bad playing, not as a bad gain.** `StyleHeadroomTests` mixes the
real buffers at 100 and 160 BPM — a mix goes hot because voices stack, and a style that clears
the rails at 100 can exceed them where sixteenths overlap.

`StyleArranger` turns a style into a piece from a **seed**, and `BackingIdentity` writes that seed
into `grooveName` as `motown@000000005eed0001` — no schema change, and a name without an `@` is a
fixed backing, which is every take before M19. **A generated backing that could not be rebuilt
from what was stored would make every take played over it unexplainable** (R1.2.2), so the seed
is not optional bookkeeping.

**Renders are reproducible as of §7.29 step 2 and were not before.** `Pattern.make` sorted its
hits by dictionary order, which Swift seeds per process, so the same backing rendered to
different bytes run to run. Any byte-comparison of audio taken before that fix is worth less
than it looks.

**Any change to a pattern must keep `CommonGridTests` green** — it compares every hit's sample
position before and after the lift, at three tempos and four feels, and a one-step drift fails it
3,265 times. The nineteen WAVs `render` writes are the other half of that gate.

**Anything can be tried from the CLI without corrupting a ladder.** `--probe`, anywhere on the
line, records a take as a deliberate look at a setting that was not earned — form level 3, a rung
above the ceiling, an offbeat level. Nothing that decides what to practise next reads one, and
`review form` marks it `*`. **A bad probe is data, not a demotion.**

```sh
./.build/release/TimingSpike form 100 64 8 3 --probe
```

The planner deliberately does **not** propose probes. A testing affordance in the planner is a
testing affordance in the business logic, changing what the app recommends to a player who is not
testing anything; the first version of §7.26 did exactly that and was removed. Same reason the
GUI has no probe control: the app is for playing.

| Done | |
|---|---|
| M0–M1 | Clock bridge validated, calibration |
| M2–M4 | `TimingCore`, groove engine, jam capture |
| M5–M8 | SwiftUI app, continuation drill, trends, tempo calibration |
| M9–M12 | Session builder, cold-vs-warm, recall drill, musical content |
| M13 | Experiment runner — preregistered A/B arms, no verdict before the declared n |
| M14 | Interval ladder — rungs, tempo ceilings, a tempo-rotating block, `slow-vs-fast` (§7.23) |
| M15 | The feels — a grid that expects the offbeat late, swing measured as placement, the offbeat drill (§7.24) |
| T1 | Test infrastructure: the take factory, storage under test (§7.22) |

**§7.20 is the pre-M13 review** — eleven places where a number or a rule said more than it
could support, all closed. Read it before trusting any statistic here: four of the eleven were
the *enforcement* being fake rather than the code being wrong.

**§7.22 is M13 and T1 as built.** T1 is the test infrastructure that closed the gap finding 11
exposed — nothing had ever tested *writing* a take. It is not an M-number on purpose: it is a
different axis from product capability, and steps d–e of it are done.

**What has and has not been played.** M14 ran once, on 5 August: the chain held end to end
(`rung=quarters → ladder-quarters → subdivisions=1 → tag=ladder`) and the experiment take was
stamped. **That sitting's timing data is not usable** — it was played exhausted and is recorded
as such in §7.24. M15 has three live takes, all in the small hours of 6 August and all tagged
`tired`: two swung jams (§7.24 step 7) and one offbeat take at level 0 (§7.24 step 8). **Both
sittings found a defect no test could, and both were the same gap** — between the path a live
take runs and the path a stored take is read back on. The swung takes were scored on a straight
grid; the offbeat take's own result did not survive being saved. Nothing has yet been played
above eighths, and no offbeat take has been held rather than slipped.

Three things to watch on the next session, all in the gap between tested pieces where every
defect of this shape has lived:

- the **arm text** on screen matches the arm the debrief reports;
- the **rung and feel** the block preview announces match what the take is stored with;
- at offbeat level 3, a report of "slipped" on a take that *felt* fine means the phrase marker
  is not doing its job (§7.24 step 6). At level 0 it has already meant the feel genuinely went.

No backing above eighths has been played along to — only rendered and heard. The swung backings
have been heard and confirmed as a shuffle; nobody has played *along* to one.

The three *planned* sessions written up are §7.17 (4 Aug 2026), §7.19 (5 Aug morning) and §7.21
(5 Aug afternoon) — one manifest each on disk. Read them before touching drills: between them
they produced two instruction bugs, one reporting bug, and the project's only retracted finding
— none of them maths. Takes recorded from the drill menu since then are in the data but not
written up; **17 of the 30 jams carry no session placement**. That does not hide them from
`review cold`, which infers sittings from 45-minute gaps between takes and reports all 30 across
10 sittings — what it costs is the distinction between a *controlled* cold probe and whatever
happened to be played first, which is why that readout carries a warning saying so.

## Surfaces

Both front ends drive `TrainerEngine`; neither contains measurement logic.

**App** (`./build-app.sh`): Session (a planned evening), six single-take modes — Jam, Form,
Alone, Tempo, Recall, Play — and History. Jam, Alone and Tempo carry a **subdivision picker**
that offers only the rungs the chosen tempo can score honestly, and a Jam on a binary rung can
also be **swung**. The offbeat drill is CLI-only so far.

**CLI** (`./.build/release/TimingSpike <command>`): everything the app does, plus calibration
and the M0 diagnostics. `TimingSpike` with no argument prints the full command list; README.md
has the annotated table. The analysis readouts are `review trend | cold | content | feel |
tags | conditions | compare | form | dropout | tempo | experiment | interval`.
Drills: `jam | form | dropout | tempo | memory | offbeat | session`.

`render [bpm] [bars]` writes every ladder backing to `temp/renders` as a WAV. **A rung the
player has not heard is a rung the planner must not promote them onto** (§7.23), and this is how
that precondition is met without booking a live run.

## Environment constraints — check these before proposing a solution

- **No Docker on this workstation.** Andrew runs containers on his Proxmox nodes. Do not start
  a local daemon; write pipeline config and hand it over.
- **Git remote is self-hosted Gitea**, not GitHub. `gh` is not installed; pull requests are a
  browser step. CI is **Woodpecker**, and it runs: pipeline #42 went green on `main` in about a
  minute (clone, verify, purity). The domain resolves only from Andrew's internal DNS, so an
  agent cannot fetch it or read the remote — take his word for what merged, and look commits up
  locally by hash.
- **No macOS CI agent exists.** `.woodpecker/test.yaml` runs the Linux-buildable half — which
  is the 434 pure-module tests, because `Package.swift` excludes the Apple-only targets off
  macOS. `TrainerKitTests` (157 tests) is macOS-only and runs in `check.sh` alone, so a
  green pipeline covers less than a green gate.
  `.woodpecker/release.yaml.disabled` is parked until a dedicated Mac exists; it must not be
  pointed at this machine (a build during a take can perturb the render thread).
- **Not installed:** `swiftlint`, `swift-format`, `gh`, `tea`, `jq`, `shellcheck`. `scripts/check.sh`
  does the linting with grep, because the rules that matter here are project-specific anyway.
- **bash is 3.2** (macOS). No `mapfile`, no associative arrays, in hooks and scripts.

## Input hardware — what a drill may assume

Only the first row is what every take on record was measured through. The rest are **owned but
never yet used for measurement**, so treat them as untested paths, not as capability.

| Input | Status | Path |
|---|---|---|
| Launchkey (keys + pads) | **In use.** Every take ever recorded | CoreMIDI — driver timestamps, validated in M0 |
| TS→USB audio adapter | Owned, cheap, works | Electric guitar, bass, amplifiers, and the TDV6 drum module's line out |
| External microphone | Owned, used for recording | Vocal capture, and the calibration test tone |
| USB→MIDI interface for the drums | **Planned purchase** | Would put the drum module on the MIDI path |
| Better audio interface | Planned purchase | Replaces the TS→USB adapter |

Three things follow, and they change what the roadmap costs:

- **M21's guitar hardware is no longer missing.** PLAN §7.13 said guitar was the one milestone
  needing hardware he does not own; the TS→USB adapter closes that. What it does not close is
  the measurement question — see below.
- **A cheap adapter is fine if its latency is *stable*.** Magnitude is calibrated away and only
  shifts bias; variable buffering adds jitter, and jitter is the skill metric. So the adapter has
  to be characterised for *spread*, not for offset, before any number through it is trusted.
- **The drum module on MIDI is a different milestone from drums on audio.** With the planned
  USB→MIDI interface the kit sends note-ons with driver timestamps — the path M0 already
  validated — and needs no onset detection at all. Through the TS→USB line out it is an audio
  problem. Same instrument, entirely different measurement quality.

**Headphones are a hard requirement for anything vocal** (M24), and the reason is feedback, not
just bleed: an open microphone and a speaker in one room is a howl, and the drill would be
unusable before it was inaccurate.

## Build, test, run

```sh
./scripts/check.sh                      # the gate — must pass before every commit
./scripts/install-hooks.sh              # once per clone, installs the tracked git hooks

swift test                              # 594 tests, no hardware needed
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

**After changing a stored property on a shared type, `swift package clean` before trusting a
failure.** Test objects compiled against the old struct layout fail on code that has not
changed — the tell is `git diff` showing the failing file untouched. It has cost two debugging
rounds in M15 alone and is recorded in PLAN §7.23 step 0 and §7.24 step 2.

**Never run a drill command to check its arguments.** `jam`, `offbeat`, `dropout`, `tempo` and
`memory` open an audio device and wait. Argument handling lives in `parseRung`, `parseFeel` and
each config's `validate()` precisely so a test can reach it — §7.22 records a test that played a
two-and-a-half-minute drill through the speakers, and §7.24 step 5 records the same mistake made
from a shell.

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
| Schedule the backing | `GrooveCore/Sequencer`, `Pattern`, `Library`, `LadderBackings` | Patterns in steps-per-bar; `Library` holds the named backings (`jamBacking`, `basicRock`), `LadderBackings` one groove per subdivision, keyed by `notesPerBeat`. **A pattern's step resolution is not the analysis grid** — three of the four ladder backings report `stepsPerBeat` 4, so the backing cannot tell the rungs apart and the grid must come from the rung |
| Play it | `TrainerKit/GroovePlayer`, `DrumSynth`, `LiveInstrument` | Render callback owns the sample clock; synthesis is in-app, no samples |
| Capture keys | `TrainerKit/MIDIInput` | One CoreMIDI client per process, never disposed |
| Bridge the clocks | `TrainerKit/HostClock` (`SampleHostMap`), `JamAnalysis.reduce` | Least-squares fit of (hostTime, sample); calibration applied here, sign and all |
| Collapse chords | `TimingCore/TapClustering` | Near-simultaneous note-ons are one rhythmic event |
| Match to the grid | `TimingCore/Grid`, `Matching` | ±40% window (`Matching.defaultWindowFraction`); outside it is an *extra*, never a late note |
| Analyse | `TimingCore/TimingReport`, `WingKristofferson`, `DropoutAnalysis`, `FormAnalysis`, `TempoCalibration`, `TempoMemory`, `MusicalContent`, `SwingAnalysis`, `OffbeatAnalysis` | One analysis per drill, all pure. Every stored type has a `report()` — **never pair `reconstruct()` with an `analyze` call of your own**, or the take's own parameters stop reaching the analysis |
| Quantify uncertainty | `TimingCore/Bootstrap`, `Statistics` | Three bootstraps, and picking the wrong one is a defect (R3.2) |
| Store | `TrainerKit/SessionStore` | One JSON per take; raw taps plus a summary nothing reads back |
| Aggregate | `TimingCore/TrendAnalysis`, `WarmUpAnalysis`, `ExperimentAnalysis`, `IntervalResponse`, `ProducedInterval` | Trends, cold-vs-warm, the A/B readout, and the interval axis. The last two are the only pair where the unit differs on purpose — takes for the first, **notes** for the second |
| Decide what to practise | `TimingCore/SessionPlan` (`SessionPlanner`), `Experiment` | Builds the evening; `ExperimentSchedule` assigns arms. The **ladder block is the only one whose tempo may vary** — cold probe, benchmark and experiment are locked (R3.5) |
| Run the evening | `TrainerKit/SessionRunner` | State machine over blocks; stamps placement and arm. Sequences, never measures |
| Drive it all | `TrainerKit/TrainerEngine` | `runJam` / `runForm` / `runDropout` / `runTempo` / `runMemory` — the **only** implementations of anything measured |
| Show it | `TrainerKit/Commands` (console), `Sources/MusicalTrainerApp` (SwiftUI) | Presentation only |

Types worth knowing before changing anything:

- **`Grid`** — index arithmetic, never accumulation. `subdivisions` is grid points per beat.
  Indices stay uniform under a feel; only their *times* move, which is what stops a feel
  reaching past `Matching`. There is deliberately **no `interval`** — under a feel there is no
  single spacing, so ask `gap(around:)` about a particular point.
- **`IntervalRung`** — a rung of M14's ladder, and the tempo ceiling its matching window implies.
  The ceiling assumes absolute spread does not move with the interval, which §7.23 step 3b
  measured rather than assumed.
- **`JamConfig.rung` / `JamSession.rung`** — the subdivision the player was **asked to produce**.
  Also on `DropoutConfig`/`TempoConfig`, where it stops the period estimate guessing the note
  value: rounding an observed 1.45 notes-per-beat to 1 reports 45% fast as a fact when the same
  playing also reads 27% slow. Every stored take is near a whole subdivision, so nothing moved.
  `nil` means no rung was prescribed, **never quarters**: the benchmark and both experiment
  blocks must stay rung-less (R3.5). A rung-less take is scored at
  `JamConfig.freePlayingSubdivisions` — sixteenths, fixed, and deliberately not the backing's
  step resolution (§7.29 step 0). Distinct from `subdivisions`, which is the grid the take
  was *analysed* on; `taskSubdivisions` is the one the interval readout wants.
- **`SwingReport`** — the ratio is **derived from mean offbeat phase and never measured per
  pair**, and consistency is the swung note's spread in *milliseconds*. Reporting a spread of
  ratios is not a stylistic choice: `dr/dφ` runs 4→16 across the useful range, so identical
  steadiness would report four times worse the harder he swings (§7.24 step 3).
- **`OffbeatLevel` / `OffbeatReport`** — the offbeat drill. **Slipping onto the beat is scored
  apart from placement**, because a slipped player is dead on a grid point — the wrong one — and
  a placement figure alone would call a lost feel an excellent take.
- **`ProducedNote`** — one matched note keyed by the gap **in grid steps** to the note before it.
  Never key this on a *measured* inter-onset interval: a note's own error is inside its measured
  gap, and binning on it fabricates a placement slope out of a player who has none. There is a
  test that plants exactly that.
- **`TimingReport`** — what a jam produced. `subdivisionStats` is **phase-conditional** (where in
  the beat a note landed), not a measure of note values played.
- **`SessionPlacement`** — where a take sat in a planned evening, and the state the player
  declared before it started. Optional; 17 of 30 jams have none, and what that costs is the
  controlled cold probe rather than the sitting, which `WarmUpAnalysis.inferSessions` recovers
  from timestamps.
- **`Feel`** — the long-to-short ratio of the divided beat, and **a ratio of 1 is straight**.
  The identity falls out of the arithmetic, so nothing needs an `if straight` and `nil` in
  storage genuinely means straight — unlike `nil` rung. Swing applies to the finest *binary*
  division only: a triplet rung never swings. Ska and reggae are **not** feels; their grid is
  straight and only the drill changes.
- **`SessionState`** — usual / tired / amped / distracted / stiff, declared **before** the first
  block and never after. After the fact it would be post-hoc exclusion. `nil` means not
  declared, which is not the same as `usual`.
- **`ExperimentAssignment`** — which experiment and arm a take belongs to. Optional.
- **`ExperimentDesign.bpmByArm`** — set only when **tempo is the condition** (`slow-vs-fast`).
  For the other two designs the instruction text *is* the independent variable, so wrong text
  swaps the arms silently; with a tempo map the tempo differs whatever the text says. Check
  `variesTempo` before assuming which kind a design is.
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
- **M15 has two swung takes and one offbeat take**, all played around 4 a.m., tagged `tired`, at
  a first attempt: they establish that the machinery works and nothing about the player. The
  swing readout's thresholds have now fired correctly on real playing once. The offbeat take
  **slipped** — 26 of 112 notes off the beat — so the drill has never yet measured a held skank,
  and the swing block's misfire on a held one (§7.24 step 8) is closed by test rather than by
  observation.
- **The offbeat drill is CLI-only.** No app mode yet — the one surface gap M15 leaves.
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
| A guard on a *count* cannot protect a *variance* | The isochrony gate admits a trial with a quarter of its intervals out of band, and the decomposition squares them. Nine intervals in 232 — 4%, well inside the gate — carried up to 99% of a trial's squared error and reported a 193.5 ms clock SD at a 600 ms beat, flagged reliable. Splitting the trial at each gap put it back to 24.1 ms. |
| Nothing louder than the groove except on the beat being marked | A crash one bar early made the form drill measure reaction to a decoy. Two takes wasted. |
| Confounds get named, not blended | A changed backing produced a "real" 8 ms spread change that was partly just different music. |
| A swung take never reaches Wing–Kristofferson | Swing alternates the intervals by design and the isochrony gate passes them. On a planted 12 ms clock and 8 ms motor, a swung series reported motor 99.7 ms and a negative clock variance. `DropoutConfig.validate` refuses it. |
| The band's swing and the grid's come from one conversion | `Feel` and `Swing` cannot share a type across the module boundary. A groove swinging at 2:1 while the grid scored 1.5:1 would look exactly like a player who drags. `JamConfig.swing` is the only conversion; `SwingAgreementTests` pins them to the sample. |
| A drill's identity survives being stored | The offbeat drill was wired into the live console path alone. `review` called the first slipped skank "steady, just early", the trend pooled its 48.4 ms spread with the free jams and turned that group's bias "worsening", and a planned block would have shown skank instructions over `jamBacking`. The take's own accessor had no callers at all. |
| The swing block and the offbeat block are mutually exclusive | A skank puts every note "off the division", so the swing readout gets *more* confident the better the feel is held: three stray notes on the beat are enough to report "you swing the beat 1.1:1" about a player dividing nothing. |
| The feel reaches the grid the *app* builds, not only the one a test builds | Both swung takes ever recorded were scored straight, because `JamAnalysis.reduce` and `SessionStore.reconstruct` kept their old calls. Reported +22 ms drag, 54 ms spread and r₁ = −0.52 — the first negative in the project's history, and an artefact. |
| A feel needs a groove, not just warped timing | The first swung backings were timed perfectly and sounded straight: every loud event stayed on an even grid and the feel was carried by a hat 8 dB down. |

## Data and analysis conventions

- Sessions live in `~/Library/Application Support/MusicalTrainer/sessions/`, one JSON per
  take, prefixed `jam-` / `form-` / `dropout-` / `tempo-` / `memory-`, plus a `session-`
  manifest per planned session (what the planner chose, why, and what was skipped).
- **Every take carries an optional `ExperimentAssignment`** — experiment id, name, arm, run
  index — written since M13 step 1 and read by nothing yet. Same reasoning as the two below: a
  take recorded without its arm is lost to the comparison for good.
- **Jam takes may carry a `rung`, a `swingRatio` and an `offbeatLevel`**, all optional. Absent
  `rung` means *no rung was prescribed* and is **not** quarters; absent `swingRatio` really does
  mean straight, because a ratio of 1 is the identity. That asymmetry is deliberate — see
  §7.23 step 4b and §7.24 step 1 before assuming either.
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

Current as of **72 takes across 10 sittings — 30 jams, 12 form, 12 continuation, 10 tempo,
8 recall**, plus 5 planned-session manifests. **Recompute rather than trusting any of this:**
`review trend`, `review dropout`, `review feel`, `review cold`, `review content`, `review
interval`.

- **r₁ is positive in all 30 jams (+0.13 … +0.50), with no negative reading ever recorded.**
  He *under-corrects* — placement floats and wanders. He does not chase the click. Do not suggest
  counting harder; that is the documented way to make this worse, and he already reports it feels
  worse. The lowest in the whole set is +0.13, an untracked `relaxed` take on 3 Aug; the lowest
  in the *locked benchmark slot* — the only one a trend may be read from — is **+0.14 on 5 Aug**,
  the most recent of the five, which is the direction §10 defines as success. One take, in one
  slot, and the slot has bounced before.
- **The benchmark jam is bouncing, not trending**: 24.1 → 17.4 → 22.0 → 21.7 → 24.9 ms across
  five takes at locked settings, ending where it started. §7.19 recorded the first step as a real
  tightening and it did not hold (§7.21). Each pairwise comparison was measured correctly; none
  of them is a trend. The free-jam trend at 100 BPM is flat on every metric over 21 takes.
- **A large placement shift held for one long sitting and then eased.** Bias went −5.9 ms on
  4 Aug to −22.6, −16.1, −20.8, −22.4 through the 5 Aug 01:00–04:30 sittings, then −15.1 and
  −13.5 that morning, and has sat between −7.6 and −24.8 since. Unexplained either way. Bias is
  not failure (§2) and spread did not move with it.
- **Clock is the looser half in every trustworthy split.** Do not pool across silence lengths:
  4-bar runs ~11–22 / 4–12 ms across five takes, 8-bar 29.6 / 9.6 and 24.1 / 15.4, 16-bar
  22.1 / 6.8. Longer is a harder task. The newest 4-bar take has the lowest motor figure
  recorded (4.2 ms). **The 8-bar figures moved in §7.25** — one of them was 40.7 / 20.9 and the
  other read 193.5 / 71.3, both inflated by a handful of hesitations feeding a variance. Anything
  quoting the old numbers is quoting the defect.
- **Nothing in the drill trends is moving, and two "worsening" verdicts were retracted to get
  there** (§7.27). `review trend` now fits one line per task instead of one line and a caveat:
  the continuation clock SD was +1.32/take [+0.64, +3.05] *worsening* across pooled 2-, 4-, 8-
  and 16-bar silences and is +2.05 [−1.03, +4.85] **flat** on the seven 4-bar takes; the form
  on-form rate was −0.04/take [−0.07, −0.01] *worsening* across levels 0–2 and is −0.01
  [−0.15, +0.10] **flat** at level 2 over 8-bar phrases. Both verdicts were the ladder, not the
  player. Only three groups now have the three points a fit needs, which is the honest cost.
- **"Runs ~5% slow unaccompanied" is dead.** The last two 16-bar continuation takes produced
  99 BPM (−1%) and 100 BPM (−0%). Controlled cold probes read −7.9%, −4.2%, −3.3%, −3.5% and
  −2.3%, and `review cold` now fits them **improving** (−0.48%/sitting [−1.27, −0.13]) — the one
  learning signal anywhere in this dataset. The −1.8% on 5 Aug was recorded *warm*, third in its
  sitting, and is not a cold point however much it looks like one.
- **Feel tracks the measurement, but less well than it did**: r = −0.42 over the rated takes,
  against −0.48 a milestone ago and −0.66 before the 5 Aug evening session. That sitting was played exhausted (§7.24) and
  is the likeliest cause; §7.17 already recorded fatigue breaking the link once, with two jams of
  identical spread rated 4 and 1. Treat the correlation as soft until a rested sitting restores it.
- **78.4% of every matched note in a free jam is a beat apart from the last one** — an eighth
  15.0%, a sixteenth 0.5% (still just 35 notes, now across 26 free takes and 7,390 notes). So
  every headline figure this project quotes, including "his ~20 ms spread", is *quarter-note
  placement in free playing*; the sixteenth-note grid those takes are scored on is doing almost
  no work. Over all 30 jams the beat share is **70.2%** and the eighth share **23.9%**, and the
  difference is entirely the three prescribed takes — two swung eighths and the skank. Quote the
  free-jam figure when caveating a free-jam number and the all-takes figure when describing the
  corpus; they are different populations and §7.23 step 3b's finding is about the first.
- **His spread is a fixed number of milliseconds, not a fixed fraction of the interval.** Flat at
  ~22–26 ms from 273 ms to 1200 ms between notes; +0.21 ms per 100 ms [−1.41, +1.18], while the
  percentage form moves for real. Recomputed on 30 jams over a 200–1200 ms range: absolute
  −0.11 ms per 100 ms [−1.85, +0.63], within noise, against −1.07 points [−2.54, −0.69] for the
  percentage, which is real. The finding has now survived three recomputes. Milliseconds are what
  compare across tempos and rungs for this player — **do not normalise spread by the interval**,
  and do not assume "faster is tighter" is arithmetic. That premise was stated as fact in §7.23 for three steps before it was checked.
- **Tempo is not analysed anywhere.** It is only ever *controlled for* — trends split mixed-tempo
  groups and `review tags` warns about them. His stated hypothesis is that faster is easier to a
  point and that slow tempos make him rush, and no readout can currently ask it. The data cannot
  either: 25 jams at 100 BPM, 4 at 110 (all one evening, six minutes apart), 1 at 120. And 61%
  of every matched note sits at one interval, 600 ms, which `review interval` now says out loud. M14 is
  where this gets built — see §7.23, including why raw spread cannot be compared across tempos.
- **The recall drill's interference cost is not established.** §7.19 read it as the distractor
  *helping*; since the attrition rule landed (§7.20 finding 2), three of the four takes are
  withheld as non-comparable and one remains. Treat it as unmeasured, not as a direction.
- **M12's first data contradicts his hunch**: busier playing went with *looser* timing within a
  take, and the censoring bias runs against that result rather than producing it. His hunch is
  about the mode of playing across a take, which M12 cannot test and M13's `steady-vs-melodic`
  experiment is now collecting for.
- **Three tags pool across a confound** — `focused` and `relaxed` across tempos, and `tired`
  across two swing ratios. All three are flagged at the point of display with what the mix
  ruins (§7.28); `tired` was silent until that list was consolidated.
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
  unit tests. The verification pipeline *has* run — #42 green on `main` — but the release
  pipeline never has, and neither covers `TrainerKit`. Naming the gap is part of the work;
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
5. **`./scripts/check.sh`** last, and `.githooks/commit-msg temp/current-git-commit-message.txt`
   — it takes a path and exits non-zero, so checking the message costs nothing and counting
   characters by eye does not work. The pre-commit hook runs only the fast half of the gate.
6. **Write `temp/pr-message.md`** — the PR body, in the shape STANDARDS.md §8.2.3 sets out.
   Part of the change like the commit message is, not an afterthought at merge time.
7. **Hand over.** Andrew commits, pushes and opens the PR with one line:

   ```sh
   git add -A && git commit -F temp/current-git-commit-message.txt && ./scripts/open-pr.sh
   ```

   Give him that line, with `--base <parent-branch>` when the work is stacked so the PR shows
   this change alone. Do not run it — pushing and opening a PR are his, and this machine has no
   credentials for the remote in any case.

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
