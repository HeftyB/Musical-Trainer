# Musical Trainer — Design & Build Plan

A macOS app for training an autonomous internal pulse.

**Target machine:** macOS 13.7.8, Xcode 14.2 (Swift 5.7), Intel x86_64
**Primary input:** Novation Launchkey Mini MK2 (USB MIDI, class-compliant)
**Later inputs:** electric guitar (audio onset detection), Roland TD-6V (MIDI DIN → USB interface)
**DAW context:** GarageBand (macOS + iOS)

---

## 1. What we are actually training

The stated problem: *"If my brain is out of the picture the flow is easy. The moment I count, my timing gets terrible."*

That is not a contradiction and it is not a discipline failure. It is a description of two different control systems fighting:

| System | Character | Latency | Good at |
|---|---|---|---|
| Symbolic counting | serial, conscious, verbal | ~200–400 ms | analysis, structure, learning a chart |
| Internal oscillator | continuous, predictive, motor | ~0 ms (predictive) | *keeping time* |

Counting cannot drive a task that requires prediction, because by the time you have consciously registered a beat, the beat is gone. Focusing harder recruits *more* of the wrong system, which is exactly why effort makes it worse. This is a well-documented effect, not a personal quirk.

**So the goal is not "count better." The goal is to build an oscillator that runs unsupervised, and then get the hands to lock to it.**

This has three hard consequences for the app:

1. **No numbers on screen during a take.** A live timing meter is counting with extra steps — it recruits the same analytical loop. Silent during, rich after.
2. **The core exercise is dropout, not correction.** Click for N bars, silence for N bars, click returns. You don't count; you find out whether you're still there. Everything else is a variation.
3. **We must measure the thing he can't feel.** He has 25 years of theory and still can't self-diagnose. The app's whole value is telling him something he does not already know.

---

## 2. Design principles (non-negotiable)

- **The audio render thread is the only clock.** Never `Timer`, never `DispatchSourceTimer`, never `CADisplayLink` for beat timing.
- **One sample counter is the single source of truth.** Click, groove playback, and the analysis grid all derive from it. No independent timelines to drift apart.
- **Calibrate before you measure, always.** Uncalibrated timing data is worse than no data — it produces confident wrong conclusions.
- **`TimingCore` is pure Swift with zero UI and zero AVFoundation.** It must be unit-testable with synthetic tap data of known bias and variance.
- **Silent during the take.** Enforced by architecture, not willpower — the take view has no data binding to live metrics.
- **Never present bias as failure.** Playing ~20–40 ms ahead of the click is normal for trained musicians (negative mean asynchrony). Variance is the skill. Conflating the two would teach the wrong lesson.
- **Measurement first, interface second.** *"We need accurate data and skill tests, that is number one priority. UI and user experience comes secondary; any indicator that may interfere needs to be hidden."* The player's rule, and it decides the cases a screen would otherwise win: the take view stays blank, the form and continuation drills get no progress indicator, and anything that would let a player locate themselves in time during a drill that measures whether they can do that unaided is not built. A pleasant surface that costs a measurement is a bad trade in a tool whose only job is to tell you something true.

---

## 3. Architecture — the timing spine

### 3.1 Sample clock authority

The audio render callback owns a monotonically increasing sample counter. Beat positions are computed **in samples, from beat index** — never by accumulating floats:

```
beatSample(n) = round(n * sampleRate * 60 / bpm)
```

Accumulation (`t += interval`) drifts. Index math does not. Non-negotiable.

### 3.2 The critical problem: two clocks

| Domain | Unit | Source |
|---|---|---|
| MIDI input | `mach_absolute_time` (host ticks) | CoreMIDI, captured at driver level |
| Audio output | sample index | our render callback |

These must be reconciled or every number the app produces is garbage. **This is the highest-risk piece of the project and gets built and validated first.**

**The bridge:** the render callback receives an `AudioTimeStamp` whose `mHostTime` is the host time at which that buffer reaches the DAC (check `kAudioTimeStampHostTimeValid`). Publish the pair `(mHostTime, sampleIndex)` atomically each callback. Then for any MIDI event at host time `H`:

```
sample = lastSample + (H - lastHostTime) * sampleRate / hostTicksPerSecond
```

Use `mach_timebase_info()` for ticks → nanoseconds. Consider a slow-moving linear regression over the last ~50 pairs rather than the single latest pair, to reject callback jitter.

### 3.3 APIs

