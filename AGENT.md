# Musical Trainer — agent guide

macOS app that trains an autonomous internal pulse. One user: Andrew, 25+ years playing,
theory-strong, timing is the weak axis.

Four documents, four jobs — putting content in the wrong one is a defect:

- **[PLAN.md](PLAN.md)** — design, rationale, findings, roadmap. **The reasoning lives here.**
- **[STANDARDS.md](STANDARDS.md)** — binding engineering rules and the procedures that enforce
  them. Read it before writing code.
- **AGENT.md** (this file) — the operating manual.
- **[README.md](README.md)** — what the app is and how to use it.

## Build, test, run

```sh
./scripts/check.sh                      # the gate — must pass before every commit
./scripts/install-hooks.sh              # once per clone, installs the tracked git hooks

swift test                              # 170 unit tests, no hardware needed
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
  (`Bootstrap`), and comparisons say "real change" or "within noise". The bootstrap is
  **moving-block** because asynchronies are serially correlated — that correlation is the r₁
  the app reports.
- When a measurement can't be trusted, say so and say why. `splitIsReliable`,
  `discardedTrials`, `unusableReason`, and the comparability notes all exist because a
  confident wrong number is worse than an honest gap.

## What the data says about this player

Current as of 39 takes across 4 sittings — 15 jams, 9 form, 8 continuation, 5 tempo, 2 recall.
Recompute rather than trusting these; every figure comes from `review trend`, `review dropout`,
`review feel` and `review cold`.

- **r₁ is positive in all 15 jams (+0.13 … +0.47).** He *under-corrects* — placement floats and
  wanders. He does not chase the click. Do not suggest counting harder; that is the documented
  way to make this worse, and he already reports it feels worse.
- **Clock is the looser half in 6 of 6 trustworthy splits.** At 4-bar silences it runs 14.9 ms
  clock vs 9.3 ms motor; the one 8-bar take is 40.7 vs 20.9, which is a harder task rather than
  a worse player — do not pool them.
- **Unaccompanied tempo runs slow, ~5%**, and it closes within a sitting (−4.7% → −0.3% over
  four tempo takes in 27 minutes). The first *controlled* cold probe read **−7.9%** against the
  −0.3% that ended the previous evening, which is the M10 question in one number: n=1 so far.
- **Feel tracks the measurement** (r ≈ −0.61 over 11 rated takes) — but the first full session
  broke it: two jams with identical spread (24.1 vs 24.3 ms) were rated 4 and 1 twenty minutes
  apart. His instinct is calibrated for precision and apparently not for fatigue.
- **Off-grid rate and velocity spread both climbed** across that session (2.7% → 10.8%). His own
  reading is that steady quarters send him to sleep and melody puts him in the pocket — that is
  M12's hypothesis, and the pitch data to test it only started being recorded on 4 August.
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