- **MIDI in:** `MIDIInputPortCreateWithProtocol` (macOS 11+) with `MIDIProtocol._1_0`. Per-packet `timeStamp` in host ticks, driver-level, sub-millisecond. The Launchkey is class-compliant — no driver needed.
- **Audio out:** `AVAudioEngine` + `AVAudioSourceNode` (macOS 10.15+) for full render control, or `AVAudioPlayerNode.scheduleBuffer(at:)` for sample-accurate buffer scheduling. Prefer `AVAudioSourceNode` — we need the timestamp anyway.
- **Buffer size:** set `kAudioDevicePropertyBufferFrameSize` to 128 or 256 frames. Lower = less latency, more CPU. 256 @ 44.1k = 5.8 ms.
- **Charts:** Swift Charts is available on macOS 13 — the review UI is well-supported despite the older toolchain.

### 3.4 Real-time thread discipline

Inside the render callback: **no allocation, no locks, no Swift runtime calls that can allocate, no logging.** Communicate with the UI via a lock-free ring buffer. Violating this produces audible glitches and, worse, timing artifacts that look like *your* timing errors.

---

## 4. Calibration

Two separate quantities that must never be conflated:

**Machine latency (objective — measure and subtract).**
Loopback: play a click through the speakers, record it with the Built-in Microphone, cross-correlate to find the round-trip delay. This captures output latency + buffer + safety offset + air travel. Query `kAudioDevicePropertyLatency`, `kAudioDevicePropertySafetyOffset`, and `kAudioStreamPropertyLatency` as a sanity check, but **trust the empirical measurement** — the reported values are frequently incomplete.

**Personal bias (subjective — measure and *keep*).**
After machine latency is removed, tap 32 beats. The residual median offset is your negative mean asynchrony. This is data about you, not error to be zeroed out.

> The common mistake is a single "tap to calibrate" step that silently absorbs both. That makes the app feel accurate while destroying the one number most worth knowing.

**Bluetooth is disqualifying.** AirPods add 150–200 ms and it *varies* run to run, which no calibration can fix. The app should detect a Bluetooth output device and refuse to record a scored take. Wired headphones or wired interface only.

Recalibrate on any output device change. Store per-device.

### 4.1 Signal design

- **Use a swept chirp, not an impulse** — e.g. 500 Hz → 8 kHz over 20 ms. Cross-correlation against a chirp gives a far sharper, more noise-robust peak than a click, and is insensitive to speaker frequency response.
- **Parabolic interpolation** across the three samples bracketing the correlation peak yields sub-sample resolution (~0.02 ms at 44.1 k). Free precision.
- **Median of N=100**, report the interquartile range. Median is robust to occasional failed onset detections.

### 4.2 Ground-truth rig — validating the clock bridge without human judgement

A key strike emits **two** signals: an electrical MIDI note-on, and an acoustic "thock" at bottom-out. On a velocity-sensitive keyboard note-on fires at the second contact closure, which *is* bottom-out — so they are near-simultaneous. That gives two independent paths to the same physical event:

- **Path A (audio domain only):** the mic records both the click and the thock into one stream. Measure the gap. No MIDI, no host time, no bridge.
- **Path B (through the bridge):** MIDI host timestamp → sample index, compared to the click's sample position.

Let `t_press` and `t_click_out` be the true physical times, `L_out` output latency, `L_in` input latency, `L_midi` press→timestamp latency, and `L_air_*` the acoustic travel times.

```
Δ_audio = (t_press − t_click_out) + (L_air_thock − L_air_click)      ← L_in cancels
Δ_midi  = (t_press − t_click_out) + L_midi + L_out

Δ_midi − Δ_audio = L_midi + L_out − (L_air_thock − L_air_click)
```

**Input latency cancels entirely** — both events traverse the same input path. Place the mic roughly equidistant from speaker and keyboard and the air terms cancel too, leaving `L_midi + L_out`. Since `L_out` is measured independently by loopback, `L_midi` falls out.

**The reframe that makes this tractable:** the thock and the note-on are not *exactly* simultaneous, so perfect absolute truth is unobtainable this way. That does not matter. Any constant offset is absorbed by calibration. What we are validating is **stability, not absolute accuracy.**

**M0 pass criteria — all automated, no visual inspection:**

| # | Check | Proves |
|---|---|---|
| 1 | Residual SD < 1 ms over 100 taps | Bridge is sound |
| 2 | Residual vs. **audio buffer phase**: slope ≈ 0 | Bridge math is correct. Vary tempo so beats land at different offsets within the buffer — if the conversion is wrong, error correlates with buffer phase, and *nothing else exposes this bug*. |
| 3 | Residual vs. elapsed time: slope ≈ 0 | Input and output devices are genuinely clock-locked |
| 4 | Absolute offset | Becomes the calibration constant |

### 4.3 Device clock domains

Separate audio devices have independent crystals and drift relative to each other (~50 ppm ⇒ several ms over a couple of minutes) — enough to corrupt a long run.

**Use the built-in microphone for calibration and the rig**, not a USB mic: it shares a codec with Built-in Output, so it is clock-locked and drifts zero. Onset detection is indifferent to mic quality. Reserve the USB mic for guitar work later, where an aggregate device (`AudioHardwareCreateAggregateDevice`, confirmed present in the 13.1 SDK) or explicit drift compensation will be required.

Check #3 above validates the clock-lock assumption empirically rather than trusting it.

---

## 5. The metrics

Given a series of asynchronies `e[i]` (signed ms, note onset minus grid point):

| Metric | Meaning | Why it matters here |
|---|---|---|
| **Mean asynchrony** | rushing (−) vs dragging (+) | Baseline character. Normal to be negative. |
| **SD of asynchrony** | precision | The actual skill. ~8–15 ms is solid, ~5–8 ms is elite. |
| **Drift rate during dropout** | ms/bar or effective BPM error | Direct quality measure of the internal oscillator. |
| **Lag-1 autocorrelation** | correction gain | **The key diagnostic — see below.** |
| **Wing–Kristofferson split** | clock vs motor variance | **The centerpiece — see below.** |
| Subdivision-conditional SD | error by note density | Fine on quarters, falling apart on 16ths? |
| Velocity/timing coupling | does harder = rushed? | Very common, rarely noticed. |

### 5.1 Lag-1 autocorrelation — the diagnostic that matches the complaint

Correlate each asynchrony with the one before it:

- `r₁ ≈ 0` → autonomous timekeeper. **This is flow.**
- `r₁` strongly negative → you are *reacting* to each click and over-correcting. Chasing.
- `r₁` positive → drifting, no correction at all.

The prediction is that when you "try to focus and dial it in," `r₁` goes sharply negative. If the app can show you that — *this is what focusing does to you, here it is in a number* — that alone is worth building. It converts a 25-year vague frustration into a measurable, trainable variable.

### 5.2 Wing–Kristofferson — is it your clock or your hands?

For an unpaced continuation task (tap with the click, click stops, keep going — i.e. **exactly the dropout drill**), total timing variance decomposes into a central timekeeper and motor execution noise:

```
σ²_motor = −γ₁
σ²_clock = γ₀ + 2γ₁
```

where `γ₀` is the variance of inter-onset intervals and `γ₁` their lag-1 autocovariance.

This answers the actual question: **is the pulse in your head unstable, or is the pulse fine and your hands are noisy?** Those need completely different training and are indistinguishable by feel. This is the single most valuable output of the app and it falls directly out of the drill we were going to build anyway.

### 5.3 Onset matching — a real trap

Do not naively snap each note to the nearest grid point. A note 60% of a beat late snaps forward and reports as *early*, inverting the sign. Use a matching window (e.g. ±40% of the subdivision), and count anything outside it as an extra or missed note rather than folding it into the asynchrony statistics.

---

## 6. Jam mode (v1 surface)

**Groove source: synthesized in-app**, not audio loops. A pattern engine driving drum samples, riding the same sample clock. Full tempo agility, sample-accurate, no licensing, and — critically — the app can *modify the groove mid-take*, which loop playback can't.

**Sustaining a long session.** "Groove for hours" fails if the backing is hypnotically static. Needs: fills, section changes (A/B), dynamic swells, instrumentation drops, and occasional deliberate tempo modulation.

**The training hidden inside the jam.** The dropout ladder, expressed musically rather than as an exercise:

1. Full kit
2. Drums drop to hi-hat only
3. Hi-hat drops to beats 2 and 4
4. Only beat 4
5. Only the downbeat of every other bar
6. Total silence for 4 bars, then the full kit slams back in

Step 6 is the moment of truth and it feels like a *musical* event, not a test. Difficulty adapts based on measured drift. You never see a score mid-take — you just hear whether the band is still with you.

**Take screen:** near-blank. Elapsed time, a stop control, nothing readable. Eyes closed is a supported use case.

**Review screen:** everything. Swift Charts, asynchrony scatter over time, drift curve through dropout sections, the clock/motor split, and one plain-English headline finding.

---

## 7. Milestones

Ordered by risk, not by visibility. M0 is a throwaway console app that de-risks the entire project — do not skip it.

| # | Milestone | Proves / delivers |
|---|---|---|
| **M0** | ✅ **Timing spike + ground-truth rig (console)** | Click, Launchkey capture, host-time ↔ sample-index bridge, and the §4.2 two-path validation with its four automated pass criteria. **The whole project rests on this.** Also yields the Launchkey's key-scan latency as a by-product. |
| **M1** | ✅ Calibration | Chirp loopback cross-correlation via built-in mic; Bluetooth detection + refusal; per-device storage with reference-derived constants for devices that skip the full run. See §7.2. |
| **M2** | `TimingCore` + tests | ✅ Done. Pure analysis module, 25 XCTest cases against synthetic ground truth. See §7.3. |
| **M3** | Groove engine | ✅ Done. `GrooveCore` (patterns, sequencer, dropout ladder) + synthesized kit + `GroovePlayer`. See §7.4. |
| **M4** | Jam capture loop | ✅ Done (console). `jam` records a take against the groove, applies calibration, runs the report, saves the session. SwiftUI shell deferred — see §7.5. **First version you actually practice with.** |
| **M5** | SwiftUI app + review | ✅ Done. Eyes-off take screen, rate-before-results, Swift Charts review, history. See §7.6. |
| **M6** | Dropout / continuation drill | ✅ Done. The only drill that yields a clock/motor split. See §7.7. |
| **M7** | Progress over time | ✅ Done. `review trend` fits each metric with a bootstrap interval and splits confounded groups. See §7.8. |
| **M8** | Tempo calibration drill | ✅ Done. Closed feedback loop on the tempo bias §7.8 found. See §7.10. |
| **M9** | Session builder | ✅ Done. The app proposes a 20/30/45 min session from recent data and runs it end to end. See §7.14. |
| **M10** | Cold vs warm | ✅ Done. Within-sitting warm-up separated from between-sitting learning. See §7.15. |
| **M11** | Clock stability drills | ✅ Done. The recall drill: is the period stored, or only held by keeping it running? See §7.16. |
| **M12** | What you play | ✅ Done. Content measured per window against timing, within-take. See §7.18. |
| **M13** | Experiment runner | ✅ Done. Preregistered A/B experiments: arms assigned and counterbalanced before play, no verdict before the declared n. See §7.22. |
| **M14** | Subdivision ladder + tempo | ✅ Done. Rungs, tempo ceilings derived from the matching window, a tempo-rotating training block, and `slow-vs-fast`. Six ladder takes on record across 80–140 BPM. See §7.23. |
| **M15** | The feels | ✅ Done. Swing measured as placement, and the ska/reggae offbeat drill. Three offbeat takes and two swung ones. **Jazz comping moved to M23** and latin was never scoped — the original line promised both. See §7.24, §7.38. |
| **M16** | Form ladder v2 | ✅ Done, steps 0–4. The form drill's two axes split into peers, then a ladder each: the levels promoted on landing cleanly, the phrase span on knowing the bar, and a named chooser between them. See §7.26 and §7.40–§7.45. |
| **M16.5** | The skank family | Step 0 built — both candidate figures, both rendered, the organ to hear them on, and **both ship** rather than one being chosen: the player heard each as plausible depending on the piece, so they are a player-selected axis with their own trend groups. **Still blocked on M26**, not on code — he heard neither as a bubble and named the tone handicap as the cause. What it owes is a blind re-listen on an organ voice. See §7.55, §7.56, §7.59. |
| **M17** | Unified adaptive difficulty | One progression model across all drills, replacing four ad-hoc rules. **A correctness milestone, not a tidying one** — §7.52 is what four rules reading one corpus through four filters costs. **Step 0 is built** — one list of what makes a task, in `TimingCore`. See §7.59, §7.60. |
| **M18** | Longitudinal model | Within-session vs between-session effects, separated properly. **Gated on sittings rather than scheduled**; §7.59 states how many. |
| **M19** | Musical depth | ✅ Done and proven live. A style format, a bass, four styles, a seeded arranger, and the planner picking a band for the closing jam. **All four auditions are currently withdrawn** — M26 changed the kit under them — so `StyleLibrary.auditioned` is empty and the planner can schedule no band today. That is the flag working, not a regression. See §7.29, §7.33, §7.34. |
| **M20** | Drum mode | Pads and keys become the kit; the click becomes the band. |
| **M21** | Guitar input | Audio onset detection. Needs an interface. |
| **M22** | Computer-keyboard input | For anyone who doesn't own a MIDI controller. |
| **M23** | Jazz time | Deferred behind the instrument milestones, on a data problem rather than a code one. |
| **M24** | Voice | Inherits M21's onset detection rather than M23's harmony. A sung or chanted skank is the same measurement as a played one. |
| **M25** | Harmony | What the band plays under the player, rather than what the player is scored on. |
| **M26** | The kit | **The synthesis work that makes a genre name true, and the milestone most other things are waiting on.** Blocks M16.5 today; blocked M19's style names before that. **Steps 0–1 and items 1, 2, 3, 4 and 6 are built**; item 5 and the listening verdict are not. Every take records which kit it heard and the kit is a grouping axis (§7.61, §7.62); every drum voice has velocity layers (§7.63, §7.64), a room (§7.65) and round-robin level variation (§7.66); `KitSpec` makes a kit a parameter set (§7.67) and the four styles carry their own (§7.68, §7.69); the cymbals are struck plates (§7.70–§7.73). **Five listening passes, still unheard in its current form** — every audition stays withdrawn until it is. See §7.30, §7.59. |
| **M27** | What makes a genre that genre | The classification problem underneath the name. |
| **T1** | ✅ **Test infrastructure — the take factory** | A different axis from the M-sequence: what the project can verify about itself. Synthetic takes, a degenerate corpus, a macOS-only `TrainerKitTests` target, and a seam under the drill runners. Ordered **before M13's storage step**. See §7.22. |
| — | *Later* | TD-6V; GarageBand via IAC Driver; MIDI/audio export of takes. |

**The number is an identifier, not an order.** Six milestones were added after the original
M9–M22 list and sit at the end of it because that is where the next free number was, not because
that is when they happen — §7.13 has always ordered them by dependency in prose, and this table
did not carry them at all until §7.59. What is actually next, and why, is in §7.59; the short
version is that **M26 sits in front of M16.5, M20 and M23** rather than behind them.

**The entry for each milestone is in [the build journal](docs/JOURNAL.md)** — what was built, what
a session measured, what a review found, and what each one changed, as §7.1 to §7.73. This document
keeps the design and the status; the journal keeps the argument and the dates. A citation names the
section and never the file, so `§7.52` resolves wherever it is read from.

---

## 8. Project layout

Swift Package Manager, five source targets and four test targets. The split is not cosmetic: the
two pure modules are what make the numbers testable, and the rule that keeps them honest is that
**anything analysable goes in `TimingCore` or `GrooveCore`**, because only those run under
`swift test` against data whose answer is known by construction.

```
Musical Trainer/
├── Sources/
│   ├── TimingCore/          pure analysis. Grid, matching, W-K split, autocorrelation,
│   │                        bootstrap, form, tempo calibration, tempo memory, trends,
│   │                        warm-up decomposition, feel and swing, the offbeat drill,
│   │                        the interval ladder, experiments, the session planner.
│   │                        No AVFoundation, no CoreMIDI, no CoreAudio, no UI.
│   ├── GrooveCore/          pure groove generation. Patterns, sequencer, arrangements,
│   │                        dropout ladder, form and offbeat backings, the aperiodic
│   │                        distractor, styles and the seeded arranger.
│   │                        Same purity rule; depends on nothing, not even TimingCore.
│   ├── TrainerKit/          audio, MIDI, synthesis, calibration, storage, the drill
│   │                        runners (`TrainerEngine`), `SessionRunner`, console layer.
│   ├── TimingSpike/         console front end (main.swift only).
│   └── MusicalTrainerApp/   SwiftUI front end.
└── Tests/                   926 cases
    ├── TestSupport/         shared generators — not a test target
    ├── TimingCoreTests/     442 cases against synthetic ground truth
    ├── GrooveCoreTests/     151 cases — patterns, sequencer, styles
    └── TrainerKitTests/     333 cases — storage, config, sessions. macOS only, so
                             `check.sh` runs them and Woodpecker cannot.
```

`TrainerKit` exists because two front ends need one engine: `TrainerEngine.runJam` / `runForm`
/ `runDropout` / `runTempo` / `runMemory` are the only implementations of anything measured, so
the CLI and the app cannot drift apart. `build-app.sh` wraps the SPM binary in a minimal `.app`
— without a bundle macOS treats the executable as a background process, with no dock icon, no
menu bar and no Info.plist to request microphone access from.

The one duplication that is deliberate: `GrooveCore` carries its own small seeded RNG rather
than depending on `TimingCore` for one. Keeping both pure modules independent is worth more
than a dozen shared lines.

---

## 9. Status of open questions

**Resolved:**

1. **Toolchain — settled on Xcode 14.2 / Swift 5.7.** Xcode 15 would not install; it is not needed. Verified present in the MacOSX13.1 SDK: `MIDIInputPortCreateWithProtocol`, `MIDIEventPacket.timeStamp`, `AVAudioSourceNode`, `AVAudioSinkNode`, `Charts.framework` (Swift Charts), `AudioHardwareCreateAggregateDevice`, and the latency constants (`kAudioDevicePropertyLatency`, `kAudioDevicePropertySafetyOffset`, `kAudioDevicePropertyBufferFrameSize`) — note these live in `AudioHardwareBase.h`, not `AudioHardware.h`. **Nothing in this plan is blocked by the toolchain.**
2. **Ground truth — solved without human judgement.** See §4.2. Eyeballing waveforms in GarageBand was explicitly rejected to avoid visual bias; the two-path rig is fully automated and strictly better.
3. **Output hardware — wired headphones available**, plus an external USB mic. §4.3 argues for the *built-in* mic for calibration specifically, on clock-domain grounds.

**Still open:**

4. ~~**Drum samples.**~~ **Resolved** — kit is synthesized in-app; no samples needed. See §7.4.
5. **TD-6V needs a USB-MIDI interface** (DIN out only). Cheap, but a purchase.
6. **Guitar needs an audio interface** for anything beyond a noisy built-in-mic experiment.
7. ~~**Launchkey Mini MK2 key-scan latency is unknown.**~~ **Resolved** — jitter ≤ 0.63 ms, comfortably good enough. See §7.1.
8. **Multi-instrument does not have to wait on hardware.** M20's drum mode uses the pads and keys already on the Launchkey, so it exercises the input-mapping and backing seams that M21 and M22 need — without a purchase. Worth doing before either.
9. **Computer-keyboard timing quality is unknown** (M22). HID event timestamps are not driver-level MIDI timestamps, and key repeat and rollover both interfere. It would need its own M0-style validation before a single number from it could be trusted; assume nothing until that run exists.
10. **Whether two seeds of one style pool honestly in a trend is unmeasured** (M19 step 7, §7.29). The argument that they should is structural — the generator selects among bars the style already defines and never invents or moves a hit, and `density` and `carriesBass` belong to the style rather than the seed — but the between-seed variance has never been observed. Takes over a generated backing now exist — the 8 August session closed on two of them (§7.34) — and **both shared one seed**, which is exactly the case that cannot estimate it. It needs a second seed within one style, not more takes. Until it has, the generated side of the trend groups by style and **says the pool mixes seeds and that the cost is unquantified**. Once a style has takes on two or more seeds it is directly estimable, and it is the same two-stage question `Bootstrap` answers for takes within a condition (R3.2, row 3): comparable to the between-take spread and seeds pool honestly, larger and the seed goes into `GroupKey`.

---

## 10. What success looks like

Not "SD under 10 ms," though that will happen. Success is:

- `r₁` near zero **while playing something musically demanding** — the oscillator holds under load.
- Drift under a few ms/bar through 8 bars of silence.
- Clock variance low enough that remaining error is motor noise — at which point the training target changes entirely.
- **On the mark.** Added on the player's own statement of what he is training for — *"I just want my
  timing to be tight, in the pocket, and on the mark"* — because bias was not among these criteria
  and he says it should be. It sits **beside** §2 rather than against it: bias is never presented as
  failure, ~20–40 ms ahead is normal, and what this criterion asks is that any deviation be
  *chosen* rather than arrived at. ~~The measurement cannot tell those apart; the player can.~~
  **The player cannot either, and said so** (§7.59): the ~35 ms is not a chosen feel and the looseness
  is not deliberate. So this criterion has no instrument today — neither the app nor the player can
  currently say which side of the beat a take sat on before the numbers appear, and a bias nobody
  can feel is one nothing corrects. §7.59 carries the candidate: ask for the direction before the
  numbers, the way `review feel` asks for the quality.
- And the one that actually matters: an hour goes by and it felt like flow, not work.
