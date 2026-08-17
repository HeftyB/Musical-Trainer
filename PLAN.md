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
| **M16.5** | The skank family | Step 0 built — both candidate figures, both rendered, the organ to hear them on. **The choice between them is blocked on M26**, not on code: the player heard neither as a bubble and named the tone handicap as the cause. See §7.55, §7.56, §7.59. |
| **M17** | Unified adaptive difficulty | One progression model across all drills, replacing four ad-hoc rules. **A correctness milestone, not a tidying one** — §7.52 is what four rules reading one corpus through four filters costs. **Step 0 is built** — one list of what makes a task, in `TimingCore`. See §7.59, §7.60. |
| **M18** | Longitudinal model | Within-session vs between-session effects, separated properly. **Gated on sittings rather than scheduled**; §7.59 states how many. |
| **M19** | Musical depth | ✅ Done and proven live. A style format, a bass, four approved styles, a seeded arranger, and the planner picking a band for the closing jam. See §7.29, §7.33, §7.34. |
| **M20** | Drum mode | Pads and keys become the kit; the click becomes the band. |
| **M21** | Guitar input | Audio onset detection. Needs an interface. |
| **M22** | Computer-keyboard input | For anyone who doesn't own a MIDI controller. |
| **M23** | Jazz time | Deferred behind the instrument milestones, on a data problem rather than a code one. |
| **M24** | Voice | Inherits M21's onset detection rather than M23's harmony. A sung or chanted skank is the same measurement as a played one. |
| **M25** | Harmony | What the band plays under the player, rather than what the player is scored on. |
| **M26** | The kit | **The synthesis work that makes a genre name true, and the milestone most other things are waiting on.** Blocks M16.5 today; blocked M19's style names before that. **Steps 0–1 are built** — every take records which kit it heard, and the kit is a grouping axis. See §7.30, §7.59, §7.61, §7.62. |
| **M27** | What makes a genre that genre | The classification problem underneath the name. |
| **T1** | ✅ **Test infrastructure — the take factory** | A different axis from the M-sequence: what the project can verify about itself. Synthetic takes, a degenerate corpus, a macOS-only `TrainerKitTests` target, and a seam under the drill runners. Ordered **before M13's storage step**. See §7.22. |
| — | *Later* | TD-6V; GarageBand via IAC Driver; MIDI/audio export of takes. |

**The number is an identifier, not an order.** Six milestones were added after the original
M9–M22 list and sit at the end of it because that is where the next free number was, not because
that is when they happen — §7.13 has always ordered them by dependency in prose, and this table
did not carry them at all until §7.59. What is actually next, and why, is in §7.59; the short
version is that **M26 sits in front of M16.5, M20 and M23** rather than behind them.

---

## 7.1 M0 — measured results

Run on the target machine, Built-in Output → air → Built-in Microphone, Launchkey Mini MK2.

| Quantity | Result |
|---|---|
| Round-trip latency (speaker → mic) | **15.88 ms**, IQR 0.01 ms, SD 0.01 ms |
| Measured input clock | 44100.01 Hz vs 44100 nominal (**0.2 ppm**) |
| Clock drift, input vs output | 0.015 ms/min |
| Residual (MIDI path − audio path) | **10.18 ms**, SD 0.63 ms, IQR 0.61 ms |
| Beats paired | 100 / 100, 0 trimmed, 0 unmatched |

**Check #1** SD 0.63 ms · **#2** 0.098 ms across a buffer (r = 0.045) · **#3** 0.165 ms/min
(r = 0.126) · **#4** constant 10.18 ms. All pass.

Findings worth carrying forward:

1. **The bridge arithmetic is correct.** Check #2 is the proof: no relationship between
   error and where a chirp fell inside the audio buffer. This was the one bug nothing else
   would have caught.
2. **Built-in mic and output are clock-locked**, as §4.3 assumed — now measured, not
   trusted. 0.2 ppm.
3. **Reported device latency under-reports by ~5 ms.** CoreAudio claimed 461 frames
   (~10.5 ms) round trip against 15.88 ms measured. Vindicates §4 — measure empirically,
   treat `kAudioDevicePropertyLatency` as advisory only.
4. **The acoustic environment is far dirtier than expected**: 1506 onsets for 100 strikes,
   ~15 per beat. Every one of the 100 beats still paired. The MIDI-gated, loudest-in-window
   selection is not an optimisation — without it this run fails outright.
5. **The 10.18 ms constant is exactly the quantity real calibration needs.** Asynchrony
   works out to `(midiHost − emitHost) − (L_midi + L_out)`, and the two-path residual *is*
   `L_midi + L_out`. No need to separate MIDI transport latency from output latency.

### Resolves open question #7

Launchkey Mini MK2 jitter is **≤ 0.63 ms** — and that figure is the whole rig's combined
uncertainty (keyboard + acoustic onset detection), so the keyboard alone is better still.
Against training thresholds around 10 ms this is comfortable. The keyboard is a sound
primary input and the TD-6V does not need to move up the roadmap.

### Carried into M1

The 10.18 ms constant is specific to internal speakers. Practice happens on headphones,
which have a different `L_out`. The delta is obtainable without new machinery: run the
chirp loopback with an earcup against the built-in mic and take
`R_headphones ≈ R_speakers + (RT_headphones − RT_speakers) + L_air_speakers`, where the
air term is the built-in speaker-to-mic distance (~15 cm, ~0.44 ms).

Worth remembering that absolute accuracy matters less than it appears: a constant offset
shifts measured *bias* but leaves *variance* untouched, and variance is the skill metric.

---

## 7.2 M1 — calibration, as built

The stored quantity is `L_midi + L_out`, because asynchrony reduces to
`(midiHostTime − clickEmitHostTime) − (L_midi + L_out)` and the two-path residual *is* that
sum. MIDI transport latency never has to be separated from output latency.

**Reference-and-derive.** A full calibration costs ~2 minutes of playing, too much to repeat
per pair of headphones. `L_midi` belongs to the keyboard, not the output device, so one full
run anchors a reference and any other device needs only a 15-second loopback:

```
C(dev) = C(ref) + (RT(dev) − RT(ref)) + air(ref) − air(dev)
```

Air path is stored per device rather than assumed, because it does not cancel: internal
speakers sit ~15 cm from the built-in mic, while a headphone earcup resting against it is
~1 cm. A directly measured constant always wins over a derived one — it carries no air-path
assumption at all.

**Device identity must include the data source.** On this MacBook, internal speakers and
wired headphones are the *same* CoreAudio device — both report the name "Built-in Output" —
yet their latencies differ by ~7 ms. The distinguishing property is
`kAudioDevicePropertyDataSource` ("Internal Speakers" vs "Headphones"), so calibration keys
on `name · dataSource`. Without this, a quick calibration on headphones overwrites the
speaker reference. The first live M1 run hit exactly that: the quick pass clobbered the
full pass's residual and left every constant unavailable. Fixed by (a) data-source identity
and (b) a `record` merge that carries an existing measured residual forward, so a
loopback-only pass can never destroy one. Both are covered in `selftest`.

**Refusals.** Bluetooth output is rejected outright rather than warned about; its latency
varies run to run, so no stored constant can ever be right. A full calibration also refuses
to store a result whose residual SD exceeds 1 ms.

Verified in `selftest` from known latencies — a sign error in the derivation would be
invisible in normal use and would bias every asynchrony the app ever reports.

Stored at `~/Library/Application Support/MusicalTrainer/calibration.json`.

---

## 7.3 M2 — TimingCore, as built

`Sources/TimingCore`, a pure Swift library with no AVFoundation, CoreMIDI, or CoreAudio, so
it runs under `swift test`. The executable now depends on it (shared `Stats`). 25 tests, all
against synthetic data whose answer is known by construction.

| Type | What it provides |
|---|---|
| `Grid` | Index-arithmetic metronomic grid. Extends infinitely, so dropout sections still have a reference. Floored-modulo subdivision phase. |
| `Tap` / `MatchedTap` / `MatchResult` | The domain model. Sign convention: **− is rushing, + is dragging** — load-bearing. |
| `Matching` | Aligns taps to the grid with a ±40%-of-subdivision window. Defeats the §5.3 sign-inversion trap; resolves double-triggers; reports extras and misses separately. |
| `WingKristofferson` | Clock/motor variance split (§5.2). Self-flags when γ₁ > 0 (drift breaks stationarity). Recovers planted variances to within 8% on 20 k samples. |
| `TimingReport` | Assembles mean/SD/median asynchrony, lag-1 autocorrelation (§5.1), drift → tempo error, per-subdivision spread, velocity/timing coupling, and one plain-English headline. |

Design decisions worth keeping:

1. **TimingCore knows nothing about host time, MIDI, or audio.** It takes `Tap` times on a
   shared timeline and a `Grid`. That ignorance is what makes it testable, and it is why the
   diagnostic math could be verified before any capture UI exists.
2. **Extras and misses never enter the asynchrony statistics.** A note between beats or a
   dropped beat is counted and set aside, never folded into mean/SD, per §5.3.
3. **The headline leads with chasing.** When lag-1 autocorrelation is strongly negative the
   report says so first — that is the finding that matches the original complaint, and the
   copy informs rather than scolds (negative mean asynchrony is normal).
4. **Population vs sample moments are deliberate.** Wing–Kristofferson uses population
   variance/autocovariance (its definition); reported spread uses sample SD.

**Not yet wired:** nothing in the app calls `TimingReport` on real playing yet — that needs
a captured session, which arrives with M3/M4. M2 is the verified engine those milestones
will feed.

---

## 7.4 M3 — groove engine, as built

**Open question #4 (drum samples) is closed by removal.** The kit is synthesized
procedurally (808/909-style: pitch-swept sine kick, tonal+noise snare, high-passed noise
hats, etc.) and rendered to sample buffers once at startup. No downloads, no licensing, no
provenance questions, sample-accurate, and tempo-agile — the last of which matters because
the ladder rewrites the groove mid-session, which sampled loops can't do.

Pure logic lives in `GrooveCore` (its own library target, 12 tests):

| Type | Role |
|---|---|
| `DrumVoice` / `Hit` / `Pattern` | One grid resolution (16 steps, 4/beat) so every bar is the same number of samples and the sample math stays trivial. |
| `Section` / `Arrangement` | Sectional contrast with per-section fills; resolves an absolute bar index to the pattern that plays, with looping. |
| `Sequencer` | Pattern → `ScheduledHit` at absolute samples, by index arithmetic from a global step. **Verified drift-free to < 0.5 sample over 5000 bars at an awkward tempo.** |
| `DropoutLadder` | The §6 training ladder as pattern transforms: full kit → hats/beat → 2&4 → beat 4 → sparse downbeat → silence. |

Audio side (executable, `selftest`-verified without hardware):

- `DrumSynth` / `DrumKit` — the synthesized voices.
- `GroovePlayer` — output-only `AVAudioSourceNode`, same real-time discipline as `AudioIO`:
  state behind one pointer, callback only adds pre-rendered samples, schedule fixed before
  start. Master gain 0.6 for clipping headroom.
- `GrooveOfflineRender` — mirrors the mixing to a flat buffer so `selftest` can assert the
  groove has energy, a silence level is truly silent, and the mix never exceeds 0 dBFS.
- `groove [bpm]` command — count-in, the two-section demo arrangement with fills, the full
  dropout ladder, and a slam back to full kit. One continuous schedule (no gaps).

A note preserved for later: index arithmetic caught its own value in testing — computing a
hit position incrementally (round each step, sum) drifted 2 samples from rounding the global
step once. That 2-sample gap is exactly the accumulation error the design exists to avoid.

**Not yet wired:** the groove plays, but nothing captures the player's MIDI against it yet.
Closing that loop — record taps during a groove, apply calibration, run `TimingReport` — is
M4/M5.

---

## 7.5 M4 — jam capture loop, as built

The loop finally closes: play → capture → measure. Chosen console-first (with the user)
because the take screen is near-blank by design, so the console is a legitimate take
surface; SwiftUI's real payoff is the visual review (M5). Fixed-length takes for
repeatable baselines.

`jam [bpm] [bars]` — a 2-bar count-in, then N bars of a steady groove (`basicRock`) with
the Launchkey captured throughout. On stop it applies calibration, aligns to the groove
grid, runs the M2 `TimingReport`, prints it, and saves the session.

The technical heart is **reconciling two clocks**, the same problem M0 solved for the rig:

- `GroovePlayer` now publishes `(mHostTime, sample)` pairs from its render callback.
- `JamAnalysis.reduce` builds a `SampleHostMap` from them and lifts both the groove grid
  and the MIDI note-ons onto one seconds-since-epoch timeline.
- Calibration is applied by shifting every tap earlier by the stored constant, giving
  `asynchrony = (midiHostSec − clickEmitSec) − (L_midi + L_out)` — identical to the M0
  definition. `selftest` proves the constant is stripped with the correct sign (recovers a
  planted −9 ms async; a zero-constant run differs by exactly the 11 ms constant).

Sessions persist to `~/Library/Application Support/MusicalTrainer/sessions/` with the raw
taps and grid parameters, so M5 can re-analyze and plot without re-recording.

Decisions:

1. **Uncalibrated is allowed, with a warning.** No constant means the *bias* (mean
   asynchrony) is off, but spread, drift, and autocorrelation are untouched — so the take
   is still worth analyzing. The report flags the bias as unreliable rather than refusing.
2. **A one-beat guard band** drops count-in notes and the final ring-out so they can't pose
   as timing data.
3. **`basicRock`, steady eighths, for the baseline take.** Wing–Kristofferson is *not* run
   here — it needs an unpaced continuation, which only the dropout drills (M6) provide.
   M4 reports bias, spread, drift, lag-1 (chasing), subdivision spread, velocity coupling.

**Live monitoring.** A silent controller has no sound of its own, so you can't jam to it —
you have to *hear* what you play. `LiveInstrument` is a 16-voice polyphonic synth (normalized
sine-plus-harmonics through an ADSR, deliberately filter-free so it can't go harsh) that
sonifies the Launchkey in real time and mixes into the groove. Note events cross from the
CoreMIDI thread to the audio thread through a single-producer/single-consumer lock-free ring;
the render thread never allocates or locks. The master bus is soft-clipped (`tanh`) so held
chords over the drums can't exceed 0 dBFS. Wired into both `jam` and `groove`. Monitoring
latency is ~15 ms (buffer + output + MIDI), independent of the *measurement*, which uses the
MIDI host timestamp and is unaffected.

**Chord handling (found in the first real take).** A keyboardist plays chords, and the first
jam reported 256 of 393 notes as "between beats" — they were chord tones, not timing errors,
because matching keeps one note per grid point. `TapClustering` (in TimingCore) now collapses
note-ons within ~35 ms into one rhythmic event before matching; the first take re-analyzed
went from 256 off-grid to 2. The window is well under any single-note run, so genuine notes
are never merged. "Missed grid points" is no longer surfaced in the jam report — in free
playing you simply aren't playing every subdivision.

**`review [list]`** re-analyzes saved takes with the current analysis (the raw taps are
stored, so improvements like chord clustering apply retroactively). A console stand-in until
the M5 visual review.

**Uncertainty, because the first experiment needed it.** Comparing a relaxed take to a
"counting" take, the differences were small — but point numbers can't say whether small is
real. `Bootstrap` (in TimingCore) adds 95% confidence intervals by a **moving-block**
bootstrap: asynchronies are serially correlated (that correlation is the r₁ we report), so
resampling single points would understate the uncertainty; resampling contiguous blocks
preserves it. Every take now prints CIs, and `review compare [i j]` bootstraps each
*difference* and labels it "real change" or "within noise" (does the interval for the change
exclude zero). The first relaxed-vs-counting comparison came back "within noise" on all three
metrics — while the single-take r₁ interval `[+0.22, +0.49]` excludes zero, confirming the
drift/under-correction signature is real, not sample noise. Lesson recorded: the "counting
makes it worse" effect, if real, needs a more demanding task than slow block chords on the
beat, plus more events for power.

**Conditions and self-rating.** `jam [bpm] [bars] [tag]` labels a take with the state it was
played in, and after every take — *before* any numbers appear — the player rates how it felt
1–5. Rating first matters: a rating shown after the measurement would just echo it.

Three readouts: `review tags` (pooled summary per condition), `review conditions <a> <b>`
(pooled bootstrap comparison, the experiment readout), `review feel` (does the player's sense
of a good take track the measured spread?). Pooling resamples blocks *within* each take and
concatenates, so a block never spans a session boundary. With fewer than 3 takes per
condition the comparison says so explicitly — the intervals cover within-take variation but
cannot see session-to-session variation, so a null result is not yet trustworthy.

**Confound flagging, added after one bit the analysis.** The jam backing was changed
mid-project (plain groove → sectional with fills). The July and August takes then differed in
spread by a statistically real 8 ms, which read as "your timing got worse" when part of it was
simply different music. `review compare` and `review conditions` now name any difference that
makes a comparison unsafe — backing, tempo, output device, calibration presence — and
`review tags` warns when a single pooled condition mixes them, where no comparison step would
ever surface it. Each note says *which* metrics are affected: a device or calibration change
moves bias only, while backing and tempo move spread and drift too.

The self-rating is not decoration. If feel correlates with spread, the player's instinct is a
calibrated instrument they can trust mid-practice; if it doesn't, that gap is the finding and
it explains a lot about "everything makes sense by feel."

**Backing is now sectional** (`GrooveLibrary.jamBacking`): 8-bar sections alternating hat and
ride, each capped with a fill. Variety keeps a long take from going hypnotic, and the fills
are landmarks — see §6.1. Both sections share a rhythmic skeleton so the timing demand stays
constant and only the colour changes.

**Deferred:** the SwiftUI eyes-off take screen and the Swift Charts review (M5) wrap this
verified engine next.

---

## 6.1 Form awareness — a second axis

Stated goal, in the player's words: *"I want to instinctively feel when I am 16 or 32 bars in
and have full confidence."* Plus: *"everything makes more sense by feel, flow, and sound vs
bar, beat, and measure count."*

This is a **different measurement from everything above.** §5 measures beat-level placement
in milliseconds. Form awareness is phrase-level — tens of seconds — and it is a distinct
skill: knowing *where you are* rather than *whether this note is early*. A player can have
tight beat placement and no form sense, or vice versa.

**Why it is trainable without counting.** Form sense is built from *sonic landmarks*, not
arithmetic. You feel "16 bars" because the music told you — a fill landed, the section
turned, the pattern resolved. The internal clock entrains to the period. Counting is the
crutch that prevents the entrainment, which is why §7.5's sectional backing (fill every 8
bars) is a training feature and not just anti-boredom.

**How to measure it — the phrase-mark drill.** During a jam, the player hits one designated
key at what they feel is the downbeat of each phrase (say every 8 bars), without counting.
Two errors fall out, and they are qualitatively different:

- **Phase error** (ms/beats from the true downbeat) — fine-grained placement, the §5 metrics.
- **Form error** (whole bars off) — did they lose the count entirely? This is the spatial
  awareness number, and it is the one that matters here.

Progression: strong landmarks (fill every 8) → weaker (fill every 16) → none → landmarks
under dropout, where the band is absent across the phrase boundary. That last stage is the
real test and it composes with the §6 dropout ladder.

### Built — `form [bpm] [bars] [phraseBars] [level]`

`FormAnalysis` (TimingCore, 8 tests) decomposes each mark into `formErrorBars` (whole bars
from the phrase top — the spatial-awareness number) and `phaseErrorMs` (placement against
the nearest bar line). Keeping them apart is the point: landing crisply on the wrong downbeat
and landing sloppily on the right one are different failures needing different work.

Four levels strip the landmarks away: fill every phrase → fill every two → no fills →
**silence across the boundary** (band leaves two bars before the turn and returns two bars
after, so nothing marks the corner). The report suggests the next level only when the current
one is ≥90% on-form with no unmarked phrases.

**A design failure worth remembering.** The first build put a crash on the downbeat of the
*fill* bar and let the fill replace the groove. So the loudest event in the drill landed
exactly one bar before the downbeat the player was asked to mark, and the pulse vanished for
half a bar right at the turn. The player marked the crash and scored 45% then 11% on form,
rating both takes 1/5 — *the app taught them to be wrong*, and the data was meaningless.

Two invariants came out of it, now enforced by tests in `FormBackingTests`:

- **Nothing louder than the groove may land anywhere except the downbeat being marked.** A
  crash one bar early is not a minor mix issue; it inverts what the drill measures.
- **The pulse never stops through the turn.** Fills add to the groove rather than replacing
  it. A player who loses the beat across the boundary has to re-find it afterwards, which is
  the opposite of the skill being trained.

The level ladder was restructured around the same insight, into react → anticipate → generate:
`0` fill + crash on the downbeat (the crash *confirms* the arrival), `1` fill only — nothing
confirms it, so you must commit, `2` no fills, `3` silence across the boundary. At level 0 a
mark can be a reaction rather than an anticipation, and the phase error says which: a mean
around +150–250 ms is reaction-time distance, and the report names it.

`FormLevel` and `FormBacking` live in GrooveCore rather than the command, because the layout
is pure logic and the bug above proves it needs tests.

Also added: a **"nailed it"** count — on the right bar *and* within 25% of a beat of the
downbeat. "Right bar" alone is a generous ±1.2 s at 100 BPM, generous enough to call a badly
placed mark a success.

Two further design details:

1. **Pads mark, keys play.** The Launchkey puts pads on MIDI channel 10 and keys on channel 1,
   so the drill separates "where am I" from "what am I playing" with no configuration. Pads
   render as an unpitched click through `LiveInstrument` rather than a synth note — an
   acknowledgement, not something you played.
2. **Unmarked phrases are reported, and they matter.** Nearest-phrase matching would score a
   player who is a *whole phrase* behind as flawless, since they still land on phrase tops.
   The unmarked-phrase list is what exposes that; there is a test for exactly this case.

**Reported failure modes to design against** (the player's own account): losing count or
over-stressing bar count; overthinking what to play next; attention wandering until "brain
jumps out of sync with body," then trying to consciously jump back in. All three are
*conscious-monitoring* failures, and the last one is the most telling — the recovery attempt
is itself the disruption. Drills should reward re-entry by feel and never require a running
count.

---

## 7.6 M5 — the app, as built

Sharing an engine between two front ends needs it in a library, so the executable was split:
`TrainerKit` now holds audio, MIDI, synthesis, calibration, sessions, and the drill runners;
`TimingSpike` is the console front end and `MusicalTrainerApp` the SwiftUI one. **Neither
surface contains measurement logic** — `TrainerEngine.runJam` / `runForm` / `playGroove` are
the only implementations, so the two can never drift apart.

Screens: setup → take → **rating** → results, plus history.

Two decisions worth keeping:

1. **The take screen has nothing to read.** No numbers, no elapsed time, and deliberately no
   progress bar — a progress indicator during the form drill would replace the felt sense of
   the phrase with a visual count, which is the exact crutch being trained away. A slow
   breathing circle is all that's on screen.
2. **The rating screen sits between the take and the results.** A rating given after the
   numbers are visible is a rationalisation of them; the whole point of storing it is to test
   whether the player's own sense of a good take predicts the measurement.

Results use Swift Charts — asynchrony scatter for jams, per-phrase form error for drills —
and history plots spread (jams) or on-form rate (form) over time.

`build-app.sh` wraps the SPM binary in a minimal `.app`. Without a bundle macOS treats the
executable as a background process: no dock icon, no menu bar, and no Info.plist, which means
no way to request microphone access for calibration.

**Stopping a take.** The take screen has a *Stop and discard* button, plus `esc` and `⌘.`, so
a take started with the wrong device, tempo, or a dead keyboard can be abandoned instead of
sat through. A `CancellationFlag` is polled by the player's wait loop — never by the audio
render callback, where taking a lock could glitch — and the runner throws `TakeCancelled`,
which the app treats as a normal outcome rather than an error. Measured: a 156-second take
stops 1.2 s after the request.

The recording is **discarded, not analysed**. A take abandoned because something was wrong is
not worth measuring, and saving a fragment would quietly pollute both the history and the
pooled per-condition statistics.

Not yet in the app: calibration and the M0 diagnostics, which remain CLI-only.

### A bug only the app could have

The first take in the app worked; the next one failed with
`MIDIClientCreateWithBlock failed: -50` (paramErr). The CLI never showed it.

`MIDIServer` is an on-demand daemon: when the last client **in the system** goes away, it
exits. `MIDIInput` was creating a client per take and disposing it at the end, so after a
take the daemon shut down, and the next `MIDIClientCreateWithBlock` in the *same* process
failed. The CLI was immune because every invocation is a fresh process. Rapid create/dispose
loops were also immune — the daemon never got the chance to exit, which is why the first two
probes came back clean and only a probe with a real idle gap reproduced it:

```
first create: status 0
disposed; idling 75s so the on-demand server can exit…
create after idle: status -50  <-- FAILURE
```

The fix is the pattern CoreMIDI expects anyway: **one client per process, created once and
never disposed** (`MIDIInput.shared`). Ports and source connections are refreshed per take —
which also means a keyboard plugged in after launch is now picked up without a restart, and
sources are tracked by unique ID so nothing is connected twice and delivers doubled events.

---

## 7.7 M6 — the continuation drill, as built

`dropout [bpm] [pacedBars] [silentBars] [cycles]`, and **Alone** in the app. The band plays,
falls completely silent, and slams back in with a crash. You play **one note per beat the
whole way through**.

This is the only drill that can produce the §5.2 clock/motor split, because that decomposition
requires an *unpaced* sequence — the player generating the pulse with no reference. Everything
else in the app measures synchronisation *to* something. Here the silences are the measurement.

Why it matters for this player specifically: every jam take shows r₁ solidly positive
(+0.23 … +0.47), i.e. under-correction — the placement floats and wanders. But r₁ cannot say
*why*. An unstable internal clock and noisy motor execution produce identical wander and feel
identical from the inside, while needing completely different training. This drill separates
them.

Three measurement decisions worth keeping:

1. **Drift is measured by fitting the player's own period, not by matching notes to the grid.**
   Drift is cumulative, so a player who has slid past half a beat starts matching to the
   *wrong* beat and the estimate silently collapses toward zero — at exactly the moment it
   matters most. Fitting the period has no such ceiling. It also normalises for subdivision,
   so doubling up doesn't read as playing twice as fast.
2. **Re-entry is measured against the known return downbeat**, not the nearest beat. We know
   exactly when the band came back, and a drifted player can be most of a beat away — where
   nearest-beat matching would flip the sign and report a small error instead of a large one
   (the §5.3 trap again). A test caught this.
3. **Wing–Kristofferson pools trials with each centred on its own mean.** A tempo that differs
   from one silence to the next would otherwise be counted as clock variance, inflating the
   very number the drill exists to produce. Products are never taken across a boundary where
   the band was playing.

**Adaptation is between sessions, not within one.** Changing the silence length mid-take would
give trials of different lengths, and pooling those weakens the variance estimate. Instead the
report suggests the next difficulty from measured drift: under ~1.5 ms/beat doubles the
silence, over ~5 ms/beat halves it.

Verified against synthetic continuation processes of known clock and motor variance, including
one where trial tempos deliberately differ, and one where naive concatenation would invent a
lag-1 term at a trial boundary.

### Also in this pass

- **Form takes default to 64 bars** in the app (8 phrases, ~10 marks). At 32 bars an 8-bar
  phrase gives only 4 phrases and 5 marks — too few to tell a real slip from noise, which is
  exactly the limitation the first level-2 results ran into.
- **History covers all three drills** with per-drill trend lines, each labelled with which
  direction is improvement (spread down, on-form up, clock SD down). That is the M7
  groundwork: the storage and the uniform `HistoryEntry` shape are in place, so deepening the
  longitudinal view later needs no migration.

---

## 7.8 M7 — trends, and what the first continuation data actually showed

### The drill reported a conclusion it hadn't earned

The first three continuation takes returned clock SD = 143 ms, 23.8 ms, 13.8 ms with motor
SD = 0.0, 0.5, 8.0 — and a "drift" of +22 to +39 ms/beat. **A motor SD of zero is not a
measurement of a human**; Wing–Kristofferson puts motor variance at −γ₁, so a sequence with no
negative lag-1 pins it at the model's floor. Two of the three takes were reporting the floor,
not the player. Inspecting the raw taps showed why:

- **Take 1 had eighth notes mixed into the quarters in half its silences.** W-K assumes an
  isochronous sequence; that take violated the assumption outright, and the 143 ms was noise
  dressed as a result.
- **"Drift" was a misleading label.** It measured the *difference between the player's period
  and the grid's* — a steady tempo offset, not acceleration. Reporting "+34 ms/beat" made a
  consistent 5% tempo bias look like the pulse falling apart.

Fixes, all tested:

1. **Isochrony validation.** A silence whose intervals stray outside 0.6–1.6× its own median
   (in more than a quarter of cases) is discarded, and the count is reported. Consistent
   subdividing is *accepted* — eighths all the way through is still a valid continuation —
   but the period is normalised so steady eighths don't read as double tempo.
2. **`splitIsReliable`.** The clock/motor split is only shown when at least two usable trials
   survive and the motor estimate is clear of the model's floor. Otherwise the report says so.
3. **Tempo bias replaces "drift" as the headline**, in BPM and percent, with within-silence
   acceleration reported separately as the different quantity it is.
4. **Stored drills recompute from raw taps** (`DropoutSession.reconstruct()`), so an analysis
   fix reaches takes recorded before it — this one did. `SessionStore` also now warns when
   sessions fail to decode rather than dropping them silently.

### What the corrected analysis says

| take | usable silences | clock / motor | tempo alone |
|---|---|---|---|
| 1 | 3 / 6 | unreliable | 98 BPM (−2) |
| 2 | 6 / 6 | unreliable (motor at floor) | 94 BPM (−6) |
| 3 | 6 / 6 | 13.8 / 8.0 ms | 95 BPM (−5) |

**Solid: an unaccompanied tempo bias of −5% or so, in every take and every clean silence.**
Left alone the player settles around 94–95 BPM against a 100 BPM click.

**Not established: that the clock is the problem.** Exactly one take yields a trustworthy
split, and it puts clock at ~1.7× motor. Suggestive, n=1.

The striking part is the dissociation with the jam data: **with** the band the player is
consistently *ahead* (mean asynchrony −3 to −15 ms, i.e. rushing), yet **without** it the
self-generated period is ~5% *slower* than the reference. Those are not contradictory — one
is placement against a beat that is given, the other is the period produced from nothing — but
together they describe someone whose natural period sits below the click while being pulled
forward by it. That is a plausible mechanism for "everything feels forced," and it is
testable: the prediction is that the bias shrinks at a target tempo nearer the natural one.

### `review trend`

Fits each metric against take number with a bootstrap interval on the slope, and **splits
confounded groups rather than blending them** — jams are grouped by tempo, because a tempo
change moves timing spread on its own; mixed backings and mixed form levels are flagged. With
9 jams, 3 continuation takes and 5 form takes, everything currently reads "flat", which is the
correct answer at this sample size rather than a disappointing one.

---

## 7.9 Training the internal clock — the plan

Aimed at what the data actually supports, in order of confidence.

**Target 1 — the tempo bias (solid).** Unaccompanied, the produced period is ~5% slow. This is
a *calibration* error, not an instability, and calibration errors respond to feedback.

The drill (M8): the click gives four bars, falls silent, the player produces sixteen beats
alone, and the app reports the tempo produced — "you played 95, target was 100." Repeat
immediately. This is a closed feedback loop on exactly the quantity that is off, and it is
mostly assembled from existing parts (`DropoutDrill` plus the tempo estimator built above).

Two refinements worth having:

- **Bracketing.** Ask for deliberately fast, then deliberately slow, then target. Producing a
  range on purpose loosens a stuck internal period faster than aiming at one number.
- **Vary the target.** Rotate 76 / 100 / 132 rather than always 100. A clock calibrated at one
  tempo is a lookup table; the goal is the mapping.

**Target 2 — the clock/motor split (unestablished; needs data).** Three or four clean
continuation takes — steady quarters, no subdividing — would settle whether the clock really
is the looser half. That determines what comes after M8:

- *Clock-dominant* → keep training period production: longer silences, tempo memory (hear a
  tempo, wait, reproduce it).
- *Motor-dominant* → different work entirely: evenness at speed, dynamics, and the
  velocity/timing coupling the jam report already measures.

**Target 3 — the rush/slow dissociation (a hypothesis worth testing).** If the natural period
really sits near 95, jamming at 95 should shrink the −5 to −15 ms rush. That is a two-session
experiment with the tools that already exist: three tagged takes at 100, three at 95, then
`review conditions`. A confirmed result would mean some of the "forced" feeling is a tempo
mismatch rather than a skill deficit.

**What not to do.** Nothing here says practice harder or count more carefully. The r₁ evidence
is consistent across all nine jams: this is under-correction, not chasing, and adding conscious
control is the documented way to make that worse.

---

## 7.10 M8 — tempo calibration, as built

`tempo [bpm ...]`, and **Tempo** in the app. The click establishes a target, falls silent, the
player holds the tempo alone, and the app reports the tempo actually produced — then the click
returns so the correction can be made immediately and tried again.

This targets the one finding §7.8 established solidly: unaccompanied, the produced period runs
~5% slow. That is a **calibration** error rather than an instability, and calibration errors
respond to feedback in a way that variance does not.

Design decisions:

1. **Feedback per round, not per session.** The learning is in the loop — produce, be told,
   correct, produce again. One long take would give a better variance estimate and no training.
2. **Rotating targets.** `tempo 76 100 132` cycles the target between rounds. A clock
   calibrated at one tempo is a lookup table; rotating trains the mapping from a named tempo to
   a period. The scheduler advances its sample cursor round by round so each round can run at
   its own tempo.
3. **Accuracy, not bias, is the number to drive down.** Bias is signed and tells you which way
   you err; mean absolute error is what improves. Both are reported, and the within-session
   slope says whether the loop is actually working today.
4. **Unscorable rounds say why.** Fewer than five notes, or a mix of note values, and the round
   reports "not one note per beat" instead of a confident wrong number — the lesson of §7.8.
   Consistent subdividing is accepted and normalised.

## 7.11 Instructions

Every drill's instructions now live in one place (`DrillInstructions`) and are rendered by both
the console and the app: goal, numbered steps, the mistakes that *invalidate* the measurement
rather than merely lower the score, and what the drill reports back.

This is a correctness concern, not a presentation one. The form drill already lost two takes to
an instruction ambiguity (§6.1), and instructions duplicated across two surfaces drift — at
which point the same drill silently means two different things depending on where it was
started.

---

## 7.12 Codebase review

A pass over all ~9,100 lines. Build is warning-free; the render callbacks contain no
allocation, locks, prints or ARC traffic. Four real defects found and fixed:

1. **Takes that end in silence were being truncated.** `run(forSeconds:)` derived its length
   from `scheduledDurationSeconds()`, which reports the position of the last *sound*. The
   tempo drill always ends with a silent hold, so **the entire final round was cut off** —
   9.6 s at default settings — and the form drill at level 3 lost its last two bars. The
   config already knows the intended length, so it is now authoritative
   (`max(intended, scheduled)`, so a trailing cymbal decay is never clipped either). The
   dropout drill was accidentally safe: it ends with a trailing paced section.
2. **Per-round feedback wasn't per-round.** `runTempo`'s `roundFinished` callback fired for
   every round at once *after* the take, while both the printed and on-screen instructions
   promised feedback as you go. Since the whole point of M8 is a closed loop, the code was
   changed to match the promise: each round is scored the moment its silence ends.
3. **A data race introduced by that fix.** Scoring mid-take means reading `MIDIInput.events`
   while CoreMIDI writes it, which the type's own comment said never happened. Capture is now
   behind an `os_unfair_lock` — that is the MIDI delivery thread, not the audio thread, so a
   lock costing nanoseconds a few times a second is free. The audio-side map cannot take a
   lock, so instead the live path reads only `startHostTime` (entry 0, written once on the
   first callback and immutable thereafter) and converts at the nominal sample rate; the
   saved result still uses the full map after the engine stops.
4. **The app never showed the feedback the CLI did.** `runTempo` was called without the
   callback, so the app's tempo drill silently lacked its central mechanism while its
   instructions described it. The take screen now shows the last few rounds — the one
   deliberate exception to §2's blank-screen rule, and it appears during the click bars,
   never during a measured silence.

Also removed one dead property, and documented the cached summary fields in the session
types: nothing reads them back (every view recomputes from raw taps so analysis fixes apply
retroactively), but they keep the stored JSON legible.

---

## 7.13 Roadmap M9–M23

Direction set with the player: **training depth** over new instruments or packaging;
**20–30 minute structured sessions**; **research built in as a first-class feature** rather
than run by hand. Ordered by dependency and value, not difficulty.

Seven entries were added after the original M9–M22 list and sit out of numeric order below, where
their dependencies put them: **M16.5** (the skank family), the **M20 note**, **M23** (jazz time,
deferred with its argument), **M24** (voice, which depends on M21's onset detection rather than
on M23), **M25** (harmony), **M26** (the kit — the synthesis work that makes a genre name
sound true, §7.30) and **M27** (what makes a genre that genre — the classification problem
underneath the name).

**M19 ran ahead of M16**, decided with the player on 6 August. M16's span ladder grows the
phrase to 32 bars and there was no backing that sustains 32 bars, so the ladder would have been
built on music that cannot carry it; M16.5's organ bubble needs a triplet skank backing, and M19 is
where the pattern format is settled. Building M19 second would have meant revisiting both.

**That dependency is discharged and both are built**: M19 with a live run (§7.33, §7.34), M16 as
steps 0–4 (§7.40–§7.45). What M19 did *not* settle was whether the form drill's own backing should
draw on a style — `FormBacking` builds its own patterns and has no sectional variety, and the
worry was that a 32-bar phrase over it would be hypnotic well before the boundary arrived.
**Answered by playing one, and the answer was the opposite of the worry** (§7.42): uniformity is
the control that makes a level mean what it says, because a backing that varies hands the player
timing landmarks the ladder exists to remove. The hypnotic risk is real for a long *jam*, which is
what M19's styles are for, and this drill is a different task.

**What does not wait for M19 is M16's other axis.** The decision below splits form into a
spatial ladder and a temporal one, and only the spatial one needs longer music — levels 0→3 at a
fixed 8-bar phrase run on today's backing. Since the level-3 probe is the piece the player asked
for first, it goes before M19 rather than behind it. See §7.26.

### M9 — Session builder
The app proposes and runs a whole session: warm-up calibration, two or three drills chosen
from recent data, then a longer jam. One click to start; it moves between drills itself.
Everything until now has been a menu of drills — this is the first milestone that decides
*what to practise today*. Depends on nothing new; the drills exist.

### M10 — Cold vs warm
The first tempo data improved monotonically inside one sitting (−4.7% → −0.3%), and nothing
in the app can say whether that is learning or dust shaking off. This adds a deliberate
**cold measurement** as the first thing in every session — before any warm-up — and tracks
cold-start values across days separately from within-session gains. Small, and it answers a
question that is currently blocking interpretation of every trend.

### M11 — Clock stability drills
The measured weakness: clock 14.9 ms vs motor 9.3 ms, clock larger in 5 of 5 clean takes.
Drills that train period *stability* specifically — longer silences, tempo memory (hear a
tempo, wait through a distractor, reproduce it), and sustained holds at the edge of what the
player can keep. Difficulty driven by measured clock SD.

### M12 — What you play
**The player's own observation, from the first full session:** steady quarter notes with no
pitch change are close to sleep-inducing, while playing an actual melody feels far more in the
pocket. That is a hypothesis about *musical content changing timing*, and it is the most
interesting untested claim in the project — because if it holds, "practise a boring exercise
until it is tight" is the wrong prescription for this player.

It is also, right now, unanswerable: every jam take stored *when* a note happened and threw
the pitch away. The storage half landed immediately (§7.17) so that data collection can start
before the analysis exists — the same reasoning as `SessionPlacement`, and for the same reason:
a take recorded without pitch is lost to this question for good.

The milestone itself is the analysis and the drills:

- **Content measures per window** — note density, pitch-class variety, mean melodic interval,
  contour reversals, chord size, velocity spread. Computed over 4- or 8-bar windows.
- **Within-take correlation** of content against timing spread. Within-take is the strong
  design: it holds the day, the fatigue and the tempo fixed, so it cannot be explained by the
  confounds that a between-take comparison would carry.
- **Deliberate conditions** through the M13 runner — the same take length played as steady
  quarters, as a written melody, and as free improvisation.

Three traps to design against, all visible in the first session's data:

1. **Off-grid notes are censored, not counted.** Spread is computed only on notes inside the
   matching window, so a more adventurous take drops more notes out of the statistic and the
   surviving SD is a self-selected subset. Off-grid rate has to be reported next to spread,
   never behind it.
2. **Melodic playing uses more subdivisions**, and spread scales with the subdivision. The
   comparison has to be per-subdivision or it measures note values rather than content.
3. **Content and arousal are confounded.** Playing something interesting is both more melodic
   *and* more engaging, and this design cannot separate them. Worth stating rather than
   quietly claiming the melodic half.

### M13 — Experiment runner
Makes the research first-class: the app schedules its own A/B conditions (steady vs melodic,
relaxed vs focused, tempo A vs B, cold vs warm), keeps them balanced, refuses to draw a
conclusion before it has power, and says how many more takes it needs. Confounds have already
crept into this dataset by hand — a changed backing, a changed tempo — and this removes the
opportunity. Promoted above the feel work because M12 and M14–M15 all need it to produce
clean comparisons.

### M14 — Subdivision ladder, and the tempo axis
Every drill so far is quarter notes at 100 BPM, straight. This adds eighths, sixteenths and
triplets — both as backing and as what the player is asked to produce — and makes **tempo a
measured variable rather than only a confound to be split apart**.

The two are one axis: subdivision and tempo both move the inter-onset interval, and eighths at
100 BPM are the same 300 ms as quarters at 200. The player's own hypothesis — that faster is
easier to a point, and that slow tempos make him rush — is the first question on it, and nothing
in the app can currently ask it. Straight time only; the grid stays where it is. See §7.23.

One correction to the note this entry used to carry: `TimingReport`'s subdivision statistics are
**phase-conditional** — where within the beat a note landed — not a measure of the note values
played. That machinery is live and already showing something (§7.23), and it is not the ladder.

### M15 — The feels
**Stated goal, in the player's words:** to handle "anything from classical and straight time,
to swing time, jazz comping timing, to the off-beat timing of ska and reggae."

This is the largest measurement change since M2, because every one of those styles moves the
*target*, not just the tolerance. Everything the app measures today assumes a note is aiming
at an even subdivision of the beat; in swing it is aiming at roughly two-thirds of the way
through, in reggae at the offbeat, and in jazz comping at a placement that is deliberately
elastic. Matching those against a straight grid would report style as error — the same class
of mistake as §5.3's sign inversion, and far more insidious because the numbers stay
plausible.

So the grid itself becomes parameterised:

- **`Grid` gains a feel**: an expected phase offset per subdivision, not just a count.
  Straight is the special case where every offset is zero.
- **Swing ratio becomes a measurement**, not a setting. Given eighth-note playing, the ratio
  of long to short is the thing to report — and *consistency* of that ratio is the skill, in
  the same way SD rather than bias is the skill for straight time. A player at a steady 1.7
  is swinging; one oscillating between 1.4 and 2.0 is not.
- **Offbeat placement as its own drill.** Ska and reggae put the emphasis where the grid says
  nothing is: the measurement is placement against beats 2 and 4 upbeats with the downbeat
  deliberately *unaccompanied*, which is a form of dropout the app already knows how to build.
- **Jazz comping** is the hardest and comes last within the milestone: the target is a
  distribution rather than a point, so it needs a different scoring model — probably
  "did you land inside the idiomatic window, and did you vary within it?" rather than a
  distance from a grid point.
- **Backings per feel**, since a swing drill over a straight-eighths backing teaches the wrong
  thing. Shares work with M19.

The ladder across the whole milestone: straight → swing at a fixed ratio → swing where the
ratio is yours → offbeat feels → comping. Each rung needs its own backing, its own grid, and
its own idea of what "on" means.

### M16 — Form ladder v2
The level-2 data showed the player marking a steady **4-bar** phrase against an 8-bar
setting: a consistent feel, not a lost one. Phrase length becomes a trained variable in its
own right — nested phrasing (4 inside 8 inside 16), explicit "which period do you feel?"
probes, and a ladder that grows the span rather than only removing landmarks.

**Reframed once twelve form takes existed, and settled with the player on 6 August — see §7.26
for the design and the data behind it.** The premise above is one observation; twelve takes say
the felt period is *unstable* rather than merely different, which is a finding about the player
rather than a setting to chase. So the milestone splits the two things the form drill has been
conflating — *where am I* (spatial, whole bars off the phrase top) and *how cleanly did I land*
(temporal, milliseconds off the bar line) — and gives each its own ladder. At 8 bars he finds
the right bar 75% of the time and lands cleanly on 23%; at 4 bars, 64% and 38%. Those move in
opposite directions and one ladder cannot train both.

Three decisions, all the player's:

- **One axis per sitting, chosen by the planner.** Two form blocks in an evening is more form
  than the session budget has room for, and running both at once reintroduces the confound the
  milestone exists to remove.
- **Level 3 is worth forcing, as a probe.** Neither form level 3 (silence across the boundary)
  nor offbeat level 3 has ever run. A single deliberate take says more than another six at
  level 2 — but a probe is not a rung, and §7.26 records the trap that makes that distinction
  load-bearing rather than pedantic.
- **M19 first**, for the span ladder and for M16.5's backing. The temporal ladder does not wait.

### M16.5 — The skank family
The offbeat drill (§7.24 step 6) trains one thing the player has named as a skill he wants: the
**skank**. It is also the drill that generalises furthest, because "hold a position the band never
plays" is not specific to ska.

`OffbeatAnalysis` currently hardcodes one asked-for phase — `subdivisions / 2`, the "and" — and
one forbidden one, the downbeat. Generalising that to a **set** of asked-for phases against a set
of forbidden ones costs very little and opens the whole family:

| Feel | Rung | Play | Rest on |
|---|---|---|---|
| Ska / reggae skank | eighths | the "and" | the beat |
| **Organ bubble** | triplets | the 2nd and 3rd of each triplet | the beat |
| Charleston, one-drop variants | eighths | selected offbeats only | the beat, and the unselected offbeats |

> **Status, 13 August (§7.55, §7.56).** Step 0 is built: both candidate figures exist, both render,
> and the organ they are heard on exists. **The choice between them is blocked** — the player heard
> neither as a bubble, named the cause as the same tone handicap §7.33 records, and asked for
> keyboard voices that need references nobody has yet. What is *not* blocked is the analysis
> generalisation below, which is independent of which figure wins.

**The organ bubble is the one to build next**, and the reason it is cheap is that the analysis
already refuses to count notes that are neither the beat nor the asked-for point — that behaviour
was written for stray sixteenths and is exactly what a two-of-three pattern needs. What it needs
that does not exist: a triplet skank backing, and a phase *set* rather than a single phase.

*Musical premise to confirm before building:* the characterisation assumed here is that the
bubble rests on the beat and plays the second and third of each beat's triplet, commonly with
alternating hands. The measurement follows from that and would change if the premise is wrong.

### M20 note — the skank is the natural first cross-instrument drill
§7.13's M20 argues that drum mode is worth building because "the measurement is unchanged (onsets
against a grid) while the *input mapping* and the *backing* both change, which is exactly the seam
M21 and M22 have to widen."

The skank family is that argument's best example. A guitar skank, an organ bubble and a drum
one-drop are **the same measurement** — notes on the offbeat, nothing on the beat, scored apart
from placement — with three different instruments and three different backings. When guitar input
arrives (M21), the offbeat drill is the first drill that should accept it, because nothing about
its analysis needs to change.

**A vocal skank is the same measurement again** (M24), and it is the one that tests the seam
hardest: the input is not an instrument at all, and if `OffbeatAnalysis` still needs no change
then the seam is genuinely where M20 claims it is. A chanted offbeat is also how the drill gets
practised away from the keyboard, which is the point of the skank being a stated training goal.

### M23 — Jazz time
**Deferred behind the instrument milestones, and the reason is a data problem rather than a code
one.** Recorded here so the deferral is on the record with its argument (§7.24 planning).

The measurement needs a target that is a *distribution* rather than a point, and there is no
definition of idiomatic available: no corpus, no reference pipeline, and one player. Any window
would be a number invented and then scored against, which §3 of `STANDARDS.md` forbids outright.

It is also not one skill. Comping on piano is a left-hand placement against a walking pulse nobody
is playing; jazz drumming is a ride pattern with independent limbs; scatting is phrase-level rubato
against an implied grid; guitar comping is different again. Each has a different target, a
different role, and a different notion of "on" — and the app has no concept of *role* until M20's
drum mode, which is the seam this needs.

**What could be built sooner, honestly framed as smaller:** elasticity itself is measurable with
tools that exist. *Did your placement vary at all, and was the variation structured or random?* —
a spread plus the lag-1 autocorrelation the app already computes. A player deliberately pushing and
pulling has structured variation; one who is merely loose has random variation, and r₁ separates
them. It does **not** answer "was it idiomatic", and should not be sold as though it does.

**Falsifier for the milestone:** if a reference corpus never becomes available, M23's scoring model
never becomes honest, and the right outcome is that it stays unbuilt rather than shipping an
invented window.

### M17 — Unified adaptive difficulty
Four drills now have four ad-hoc progression rules. Replace them with one model: a per-axis
difficulty estimate updated from measured performance, so the app can say "you are ready for
8 silent bars but not 16" consistently and across drills.

**This reads as consolidation and it is correctness.** There are now more than four ladders —
interval rungs, form levels, phrase spans, offbeat levels — and behind them a spread estimate that
decides *which rungs exist at all*. They are separate rules reading one corpus through separate
filters, and §7.52 is what that costs: the planner's own input counted every skank as a free jam
for the whole life of the offbeat drill, so the take that widened a trend also narrowed the ladder,
and unlike a readout nothing about it was visible. One model is the guard against the next one.

**Step 0 is §7.57 item 3**, moving task identity — `GroupKey`, `BackingGroup`, `DropoutKey`,
`FormKey` — out of `TrainerKit` and into `TimingCore`. Three defects have been about that list
(§7.24 step 8, §7.48, §7.52), it is pure logic, and it is currently on the side of the module
boundary that CI cannot compile. M17 needs exactly that vocabulary, so it is the first commit
rather than a chore done alongside.

### M18 — Longitudinal model
Separate the two effects properly — within-session improvement (warm-up) from
between-session improvement (learning) — instead of fitting one slope across everything.
M10 does this for one metric at a time; this generalises it into a single model over all of
them, and subsumes the current `review trend`.

**It now has a live question and still not the data to answer it.** §7.53 recorded r₁ running
+0.44 to +0.72 across three different tasks in one afternoon, against a historical 0.13–0.50 —
which is precisely the within-sitting-versus-between-sitting confound this milestone exists to
separate, and precisely what a single slope through everything would report as learning.

**Gated rather than scheduled, and the gate is stated so it can be met.** A model that separates
two effects needs both to be estimable: **six sittings carrying the same task, with at least three
takes of it per sitting.** Fewer than that and the between-sitting term is fitted on a handful of
points whose spread is dominated by the within-sitting one — the failure §7.25 and §7.32 both
found in smaller forms. The 13 August setlist is one such sitting. Playing is what advances this,
not building.

### M19 — Musical depth
Sectional arrangements with real dynamics, more styles, longer forms. No new measurement —
but a 30-minute session has to be worth playing, and the first live session already ended on
two 5-minute jams over a two-section backing. Sustainability is what turns any of this into
results.

### M20 — Drum mode
The pads and keys become a drum kit, and the roles invert: **the player is the drummer and the
backing is the click.** Levels from "keep a backbeat against the metronome" up through fills,
independence, and dropout of the click itself.

Two reasons this is worth building despite not being the player's instrument. It needs **no new
hardware** — the Launchkey already has pads and the synth already exists, so it is cheaper than
guitar. And it is the natural first test of multi-instrument support: the measurement is
unchanged (onsets against a grid) while the *input mapping* and the *backing* both change,
which is exactly the seam M21 and M22 have to widen.

**There is a real kit, and it changes the shape of this.** The player has a TDV6 drum module and
plans a USB→MIDI interface for it. That splits M20 in two, and the halves are not equally
expensive:

| | Path | Measurement quality |
|---|---|---|
| Pads as a stand-in | Launchkey over CoreMIDI | The validated path. Buildable today, no purchase |
| Real kit over MIDI | Module → USB→MIDI interface | **Also the validated path** — driver timestamps, no onset detection |
| Real kit over audio | Module line out → TS→USB adapter | An onset-detection problem, and an unnecessary one |

The middle row is the point. A drum module on MIDI is note-ons with driver timestamps, which is
what M0 validated and what every take on record already uses — so playing real drums is the
*same* measurement as playing the keys, with a different note mapping. **Do not route the module
through the audio adapter to save buying the MIDI interface**: it would turn a solved measurement
into M21's unsolved one for no gain. Worth checking on the first run whether the module adds
latency of its own between pad and MIDI out; a constant would calibrate away like any other, and
only its spread would matter.

### M21 — Guitar input
Audio onset detection through an interface, reusing the calibration and analysis already
built. A new input is additive once the drills and measurement are mature.

~~It is the only item requiring hardware the player does not own.~~ **No longer true.** He has a
cheap TS→USB adapter that already carries electric guitar, bass and amplifiers, with a better
interface planned. The blocker was never really the hardware anyway — it is that this is the
milestone where **audio onset detection has to be built and characterised**, and M24 then inherits
it.

Three things the adapter makes concrete rather than hypothetical:

- **Characterise the adapter for spread, not for offset.** A constant input latency shifts bias
  and leaves variance untouched (§ "On accuracy"), so a cheap converter is perfectly usable if its
  buffering is *stable*. If it is not, it injects jitter into the one quantity this project
  measures. That is a loopback measurement, and it must happen before the first guitar take
  rather than after a surprising one.
- **An amplifier is not a clean DI.** Distortion and compression smear the attack, which is the
  same problem M24 has with a sung vowel against a plosive — the transient the detector needs is
  exactly what a driven amp softens. Expect per-signal-chain onset bias, and characterise a
  distorted tone separately from a clean one rather than assuming one constant covers both.
- **Input devices need the calibration store's device keying.** Constants are already keyed by
  name *and* data source, because the speakers and the headphone jack are one CoreAudio device
  with different latency. An input device needs the same treatment, and it is the first time the
  store has held one.

### M22 — Computer-keyboard input
Timing capture from the Mac keyboard, for anyone who does not own a MIDI controller. Last on
purpose, and not only by priority: key-repeat suppression, rollover limits and the fact that
HID timestamps are not driver-level MIDI timestamps all mean the *measurement quality* would
have to be characterised from scratch — an M0-style validation run of its own before a single
number could be trusted. Better as an on-ramp for other players than as a way for this one to
practise.

### M27 — What makes a genre that genre
**The half of the problem M26 does not touch**, and the reason the styles are named
`driving`, `pocket`, `syncopated` and `half-time` rather than for genres today (§7.30).

A kit that sounds convincing is necessary and nowhere near sufficient. Naming a style `motown`
is a claim, and there is currently no way to state what the claim *is*, let alone check it. That
is a classification problem and it runs deeper than timbre and a step list:

| Axis | Example of what it decides |
|---|---|
| Instrumentation | Tambourine on eighths, or it is not Motown |
| Rhythmic placement | Where the backbeat sits, how far behind the beat the snare lies |
| Feel | Straight, swung, and how deeply — already modelled by `Feel` |
| Dynamics | The relationship between ghost and accent, not just their presence |
| Form | Where turnarounds fall, how long a section runs before it moves |
| Harmony and bass motion | Walking, static, or a root-and-fifth pulse — M25's territory |
| Tempo range | A groove that only works between 88 and 104 is a different claim |
| Register and arrangement | What occupies the mid-range, and what is deliberately empty |

**What this milestone owes:** a vocabulary for those axes, a way to write a genre's requirements
down, and a check that a style meets them — so "this is a Motown groove" becomes a statement with
a falsifier rather than a label somebody typed.

Until then a style is named for what it demonstrably *does*. That is not a retreat: it is the same
discipline as `unusableReason` and `splitIsReliable` — say the true thing, and do not let a label
imply a measurement nobody made.

*Depends on:* M26 for the kit, M25 for harmony, and probably a professional ear for the reference
recordings that define what each requirement actually sounds like.

### M26 — The kit
**The synthesis work that makes a genre name true**, settled with the player on 7 August and
argued in full in §7.30. The direction is explicit: keep the genre names, and make the kit good
enough to deserve them. No shortcuts.

**Promoted in front of M16.5, M20 and M23** — see §7.59. It is not a polish milestone; it is the
one other milestones are waiting on, and it has now blocked twice with the second worse than the
first. §7.33 cost four *style names*, renamed because a genre name claimed what the kit could not
deliver. §7.56 cost a *measurement decision*: M16.5 cannot choose between the triplet bubble and
the sixteenth one while neither can be heard as the thing it is supposed to be. A naming problem
is embarrassing; a milestone that cannot be decided is stopped.

**Items 1, 3 and 4 are what M16.5 needs**, and they are a smaller piece of work than the whole:
velocity layers, room and deterministic variation. A bubble is articulation and dynamics before it
is anything else, and the current kit has neither — one buffer scaled by gain, bone dry, every hit
byte-identical to the last. Item 2 is architectural and can follow; item 5, the bass, is not in
this figure's path.

**Note length belongs to the figure, not to the voice**, which §7.56 found and nothing yet models.
`OrganSynth.bodySeconds` is one number bounded by the tightest gap in the family, so every bubble
is staccato by construction, and *"the triplets with the right voicing and more of a legato"* is
outside what can currently be rendered. That seam is M16.5's, not M26's, but it is the same
discovery and neither is much use without the other.

Five things, in order of what each buys:

1. **Velocity layers** — a drum hit harder is a different spectrum, not the same one louder. One
   buffer scaled by gain is why a ghost note sounds like a fader move.
2. **A kit as a parameter set** — a Motown snare is tuned high and damped, a rock snare is fatter
   and rings. `Style` carries kit parameters; `BackingKit` takes them. Architectural, not tuning.
3. **Room** — the kit is bone dry, and dryness is most of what reads as "electronic".
4. **Deterministic variation** — every hit is byte-identical to the last, which no acoustic
   instrument is. Seeded, because R1.2.2 is not negotiable for a bit of realism.
5. **The bass** — a sine and an octave with a pluck, and the least convincing thing after the kick.
6. **Keyboards, plural** — added 13 August, and it is the reason M26 stopped being a "someday"
   item. The organ built for M16.5 sounds like an organ and **not like the right organ**: the
   player asked for several voices across a range of vibes, naming the Wailers' sound and Kash'd
   Out's as two poles, and is assembling references. `OrganSynth` carries one drawbar table; what
   it needs is a named **`Registration`** — a table row per voice, rendered per registration and
   note, chosen by the *arrangement* rather than by a hit, because a band sets the drawbars for a
   song. **Not built without references**, for the reason in the paragraph below and in §7.56.

**M26 now blocks a measurement, not just a name.** §7.33's handicap was that four styles sounded
like "beat #3 rather than oh, a Motown beat" — a naming problem, solved by renaming. §7.56 is the
same handicap stopping M16.5 from choosing between two candidate figures, because neither can be
heard as the thing it is meant to be. That raises this milestone's priority above where §7.13 put
it: it is now upstream of a drill rather than downstream of taste.

**No samples.** The app ships no audio assets, which is why it is small and why a render is
reproducible from source alone; every asset is content somebody else's licence governs, and
hardware ROM and DAW instrument libraries are usually most restrictive about exactly the thing a
release would do. The player's TD-V6 and GarageBand get used as a **reference** instead — record
them, measure spectra and envelopes, tune the synthesis to match. A timbre is not copyrightable
and a measurement problem is one this project is equipped for.

*Falsifier:* if a synthesised kit tuned against real references still cannot be told from "beat
#3" by a professional ear, the genre names come off and the styles get named for what they are.

### M25 — Harmony
Settled with the player on 6 August, as a milestone rather than a parameter. M19's bass is
**rhythmic only** — a root and a fifth locking with the kick — and that will get boring, which is
the point at which most trainers reach for a chord widget and produce something musically
incoherent.

Harmony is a different problem from rhythm, not a smaller one: a key, a progression, voice
leading, what a chord change does to a *timing* drill, and whether the player should be told the
changes or made to hear them. It also touches measurement, because a chord change is a landmark
and the form drill exists to remove landmarks — a progression that resolves every eight bars is
doing the fill's job for it.

**The framework it needs is already laid.** `Hit.note` is per hit and optional, so a chord is
several hits at one step with different notes and nothing about the pattern format has to move.
That was the whole reason for putting the note there rather than on the pattern (§7.29 step 2).

*Falsifier:* if a progression makes the form drill easier in a way that cannot be separated from
the player getting better, harmony belongs in free playing only and never under a measured take.

### M24 — Voice
**The instrument comes out of the equation.** Onsets from the built-in microphone, produced by
chanting, rhyming and spoken rhythm rather than by hands. Numbered after M23 because it was added
last; placed here because its dependency is M21's onset detection, not M23's.

Every timing number this project has ever produced came through one pair of hands on one
keyboard. That is not a small caveat. `WingKristofferson` splits the variance into *clock* and
*motor*, and the motor half is, specifically, **this player's fingers** — so "his clock SD is
11–22 ms" is a claim about a timekeeper that has only ever been observed through a single
effector.

**That is the milestone's first and best experiment, and the app can already run it.** Chant a
pulse and play a pulse, same tempo, same sitting, same drill. If the clock estimate is a property
of the timekeeper it should survive the change of effector; if it moves, some of what has been
called clock was hands all along. Nothing else in the roadmap can ask that question, and it
bears on every figure in §7.7 onwards. The continuation drill is the right vehicle — it is
already the only drill that separates the two — and voice is a `DropoutConfig` with a different
input, not a new analysis.

**It also puts a documented weakness under measurement.** Counting makes this player worse, which
is recorded everywhere in this project as a thing to avoid and has never been *measured*. Voice
makes it a preregistrable M13 design: count aloud against chant a rhyme, same pulse, arms
assigned before the take. The instruction is the independent variable, which is the shape
`relaxed-vs-focused` and `steady-vs-melodic` already have.

**Why the world's rhythm pedagogies are the right source, and not decoration.** Konnakol, tabla
bols, takadimi and the Kodály syllables were all designed to be *articulated crisply* — which is
the same property an onset detector needs. That is a real convergence rather than a nice story:
the traditional vocabularies solved the attack-clarity problem centuries before anyone had to
detect it in software, and choosing syllables from them is choosing the ones with sharp
transients. Accents, dialect and the placement conventions of different traditions then extend
naturally onto M15's feel axis, since where a syllable sits inside a beat is exactly what `Feel`
already models. Poetry and rhyme carry the other axis: metre is phrase structure, felt rather
than counted, which is the form drill without an instrument.

**The hard part is the measurement, and it is harder than guitar.** The hardware is owned outright
— an external microphone he already records with, plus the headphones this drill requires — and
the onsets are the worst-defined in the roadmap:

| | Attack |
|---|---|
| Key strike (today) | A driver-level MIDI timestamp of a discrete event |
| Plucked string (M21) | A sharp transient |
| `ta`, `ka`, `pa` | A plosive burst — detectable |
| `ma`, `na`, `sss`, a sung vowel | A slow rise with **no well-defined onset at all** |

So the measured drills constrain the vocabulary to plosive-onset syllables and say so, rather
than pretending a hummed note has an attack. Free vocalising can be *recorded* without being
scored, the same way `rawTimes` stores what was played on takes M12 could not yet analyse.

**M0 all over again, and that is the entry cost.** The same argument that puts M22 last applies
here with more force: audio onset detection has its own latency, its own jitter, and a systematic
bias that **differs per phoneme**. None of that may be assumed. The validation is unusually clean,
though, and it is the reason this is buildable at all — **the MIDI path is already validated to
the microsecond, so it can be the ground truth for the audio path.** Strike a key and voice a
syllable together; the MIDI timestamp says when, the detector says when it thinks, and the
difference is the constant plus its spread, per phoneme. That is M1's two-path trick pointed at a
new input, and it needs no new hardware.

What exists to build on, and what does not:

- `TrainerKit/DSP` already has `transientEnvelope`, `noiseFloor` and `detectOnsets`, including
  the backtrack that stops an envelope peak reporting every onset late. Written for calibration
  strikes, and the closest thing to a starting point.
- Calibration measures `L_midi + L_out`. Voice replaces the first term with microphone plus
  detection latency, so the two-path procedure needs re-deriving rather than reusing.
- **Headphones are a requirement, and the reason is feedback before it is bleed.** An open
  microphone and a speaker in one room is a howl — the drill would be unusable before it was
  inaccurate, and no amount of gain staging makes a hands-free vocal drill safe on speakers. Bleed
  is the quieter second problem: a backing arriving at the same microphone as the voice puts the
  band's own transients into the onset detector, which is the exact failure mode of detecting
  onsets at all. So this is enforced like the Bluetooth refusal rather than advised like mic
  placement — **refuse to run a vocal take on speakers**, the way `dropout` refuses a swung feel.
  It also forces every vocal take onto the headphone calibration constant, which makes that path
  load-bearing for the first time.
- **The external microphone is the one to use**, and it helps twice. Better capture than the
  built-in, and a mic on a stand can be *placed the same way twice* — which the two-path
  calibration already depends on ("roughly equidistant from the sound source and the keyboard, so
  the acoustic path lengths cancel") and which a laptop lid cannot promise. With headphones there
  is no acoustic output path at all, so the vocal constant is measured the way `calibrate quick`
  already does it: an earcup against the microphone.
- `LESSONS.md` shape 16 is this milestone's own warning: an onset detector that fired on energy
  *tripling* found nothing after the first event of a bar and looked exactly like a broken
  feature. Validate the detector against a case whose answer is known before trusting it about
  one that is not.

**Falsifier.** If per-phoneme onset bias cannot be characterised tightly enough — if the spread
of the detector is comparable to the ~20 ms spread being measured — then voice can carry the
*phrase-level* drills, where the quantity is bars rather than milliseconds, and must not carry
placement. Shipping a placement number the detector cannot support would be §3's forbidden case:
a confident number that is wrong.

---

## 7.14 M9 — the session builder, as built

`session [minutes]`, and **Session** in the app. One choice — 20, 30 or 45 minutes — and the
app proposes a whole evening, says why it picked each drill, and runs it end to end. Until now
everything has been a menu of drills; this is the first thing that decides *what to practise
today*.

### Storage went first

Before any planning code, every take type gained an optional `SessionPlacement`: session id,
block index, role, and **seconds elapsed from the start of the sitting**. Optional throughout,
so every take recorded before M9 still decodes.

This ordering was deliberate. "Was this the cold take or the fifth one of the evening?" cannot
be reconstructed from a bare timestamp, and it is exactly what M10 and M16 ask. A take recorded
without it is a take those milestones can never use — so the field had to exist before another
take was recorded, not after.

### Fixed slots, and why they are fixed

| # | Block | Parameters | Why this slot |
|---|---|---|---|
| 1 | Cold probe (tempo, 3 rounds) | **Locked** | Before any warm-up. Comparable across days only if nothing about it moves. |
| 2 | Warm-up groove | Unmeasured | Hands moving, nothing recorded. |
| 3 | Benchmark jam | **Locked** 100 BPM, 64 bars | The take the trend is fitted to. Same slot every session — warm, not yet tired. |
| 4–6 | Training | Adaptive | The only blocks the planner may vary. |
| last | Closing jam(s) | Length varies | The musical payoff. Tagged `closing`, apart from the benchmark. |

Every confound already in this dataset arrived by a parameter changing between takes — a
changed backing, a changed tempo. The cold probe and the benchmark are the two takes that must
never do that, so they are constants in the planner rather than settings. A test asserts they
are byte-identical across six combinations of history and session length.

### The planner (`TimingCore/SessionPlan.swift`, 20 tests)

Takes a `PlannerInput` of plain summaries rather than the stored session types, which is what
makes "given three unreliable splits, does it schedule the continuation drill?" a test instead
of a fixture directory. Every block carries a one-sentence **reason**, shown before the session
starts: a session the app chose but cannot justify is one the player has no way to disagree with.

Rules, in priority order:

1. **Continuation drill** while the clock/motor split is unsettled — fewer than three reliable
   splits in the last six takes. That split is the question the whole training plan branches on
   (§7.9), and collecting the data that answers it beats training either half on a guess. Once
   settled, a looser clock doubles the silences; a motor-dominant result schedules *nothing* and
   says so, because that needs work no drill here does yet (M11).
2. **Tempo calibration** while the produced period is off by ≥2% at a single target. Accurate at
   one target promotes to rotating targets — a clock calibrated at one tempo is a lookup table.
3. **Form**, always available, at the level earned. If the last take marked a consistent
   sub-multiple, the drill *follows the felt phrase* rather than scoring it down, and changes
   only the phrase length, never the phrase and the level at once.

Longer sessions buy **longer takes, not more of them**. There are three training drills, so
repeats would be filler, whereas ten silences instead of six is a materially better variance
estimate. A single closing jam is capped at ~10 minutes and the remainder split evenly across
more of them: `jamBacking` is two sections with a fill every eight bars, which sustains ten
minutes and is hypnotic well before twenty (§6 — real depth is M17). A 9-minute jam followed by
a 1-minute one is not two takes, it is one take and an apology.

### Running it

`SessionRunner` is a state machine, not a loop, because a rating needs the UI between every
block. Two decisions:

1. **No numbers until the debrief.** Rating after each block and holding every result to the end
   makes §2's blank screen stronger than it is for a single take — for the whole session there
   is nothing measured to see. The tempo drill's round feedback stays; that drill *is* a feedback
   loop and removing it removes the mechanism.
2. **Stopping a block asks what you meant.** Skip this drill, or end the session — "wrong tempo,
   move on" and "I'm done" are different intentions and the runner refuses to guess. Finished
   blocks stay saved; the abandoned one is discarded, as a stopped single take always was.

`session plan [minutes]` prints the choices without committing the evening to them.

---

## 7.15 M10 — cold vs warm, as built

The first tempo data fell −4.7% → −0.3% inside one sitting, and nothing in the app could say
whether that was learning or dust shaking off. Those need opposite responses — one means
practice is working, the other means the first ten minutes of every session are the cost of
entry — and **one slope across all takes cannot tell them apart**, because it confounds *when in
the evening* a take was played with *which evening* it was.

`WarmUpAnalysis` (TimingCore, 13 tests) fits the two separately.

**Within a sitting**, each evening is centred on its own means before pooling, so a sitting that
was simply a good day contributes nothing to the warm-up slope. This is the same move
`DropoutAnalysis` makes for Wing–Kristofferson trials, for the same reason. A test plants six
internally-flat evenings that improve across weeks and asserts the warm-up slope comes out
exactly zero — a naive fit of value against elapsed minutes finds a slope there, which is the
specific error the whole analysis exists to remove.

The interval resamples **whole sittings**, not takes. Takes inside one evening are correlated;
resampling them individually would treat six takes from one night as six independent
observations and report a confident wrong interval.

**Across sittings**, the cold value of each. A controlled cold probe when the session builder
ran; otherwise whatever was played first — a proxy that is flagged, never quietly equated, since
a first take differs in drill and settings as well as in temperature.

**Sittings are recovered from timestamps** for everything recorded before M9: an evening is a run
of takes minutes apart, and the next is hours later. That makes the whole existing history usable
for the within-sitting question instead of starting from nothing.

The verdict refuses to conclude below three sittings, and distinguishes warm-up only / learning /
both / neither. Declining across an evening is named as fatigue rather than folded into "no
warm-up effect".

### What it said when it shipped

`review cold` at M10, on the 13 jams and 2 controlled sittings then on disk. **A snapshot, not
a live figure** — every number here has since moved, and the command is the authority:

| drill | within a sitting | cold, per sitting | verdict |
|---|---|---|---|
| Jams — spread | −0.050/min, flat | +2.20/sitting, flat | neither |
| Form — on-form rate | −0.008/min, flat | −0.091/sitting, flat | neither |
| Continuation — \|tempo bias\| | −0.101/min, flat | 2 sittings — too few | not enough data |
| Tempo drill — error | 1 sitting — too few | 1 sitting — too few | not enough data |

**The drill that motivated the milestone has exactly one sitting**, so the −4.7% → −0.3% run
remains uninterpretable — which is the correct answer and the reason the question was worth
building for rather than arguing about. It becomes answerable after three sessions from the
builder, where the cold probe is controlled rather than inferred.

**One row has since changed verdict and is not yet written up as a finding.** Form's cold start
now reads −0.109/sitting over 6 sittings with an interval of [−0.218, −0.023] — *worsening*,
where M10 read flat. It is not a controlled probe: form is never the cold block, so every cold
value in that row is the first-take proxy `WarmUpAnalysis` flags, and the drill's level and
phrase length both moved across those sittings (§7.19). It needs a §9.6 decision — either the
confounds disqualify it, or it is the first cold-start signal in the dataset — and until it gets
one, nothing should cite it.

---

## 7.16 M11 — the recall drill, as built

`memory [bpm] [waitBars] [rounds]`, and **Recall** in the app. The groove plays and you play
along; it stops and you **stop too**; a single kick marks the end of the wait and you produce
the tempo alone. Half the waits are silent, half are filled with scattered percussion.

### Why this and not just longer silences

The continuation drill asks whether a pulse survives while you keep producing it. This asks
something different: whether the period is **stored**, or only exists while it is running. You
let go of it entirely and pick it up from nothing.

The two conditions are the experiment, and the prediction is specific. A period maintained by
active attention should survive an empty gap and collapse against a distractor, because the
distractor competes for exactly the resource doing the holding. A stored period should not care
what was in the gap. For this player that is not abstract — "if my brain is out of the picture
the flow is easy" (§1) predicts a real interference cost, and this is the first thing in the app
that can put a number on it.

### The trap that shaped the implementation

The obvious way to build a distractor is a `Pattern`, like every other sound in the app. That
would have been silently, completely wrong: patterns live on the 16-step grid, so every onset
would land on a sixteenth of the exact tempo being remembered. The "distractor" would have
**rehearsed the period** instead of interfering with it, and the filled condition would have
measured nothing — while producing perfectly plausible numbers.

So `Distractor` bypasses `Pattern` and emits `ScheduledHit` at arbitrary sample positions, with
two properties enforced by tests:

1. **No onset within 10% of a beat.** An onset on the beat is a metronome tick.
2. **Beat-phase is spread, not concentrated.** Intervals are drawn from a range wider than one
   beat, so phase random-walks instead of locking.

Property 2 needed a second pass. The first version measured circular concentration at the
fundamental only — and onsets on every *sixteenth* sit at phases 0, ¼, ½, ¾, which are spread
perfectly evenly and score ≈0 there. A metronome would have passed. The measure now takes the
worst case across the beat and its first four harmonics, and there is a test asserting that
grid-aligned trains at 1, 2 and 4 per beat all score above 0.95, so a low score is evidence
rather than an artefact.

Also excluded: kick and crash. Both read as downbeats however they are placed, and a heard
downbeat is a bar line to rebuild the tempo from.

### Measurement decisions

- **Per-round scoring is the tempo drill's**, reused rather than reimplemented. The five-note
  floor, the isochrony gate and the subdivision normalisation each fixed a real wrong number
  (§7.8); a parallel copy here would be a second place for them to be wrong.
- **Playing through the wait invalidates the round.** Keeping the pulse running means nothing
  about *storing* it was tested — that is the continuation drill. Up to two stray notes are
  tolerated as a slip; more and the round says why it was discarded.
- **Exactly one sound in the reproduction window.** One onset carries no period; two would hand
  the tempo straight back.
- The interference cost gets a plain (non-block) bootstrap: rounds are separate trials minutes
  apart, not a serially-correlated stream, so there is no short-range structure for blocks to
  preserve. Below three scored rounds per condition it reports the point estimate and refuses
  the interval.
- Difficulty follows the **measured clock SD**, not this drill's own accuracy, which would be
  circular. A tight clock earns a longer wait; a loose one gets a shorter one so rounds stay
  scorable.

### Planner

This fills the hole M11 was created for: the clock-dominant branch used to schedule nothing and
leave a note saying no drill existed. It now schedules Recall — but only once the split says the
clock is the weak half, because before that it would be training a weakness that has not been
shown to exist.

Adding it immediately exposed a regression worth recording: with three training slots and a
priority list, Recall pushed **Form out of every session**. Form is the only drill on the other
axis — where you are in the music, tens of seconds, not milliseconds (§6.1) — so ranking it
against the clock drills on their evidence loses it the moment any clock drill has a reason. Form
now takes the last training slot outright and the timing drills compete for the rest, with a test
that fails if it is ever crowded out again.

---

## 7.17 First live session — findings and fixes

The first end-to-end run of the session builder, 4 August: 30.5 minutes against a 30-minute
target, all 8 blocks completed, nothing skipped.

### What the session measured

| # | block | result | feel |
|---|---|---|---|
| 1 | Tempo (cold) | **−7.9%** — runs slow | 3 |
| 2 | Play (warm-up) | — | — |
| 3 | Jam (benchmark) | SD 24.1 ms, mean −5.9 ms | 4 |
| 4 | Alone | 95 BPM alone, clock the looser half | 2 |
| 5 | Recall | silent 5.1% / filled 6.4%, cost +1.3 | 3 |
| 6 | Form (level 2, 4-bar) | 4-bar phrases, mostly on form | 2 |
| 7 | Jam (closing) | SD 24.4 ms, mean −5.4 ms | 1 |
| 8 | Jam (closing) | SD 28.2 ms, mean −2.6 ms | 2 |

**The cold probe is the headline: −7.9%, against −0.3% at the end of the previous sitting.**
That is the first controlled cold measurement in the dataset and it is a long way from where
the last evening finished. One point proves nothing, but it is exactly the gap M10 exists to
measure, and it will be interpretable after two more sessions.

**Feel came apart from the measurement.** Blocks 3 and 7 are the same take by every number —
SD 24.1 against 24.4, mean −5.9 against −5.4 — and were rated 4 and 1. Only block 8 is
genuinely looser. Whatever collapsed over those twenty minutes was not precision, and
`review feel` (r ≈ −0.54 over the earlier takes) will need re-checking now that fatigue is in
the data.

**Off-grid rate climbed through the session**: 2.7% → 4.2% → 10.8%, and velocity spread jumped
on the last jam (22.1 against ~16 everywhere else). Read carefully, that is playing that got
freer and louder as well as looser — which is the M12 question arriving unbidden in the data.

### Two defects the run exposed

1. **The form drill described landmarks that were not there.** The session ran form at level 2
   — no fills — while the instructions said "a drum fill warns you that a phrase is about to
   end". The player was told to wait for a cue that never came. `DrillInstructions.form` is
   now a function of the level, so the text describes the backing that is actually playing.
   This is the *second* time static instructions have produced a bad take (§6.1); a drill whose
   whole design is removing cues cannot have fixed text describing them.
2. **`review cold` contradicted itself.** The continuation row read `+1.487/sitting worsening`
   with an interval excluding zero, directly above a headline saying "neither effect is
   separable from noise". `WarmUpAnalysis` only recognised improvement as a result; a cold
   start reliably getting *worse* fell through to "neither". It now has its own verdict.

### Pitch is now recorded

The player's own reading of the evening: steady quarter notes with no pitch change are nearly
sleep-inducing, while playing an actual melody feels far more in the pocket. The data agrees
that *something* changed — off-grid rate 2.7% → 10.8%, velocity spread 16 → 22 — but it cannot
say what, because **every jam take stored when a note happened and threw the pitch away.**

`Tap` now carries an optional note number, and `JamSession` stores `rawTimes` / `rawNotes` /
`rawVelocities`: every note-on in the window, before chord clustering. The clustered series
that all existing analysis runs on is untouched, so no number moved; the raw arrays are
optional, so every earlier take still decodes.

Nothing reads them yet — that is M12. They are stored now for the same reason
`SessionPlacement` was stored before M10 existed: a take recorded without pitch can never
answer the question afterwards, and the question was asked the day the drill first ran.

### The cue, and an asymmetry in the recall drill

The single kick marking the end of the wait was "enough if you are really looking out for it".
It is now a **crash and kick together at full velocity** — still one instant, which is the
property that matters (one onset carries no period; two would hand the tempo back), but
impossible to miss.

More significant, and only visible with real data: **the silent rounds are violated far more
often than the filled ones.** Across the two recall takes, 3 of 8 silent waits had the player
still playing through them, against 1 of 8 filled. The distractor interrupts; silence invites
you to carry on. That biases the control condition — the silent rounds that survive are the
ones where stopping happened to be easy — and it is why one take scored only 5 of 8 rounds.
Worth fixing before the interference cost is trusted: either a clearer "stop now" cue at the
top of the wait, or scoring the violation rate as a result in its own right, since *being
unable to stop* is itself evidence about how the period is held.

---

## 7.18 M12 — what you play, as built

`review content`. A take is cut into 8-bar windows; each window gets a set of content measures
and the timing spread of the notes in it; the two are correlated **within the take**.

Within-take is the design, not a convenience. It holds the day, the tempo, the backing and the
fatigue fixed, so a relationship cannot be explained by any of them — which is exactly what a
between-take comparison could not have ruled out.

### The measures

Note density, pitch-class entropy, mean melodic step, contour reversal rate, chord size, and
velocity spread. Two decisions worth keeping:

- **A chord is one rhythmic event, not three melodic steps.** Counting every note of a block
  chord as a melodic move would report comping as wild melodic activity. Melody is read from
  the *top line* — the highest note of each cluster.
- **Contour separates a scale from a shaped line.** A run and a zigzag have identical mean
  interval; only the reversal rate tells them apart, and without it "melodic" would just mean
  "fast".

There is also a crude 0–1 `interest` summary for ranking windows. It is deliberately named
after a feeling rather than a quantity: findings must be stated against a named component,
never against it.

### The three traps, all reported rather than assumed away

1. **Censoring.** Spread is computed only on events that matched the grid, so a window that
   pushed more notes off the grid reports the spread of a self-selected subset. The report
   correlates off-grid rate against content and says so when the two track each other — without
   which "busy playing is tighter" could be pure survivorship.
2. **Subdivision.** Spread scales with the note values being played, so note density is
   reported as its own row and flagged when it correlates with spread.
3. **Arousal.** Playing something interesting is both more melodic *and* more engaging. This
   design cannot separate them, and the report says so on every run. A real effect here means
   content matters; it does not say why.

### Status

The analysis and its eleven tests are in; the data is not. Pitch has only been recorded since
4 August 2026, so `review content` currently reports that no take can be analysed — which is
the correct answer and the reason §7.17 stored the field before this milestone existed. One
jam fills it in. Turning a within-take correlation into a *result* needs M13's experiment
runner: the same take length played as steady quarters, as a written melody, and free.

---

## 7.19 Second planned session — the first movement in the data

5 August 2026, 30-minute session, 29.7 minutes actual, all seven blocks completed.

### The benchmark moved, and both changes are real

Same locked settings, same output device, same calibration constant (2.58 ms), one day apart:

| | 4 Aug | 5 Aug | change (bootstrapped) |
|---|---|---|---|
| Spread | 24.07 ms | **17.37 ms** | −6.70 [−9.41, −3.82] **real** |
| Bias | −5.85 ms | −22.59 ms | −16.74 [−22.47, −11.01] **real** |
| r₁ | +0.43 | +0.46 | within noise |

17.4 ms is the tightest benchmark recorded. By this project's own doctrine — variance is the
skill, bias is not failure (§2) — that is a good session, with a large simultaneous shift in
placement. This is the first time the locked benchmark slot has paid for itself: two takes a
day apart, nothing varying but the player.

It is still n = 2, and the trend across all 13 jams at 100 BPM remains flat on every metric.

### The recall result reversed, and the first one was probably an artefact

| date | wait | usable | silent | filled | cost |
|---|---|---|---|---|---|
| 4 Aug | 4 bars | 7/8 | 9.9% | 13.2% | **+3.26** |
| 4 Aug | 4 bars | 5/8 | 5.1% | 6.4% | **+1.30** |
| 5 Aug | 2 bars | 6/8 | 5.9% | 4.4% | **−1.49** |
| 5 Aug | 4 bars | 8/8 | 5.1% | 4.1% | **−0.98** |

§7.17 recorded that silent rounds were violated far more often than filled ones — 3 of 8
against 1 of 8 — because an empty gap invites you to carry on playing while a distractor
interrupts. The surviving silent rounds were therefore a biased subset. On 5 August the player
reached 8/8 usable, that bias disappeared, **and the sign flipped**.

The defensible reading: the original "interference hurts" was the violation bias, and the
cleaner measurement says the distractor **helps**. The mechanism is the project's own thesis —
an empty gap invites counting, and the distractor prevents it. Two takes per direction, no
interval; M13 is what turns this into a result.

### M12's first data contradicts the hypothesis, and the bias runs against it

Both takes with pitch: busier playing went with **looser** timing (r = +0.40 over 8 windows,
+0.57 over 27). Pitch variety was the most consistent component (+0.67, +0.43).

The censoring warning now states its direction, because it decides how to read this. Off-grid
notes are the worst-placed ones, so excluding them shrinks the spread of whichever windows lose
most — the busier ones. The bias therefore favours "busier is tighter", and the measurement
came out the other way: **the effect is at least as large as it looks.**

The qualification that matters: this is a *within-take* relationship, windows where the player
happened to play busier. The stated hunch is about the *mode* of playing — a melodic take
against a quarter-note take — which M12 cannot test. That needs M13.

### Three fixes this session forced

1. **The planner was oscillating the form phrase length.** It read `markedEveryBars` from a
   single take: an 8-bar setting where the player felt 4 moved the drill to 4, and the next
   take at 4 — where they felt 8 — would have moved it straight back. The two takes at 4 bars
   also disagreed wildly with each other (16/17 on form, then 5/14), so one take was never
   evidence of a stable felt period. The rule now needs the two most recent takes to agree, and
   says so when it holds.
2. **The recall drill had no warning before the silence.** The groove simply stopped and the
   player was caught out every round. The last reference bar now carries a snare fill, which
   adds to the groove rather than replacing it (§6.1's invariant) and gives away no tempo,
   since it lands while the groove is still playing. With the fill in a fixed place and the
   retention length constant for a session, the round's shape becomes learnable — the player
   can start anticipating re-entry instead of waiting to be told.
3. **The censoring warning did not state its direction**, which is the difference between a
   caveat and a finding.

### Smaller notes

- **Cold probe #2: −4%**, against −7.9%. Three controlled sittings are needed before
  `review cold` will fit anything.
- **Continuation at 16-bar silences: clock 22.1 / motor 6.8 ms, 99 BPM alone (−1%)** — better
  on a *harder* task than the 8-bar take (40.7 / 20.9, −5%). The "runs ~5% slow unaccompanied"
  finding is weakening; 99 BPM is the closest to target yet.
- **`|bias|` no longer trends "worsening"**, consistent with that slope having been driven by
  the stale first point fixed in §7.17.

---

## 7.20 Second codebase review — eleven findings, and the order they get fixed

A full pass over the tree before M13 starts, on the principle that an experiment runner
inherits every weakness of the statistics underneath it. Ten findings from reading; an
eleventh, and the most serious, arrived from a live session while the fixes were in progress.

The gate was green at the time of the review and stayed green throughout: 175 tests then, 36
selftest checks, a warning-free release build, every stored take decoding, the 46 takes then on
disk matching the counts quoted in `AGENT.md`. Finding 11 is the reminder that a green gate
bounds what has been checked, not what is true — no test in the suite ever wrote a take.

So none of this is a crash or a broken build. All ten are the other failure mode, the one
§3 of `STANDARDS.md` exists for: **a number, a rule or a document saying more than it can
support.** Ordered by what they block rather than by size.

### 1. The pooled bootstrap cannot see between-take variance — blocks M13

`Bootstrap.pooledInterval` and `pooledDifference` resample blocks *within* each take and
concatenate the results. The takes themselves are never resampled, so the interval describes
variation inside takes and nothing else — while the quantity being compared varies mostly
*between* them. Everything this project has measured says so: two benchmark jams one day apart
moved 24.1 → 17.4 ms (§7.19), and two jams twenty minutes apart in one evening were rated 4
and 1 (§7.17).

`review conditions` is therefore able to call a difference "real change" on variance it
structurally cannot observe, and that is the readout M13 is built on top of. R3.2 is explicit
that using the wrong bootstrap is a defect and not a preference.

The fix is a **two-stage cluster bootstrap**: draw takes with replacement, then moving-block
resample within each drawn take. The codebase already knows this pattern —
`WarmUpAnalysis.withinSessionFit` resamples whole sittings, for exactly this reason, and says
so in its own doc comment. The pooled path simply never got the same treatment.

A group of one take gets no interval at all after the fix, rather than a narrow one. One take
cannot support a statement about takes, and a plausible number here is worse than a gap.

**Related, and deliberately left alone.** The pooled *estimand* is a statistic over
concatenated events, so a longer take carries more weight, and a pooled SD across takes with
different biases includes the between-take bias spread on top of the within-take spread. That
is a question about what "spread across a condition" should mean, not about uncertainty, and
changing both at once would leave neither reviewable. It gets its own decision under M13 step 3.

`review compare` is not affected either way. It puts an interval on the difference between two
*named* takes, and the within-take resample is the right tool for that: "did these two takes
differ" is a different question from "does this condition differ", so §7.19's benchmark
comparison stands as recorded.

#### Fixed — step 0

`resamplePool` now draws takes with replacement before block-resampling inside each drawn
take. Five tests cover it; two fail if the outer draw is reverted, which was checked by
reverting it.

That reverted run is the clearest statement of what was wrong. Given four takes that agree
with each other, and four sitting at −20, −6, +6 and +20 ms — identical within-take spread,
only the agreement differing — the old bootstrap returned a *narrower* interval for the
disagreeing set (margin 0.50 ms) than for the agreeing one (0.56 ms). It was not merely too
narrow. It could not see the difference at all.

On the real 46 takes:

| | before | after |
|---|---|---|
| `benchmark` pooled mean | −14.2 [−17.1, −11.1] | −14.2 [−24.2, −3.9] |
| benchmark vs closing, mean asynchrony | +4.26 [+1.19, +7.36] **real change** | +4.26 [−8.66, +19.45] **within noise** |
| benchmark vs closing, r₁ | −0.25 [−0.32, −0.09] **real change** | −0.25 [−0.34, −0.04] **real change** |

The first row is the whole finding in one line. The benchmark's two takes sit 16.7 ms apart on
mean asynchrony, and the old interval over exactly those two takes was 6.0 ms wide. It is now
20.3 ms wide — wider than the gap it spans, as it has to be.

**The mean-asynchrony row was a false positive** and now reads "within noise". That is the
correct answer for two takes against three, and it is the answer M13 needs the machinery to
give before it starts drawing conclusions on its own.

**r₁ survived**, which is the check that this did not simply widen everything into mush. r₁ is
a within-take property and it was consistent from take to take, so the outer stage had little
to add — exactly what a cluster bootstrap should do with a metric that genuinely replicates.

### 2. The recall drill's differential attrition is still invisible — blocks M13

§7.17 measured it: 3 of 8 silent waits were played through, against 1 of 8 filled, because an
empty gap invites you to carry on while a distractor interrupts. §7.19 concluded that the
original "interference hurts" reading *was* that bias, and that the sign flipped once the
player reached 8/8 usable. This is the only finding in the project so far that has been
retracted, and the mechanism was differential attrition.

The cue half of the fix landed in §7.19 — the snare fill before the silence. The measurement
half did not. `TempoMemoryAnalysis` still counts violated rounds into a single total, so the
report can say "3 rounds had playing during the wait" without saying that all three were
silent, and no note tells the reader that the surviving control rounds are a self-selected
subset. R3.3 requires the opposite: when a measurement cannot be trusted, say so and say why.

The fix reports the violation rate **per condition**, and treats an imbalance as a caveat on
the interference cost. §7.17 also suggested scoring the violation rate as a result in its own
right — *being unable to stop* is evidence about how the period is held — and that stands, but
it is a second question and follows the caveat rather than replacing it.

#### Fixed — step 1

`RetentionAttrition` per condition — rounds, scored, played through, otherwise unusable — and
`attritionIsImbalanced` when the two played-through *rates* differ by 0.2 or more. Seven tests.
Both surfaces show the per-condition split; neither states a cost when the conditions are not
comparable.

**The threshold had to be a rate, and the stored takes are what said so.** The first attempt
used a count: two rounds apart, on the reasoning that §7.17 measured 3 silent against 1 filled.
Checking it against the four recorded takes showed that figure is *the evening's two takes
pooled*, and that within a take the gap is one round:

| take | wait | silent played through | filled | flagged? |
|---|---|---|---|---|
| 4 Aug #1 | 4 bars | 1 of 4 | 0 of 4 | yes |
| 4 Aug #2 | 4 bars | 2 of 4 | 1 of 4 | yes |
| 5 Aug #1 | 2 bars | 2 of 4 | 0 of 4 | yes |
| 5 Aug #2 | 4 bars | 0 of 4 | 0 of 4 | **no** |

A count threshold of two would have passed both of the takes whose cost §7.19 retracted while
flagging a later one — precisely inverted. At four rounds per condition a single lost round is
25 points of attrition, and that has to trip it. The take that survives is 5 Aug #2, the 8/8
take, which is exactly the one §7.19 identified as the trustworthy reading.

**Withheld at source, not flagged for callers.** `interferenceCost` and its interval are `nil`
when the conditions are not comparable. This started as a flag with each caller checking it,
and building it that way surfaced the actual risk: the cost is derived in *three* independent
places — the report, the history chart, and the planner's input — and the third was found only
by noticing that `review cold` had not moved. A value that is safe only when every caller
remembers a precondition is the cached-summary defect of §7.12 in a new costume. The
per-condition means are still reported, because each describes its own condition honestly; it
is only their difference that is not a measurement.

**What it does to the data.** Three of the four recall takes are imbalanced, so the recall
trend goes from four takes to one and `review cold` now reads "not enough data" where it
previously fitted a within-sitting slope of −0.136/min. That slope was being fitted through
the attrition. Losing it is the point: §7.19 already said the recall result needed M13 to
become a result, and this says the same thing in the readout instead of in a footnote.

### 3. The last content window's density is understated

`MusicalContentAnalysis.analyze` rounds the window count up, so the final window runs past the
end of the take, but `measures(of:overBeats:)` always divides by the *full* window length.
`eventsPerBeat` in that window is scaled by however much of it was real playing.

Note density is not an incidental measure here: it is trap 2 of the three §7.18 names, the
confound the whole report is written around, and it is reported as its own row precisely so a
content effect can be separated from a note-values effect. Biasing it in one window of every
take puts a thumb on that scale.

#### Fixed — step 2

`analyze` now takes `totalBars` and emits `totalBars / windowBars` whole windows; a tail shorter
than a window is not a window. Three tests.

Normalising the partial window by its measured span was the first idea and it is wrong, because
the span would have to come from the last note — and a player who stopped a bar early would then
lose a window that really was complete. That is §7.12's first defect exactly, one layer up:
**take length comes from the configuration, never from the last thing that sounded.** The
parameter is the fix; the arithmetic is a consequence of it.

No published number moves. Both takes in §7.19 are 64 and 216 bars, exact multiples of the 8-bar
window, so they had no ragged tail and their +0.40 and +0.57 stand as recorded. The fix bites on
takes whose length is not a multiple of the window — the 56-bar closing jam is the first.

### 4. `review trend` renumbers the take axis when a take is unscorable

`TrendAnalysis.fit` filters non-finite values and then builds its x-axis as `0..<clean.count`.
A take whose metric could not be computed does not leave a gap in the axis — it compresses it,
and every later take slides one place earlier. The slope is then per *usable* take while every
label, every unit string and the doc comment say per take.

Small in this dataset and not small in principle: it is the same class as the stale-cache
defect §7.12 found, where a plotted number was not the number the analysis produced.

#### Fixed — step 2

The fit now carries each value's original index, and `TrendAnalysis.row` hands the fit the
*original* series rather than the filtered one — without that second half the fix would have
been dead on arrival, since `row` is the entry point every caller uses. Two tests; over
`[10, nan, 8, 7, 6]` the renumbered axis gives −1.30 against a true −1.00, and both tests fail
if either half is reverted.

**It changes nothing on today's data, and the reason is worth recording rather than glossing.**
The only series carrying gaps is the continuation drill's clock SD, whose unusable takes sit at
positions 1, 2 and 10 — all leading or trailing. A uniform translation of the x-axis leaves a
slope unchanged, so only a gap in the *middle* of a series moves the number. The defect was
real and latent, and it will produce a wrong slope the first time a take in the middle of a run
is unscorable. Recorded here because "the fix changed no output" is the kind of result that
looks like evidence the fix was unnecessary, and it is not.

### 5–8. Enforcement gaps and small stuff

| # | Finding | Why it matters |
|---|---|---|
| 5 ✅ | `check.sh`'s force-unwrap rule only matched `!` followed by `.`, so bare force-unwraps passed. **Eleven** lived in `Sources/`, not the six the first pass found — excluding lines containing a quote hid the rest. | Every one was guarded by a preceding filter, so none could trap. The defect is that the gate reported a rule as held when it was not — R4.7 was unenforced, and the next one might not be guarded. |
| 6 ✅ | The decode gate could not fail. `check.sh` runs `review list` and tests the exit status, but `SessionStore.load` wrote its "could not be read" note to stderr and returned whatever decoded; the CLI exited 0. **And `review list` loads only jams**, so a schema change to any of the other five types could never have been caught by it. | R6.1 says every take ever recorded must continue to decode, "verified by running `review list`". A change that orphaned the entire history would still have printed `PASS`. |
| 7 ✅ | The M7 trend doc comment sat above `runContent`; `runTrend` had none. | Left behind when M12's command was inserted. §0 of `STANDARDS.md` treats misplaced content as a defect; a comment describing the function above it is worse than none. |
| 8 ✅ | `MemorySession.roundWindows` indexed five parallel arrays by `roundConditions.indices`; `TempoSession` had the quieter form of the same thing, where `zip` truncates to the shortest and says nothing. | A length mismatch traps instead of reporting, which is the failure mode R6.4 exists to prevent — a storage inconsistency should be legible, not a crash while reading history. |

#### Fixed — step 3

Both rules now fail when they should, which was checked by planting a violation for each rather
than by reading the regex.

**Finding 5.** The rule matches a postfix `!` after any identifier, `)` or `]`, which also
catches `Type!` declarations. All eleven violations are gone: four in the pure modules and
`Commands`, rewritten to `guard let`, paired `compactMap`, or iterating a dictionary's pairs
instead of re-subscripting its own keys; and three implicitly-unwrapped `AVAudio*Node`
declarations, built into a local and then retained, which needed no restructuring at all.

Two things surfaced while doing it, and both are the point of the finding rather than asides:

- **The first pass undercounted.** It reported six violations; there are eleven. The search that
  found six excluded lines containing a quote, to duck string-literal false positives, and that
  filter hid five real ones. A rule relaxed to avoid noise stops being a rule.
- **The replacement was itself broken, in exactly the way it was fixing.** `[A-Za-z0-9_)\]]!`
  looks like it includes `]` in the set. Inside a bracket expression a backslash is literal, so
  the set closes at the first `]` and the pattern means something else — it matched nothing and
  reported PASS. Two rounds of testing at the shell missed it because the shell and the script
  disagreed; only planting a violation and running `check.sh` itself exposed it. `]!` is now its
  own alternative. **Verifying a gate means making it fail on purpose, not reading it.**

That last point generalised: every other rule in `check.sh` was then given a planted violation —
a pure module importing `AVFoundation`, `GrooveCore` importing `TimingCore`, a `print`, a
`Date()`, a cached-summary read, a `URLSession` — and all six failed as they should. The rest of
the gate is sound; this one rule was not.

**Finding 6.** `SessionStore.unreadableFiles()` checks all six stored types, and `review list`
throws when any file fails to decode, so the exit status `check.sh` reads finally means
something. Verified by planting a corrupt `form-` file: the command exits 1 and names the file
and the rules. A `form-` probe was used deliberately, because the old check loaded only jams and
would not have noticed.

#### Fixed — step 4

Finding 7 is a comment moved to the function it describes.

Finding 8 became a small piece of structure rather than a bounds check. `Codable` proves the
fields decoded; it cannot prove that five arrays describing the same rounds are the same length.
A new `StoredTake` protocol carries `isStructurallyValid`, defaulting to true, and the loader
treats an invalid file as unreadable — so it surfaces through finding 6's `unreadableFiles()`
and `review list` **with a name attached**, rather than as a stack trace while reading history.
`roundWindows` also returns nothing rather than trapping, so both paths are covered.

Two things worth keeping from doing it:

- **`TempoSession` had the same defect in a quieter form.** It builds its rounds with `zip`,
  which does not trap on a mismatch — it truncates to the shortest array and says nothing, so a
  malformed file would report a take with fewer rounds than were played and look entirely
  plausible. That is worse than the crash, and it was only found by asking which other type
  carried parallel arrays. It is validated too.
- **The fix rides on the previous one.** Finding 6 gave the project a way to say "this file is
  not readable, here is its name"; finding 8 is just another reason for a file to be in that
  list. Three `selftest` checks cover it, including the property that used to trap.

### 9. Neither the content nor the condition readout exists in the app — partly fixed

The app's History carries trends and the warm-up card. `review content`, `review tags`,
`review conditions` and `review feel` are console-only.

That was tolerable while the console was where analysis happened. M13 makes it a real problem:
the experiment readout — which arm is ahead, how many takes remain, whether the app will
conclude anything — *is* the milestone's output, and the app is where sessions actually get
run. A milestone whose result the player never sees where they practise has not shipped.

This is not the `R1.1.2` violation it might look like; no measurement moves. It is a surface gap.

**Closed for the experiment readout** in M13 step 5: `review experiment` exists on the console
and as a card in the app's History, mirroring each other. `review content`, `tags`, `conditions`
and `feel` are still console-only, and remain so deliberately — M13 needed one of them on the
surface where sessions are run, and porting the rest is presentation work with no question
waiting on it.

### 10. `AGENT.md` pointed at the wrong live session — fixed in this pass

It called 4 August (§7.17) "the last live session". The last one is 5 August (§7.19), which
retracted a finding and forced three fixes. An operating manual that sends a reader to the
second-most-recent findings is exactly the failure the closing documentation step in §8.3 of
`STANDARDS.md` exists to catch — and it was introduced *by* a pass that updated the milestone
table and not the sentence under it.

Corrected here rather than queued: a wrong pointer in the operating manual misleads every
reader who arrives before the queue drains, and the fix is one sentence.

### 11. A take is destroyed when its summary is not computable — found live, fixed at once

The third session (5 August, 21.6 minutes, 20-minute target) failed to save its form take:

> Could not save that take: The data couldn't be written because it isn't in the correct format.

That is `NSCocoaErrorDomain 4866`, `JSONEncoder` refusing a non-finite `Double`, confirmed by
reproducing it. `FormAnalysis` writes `.nan` for `phaseErrorMeanMs` when no mark landed and for
`phaseErrorSDms` when fewer than two did — the honest output of `Stats.mean` and `Stats.sd` on
an empty series — and the encoder throws on it. The drill ran, the analysis completed, the save
threw, and `SessionRunner` recorded the block as skipped. **The take is gone.**

The exposure was three of the five drills, not one:

| Take | Non-finite when |
|---|---|
| Form | no mark placed, or only one |
| Continuation | too few usable trials for a paced SD, an interval SD or a re-entry |
| Jam | nothing matched the grid |

**The inversion is what makes this the worst defect found in the review.** A take is destroyed
exactly when it went *badly* — that is when marks, usable trials or matched notes are too few
to compute a summary. The takes being thrown away were the most diagnostic ones in the set, and
the drill it hit is the one whose whole design is removing the landmarks until the player is
guessing. §7.19 had just moved the form drill from 4-bar to 8-bar phrases at level 2.

It also breaks R6.2 in the one way the rule does not literally say: nothing deletes a stored
take, but a take that never reaches storage is lost just as completely, and the session manifest
records it as "skipped" so nothing downstream can tell that a measurement was destroyed rather
than declined.

**Fixed.** Every stored summary now passes through `Stats.finite`, which is `nil` for NaN and
infinity, and the seven affected fields are `Optional`. Nothing reads cached summaries back
(R3.1), so writing `null` costs nothing — the raw taps and marks are stored either way, and the
report recomputes from those. Old takes hold a number and still decode.

Guarded by three new `selftest` checks that encode a degenerate form, continuation and jam take.
They live in `selftest` rather than `swift test` because the session types are `TrainerKit`,
which has no unit tests; `check.sh` runs `selftest`, so the gate still covers it.

**Not fixed, and queued:** `.nan` is being used as a sentinel for "not computable" throughout
the analysis, and `Optional` is what the rest of the codebase uses for exactly that. Converting
`FormReport`, `DropoutReport` and `TimingReport` to optionals is the root fix and touches every
display site, so it is its own change. This one stops the data loss.

### Fix order

Findings 1 and 2 are M13 prerequisites: the first because every conclusion the experiment
runner draws goes through it, the second because the recall comparison is one of the first
three experiments and would re-inherit the bias. Everything else is sequenced after them
because none of it is load-bearing for the milestone.

| Step | Fixes | Where |
|---|---|---|
| 0 ✅ | 1 — cluster bootstrap; `review tags` / `review conditions` moved onto it | `TimingCore/Bootstrap.swift` |
| 1 ✅ | 2 — per-condition attrition, reported and caveated | `TimingCore/TempoMemory.swift` |
| 2 ✅ | 3, 4 — partial content window; trend take axis | `TimingCore` |
| 3 ✅ | 5, 6 — close both enforcement holes, then fix what they surface | `scripts/check.sh` |
| 4 ✅ | 7, 8 — comment placement, parallel-array decode | mixed |
| — ✅ | 11 — non-finite summaries destroying takes. Jumped the queue: found in a live session, and every further session was losing data until it landed. | `TimingCore/Statistics.swift`, `TrainerKit` |
| later | 11's root cause — `.nan` as a sentinel replaced by `Optional` across the three reports | `TimingCore` |
| T1 | The gap finding 11 exposed: nothing has ever tested writing a take. See §7.22. | new test target |
| 5 | 9 — folded into M13 step 5, since it is the same view | `MusicalTrainerApp` |

### What this sequences into — the M13 build order

Three things about this codebase shape the milestone.

**Storage goes first, again.** `ExperimentAssignment` — experiment id, name, arm, run index —
optional on all five take types, written by `SessionRunner`, read by nothing. Same reasoning as
`SessionPlacement` before M10 and pitch before M12, and the same rule: R6.3. A take recorded
without its arm is lost to the comparison for good.

**Preregistration is the mechanism, not a flourish.** The app re-runs its analysis after every
session, which is optional stopping, and optional stopping plus a bootstrap eventually
manufactures a "real change". So an experiment declares its metric, direction, arms, target n
and stopping rule up front; below target n the readout is "collecting, k takes to go" and no
verdict is computed at all. That is the literal reading of "refuses to draw a conclusion before
it has power" (§7.13), and it doubles as protection for the player: a running tally on screen
would bias the takes still to come, in a project whose first principle is that watching the
number changes the playing.

**Counterbalancing against block position is mandatory.** §7.17 has two takes identical on
every number rated 4 and 1, twenty minutes apart. An arm that correlates with elapsed minutes
measures fatigue. Arm order alternates across sessions under a seeded RNG (R1.2.1), and the
analysis reports arm-against-elapsed as a confound check rather than assuming the balancing
worked.

One consequence worth naming: steady-vs-melodic is an **instruction-only** condition. Same
backing, same tempo, same everything — the independent variable is the text the player is
shown. That makes `DrillInstructions` the experimental apparatus, in a project where static
instructions have already cost two takes and one live session (§6.1, §7.17). Arm text is
generated from the arm that will run, with a test, or the experiment is not measuring what it
claims.

| Step | Delivers |
|---|---|
| 0 ✅ | Cluster bootstrap (finding 1) |
| 1 ✅ | `ExperimentAssignment` storage, written and unread |
| 2 ✅ | `Experiment.swift` — design, arms, seeded balanced assignment, stopping rule |
| 3 ✅ | `ExperimentAnalysis.swift` — arm comparison, minimum detectable effect, takes-needed, confound and attrition checks. Settles the pooled-estimand question from finding 1. |
| 4 ✅ | Planner blocks at locked parameters (R3.5), arm-specific instructions (R3.6), engine wiring |
| 5 ✅ | `review experiment` on both surfaces (finding 9) |
| 6 ✅ | `PLAN.md` as-built, `README.md` command table, `AGENT.md` state |

### Step 1, as built

`ExperimentAssignment` — experiment id, name, arm, run index — optional on all five take types,
and optional on `SessionBlock` so the arm travels with the thing that decides it. `SessionRunner`
stamps it from the block, beside the placement it already writes. Nothing reads it.

Four decisions worth keeping:

- **The arm is a raw string**, like `SessionPlacement.role`, so adding an arm to an experiment
  never makes an already-recorded take undecodable.
- **The design is not stored on the take.** Arms, target n and the stopping rule belong to the
  experiment; copying them into every file would let two takes disagree about what experiment
  they were part of.
- **`runIndex` is stored** because counterbalancing has to be checkable after the fact rather
  than merely intended. §7.17 has two takes identical on every number rated 4 and 1 twenty
  minutes apart, so an arm that drifted toward the tired end of a sitting would measure fatigue —
  and the placement's `elapsedSeconds`, already stored, is the other half of that check.
- **It sits on `SessionBlock`, not on the runner's call.** A plan that says which arm it is
  running can be shown, stored and checked before a note is played.

This is the third time a field has landed ahead of the analysis that needs it — `SessionPlacement`
before M10, pitch before M12 — and the first time one has arrived with T1's round-trip property
already waiting. Five tests, including a take whose `experiment` key is deleted from the JSON
entirely, which is the closest a test gets to a take from 4 August. One of them asserts the
planner assigns *no* arms, so it fails the moment step 4 starts assigning them, which is when
the analysis has to exist to receive them.

### Step 2, as built

`ExperimentDesign` (id, name, question, arms, metric, takes per arm) and `ExperimentSchedule`
(assignment, progress, the stopping rule). Fifteen tests against planted histories.

**The design refuses what it cannot answer.** Fewer than two distinct arms, or fewer than two
takes per arm, and `init` returns nil rather than repairing it. One take per arm cannot see
between-take variation at all, which is finding 1 restated as a precondition.

**Bias has no better direction.** `ExperimentMetric.lowerIsBetter` is `nil` for bias and only
for bias. Spread, interference cost, tempo error and |r₁| all go down; bias is reported and never
scored, because playing ahead of the beat is normal and variance is the skill (§2). An
experiment that could score bias down would be a machine for teaching the wrong lesson.

**Assignment is min-count with a seeded tie-break**, and the tie-break is the part that matters.
Balance alone would be satisfied by strict alternation — and `ABABAB` is the wrong design,
because it puts one arm in every odd position, so any effect of *where in a sequence* a take
falls lands entirely on one arm. §7.17's two identical takes rated 4 and 1 twenty minutes apart
is exactly that effect, and it is large.

The min-count rule instead produces a random `ABBA`-like sequence: a repeat can only occur across
a tie, and after it that arm is ahead so the other must follow. Two is the ceiling on a run, the
arms never drift more than one take apart, and neither arm monopolises the odd or even slots.
Writing the test for strict alternation first is what surfaced this — the assertion failed, and
the failing sequence was better than the one being asserted.

**The seed comes from the design's UUID bytes, not `hashValue`.** Swift salts its hasher per
process, so a schedule keyed on `hashValue` would differ on every launch while looking perfectly
deterministic — R1.2.2 broken in the least visible way possible.

**The stopping rule is the whole point of step 2.** `hasPower` is false until *every* arm reaches
the preregistered target, and below it no verdict is computed at all — the headline reports how
many takes remain and nothing else, with a test asserting it contains none of "real change",
"within noise", "better", "worse" or "wins". The app recomputes after every session, which is
optional stopping; without a fixed stopping point it would be running the comparison dozens of
times and keeping whichever answer it liked. The player is shown no running tally either, since a
score on screen biases the takes still to come.

**An unknown arm counts toward no arm.** A take stamped with an arm the design no longer lists
still happened — `runIndex` counts it — but it is not quietly folded into a neighbour.

### Step 3, as built, and the estimand settled

**The unit of analysis is the take, not the event.** Each take contributes one number — its
spread, its bias, its interference cost — and an arm's value is the mean of its takes' numbers.
That is the question finding 1 deferred, and the answer turns out to be clear.

Pooling events would have been wrong twice over. A longer take would carry more weight than a
short one for no reason anybody chose. And a pooled SD across takes at different placements
includes the *between-take bias spread* on top of the within-take spread — over the 5 August
jams, sitting at −22.6 and −16.1 ms, it would report as "spread" something that is really a
difference in where the player sat. Spread is a within-take property. Every headline figure this
project has ever quoted (24.07, 17.37, 22.00) is per-take, so the analysis now matches how the
results were always read.

That also settles which bootstrap: per-take values are independent observations days apart, so
the plain resample is right, not the moving-block one. `Bootstrap.plainDifference` is now public
and `TempoMemoryAnalysis` uses it instead of its own private copy — the interference cost was
already the same shape of comparison, and there is no reason for two implementations.

**The stopping rule runs before the comparison exists.** Below the preregistered target the
difference is not computed at all, rather than computed and withheld. Withholding would still be
optional stopping: the number would be sitting there to be looked at, and this app recomputes
after every session.

**Three things make arms non-comparable regardless of count**, and each came from a defect
already in this dataset:

- *Unequal attrition.* An arm that lost more takes to unscorable drills is scored on a
  self-selected set — the recall drill's retraction (finding 2) generalised.
- *Position in the sitting.* Arms whose mean elapsed time differs by ten minutes or more are
  confounded with fatigue. §7.17's two takes identical on every number, rated 4 and 1 twenty
  minutes apart, is the calibration for that threshold.
- *Concentration in one sitting.* An arm played only on one evening carries whatever else was
  true of that evening.

**Power is reported as a minimum detectable effect, not as power.** It is the half-width of the
interval a difference of means would carry at the observed between-take spread — the size below
which a real effect still comes back as "no difference found". Calling it 80% power would imply
a design calculation nobody did, and the between-take SD it rests on is itself estimated from a
handful of takes. `takesNeeded(forEffect:)` inverts it, and the cost is quadratic: chasing an
effect half the size needs four times the evenings.

**More than two arms gets no single verdict.** Three arms would be three comparisons reported as
one, so the readout gives per-arm figures and says why it is stopping there.

Thirteen tests, including the one that matters most: two arms drawn from the ±4 ms take-to-take
wobble the benchmark jams actually show must come back as no difference. That is finding 1
arriving as an experiment rather than as a bootstrap.

### Step 4, as built

`ExperimentLibrary` declares the experiments with **fixed ids**, because the schedule is seeded
from the id — a fresh UUID each launch would reshuffle the arms of an experiment already half
collected. One runs at a time; two at once would put two instruction-only conditions on the same
evening, and a take cannot be both steady and melodic.

The planner gains a `.experiment` role and puts one take **immediately after the benchmark, at
the benchmark's own locked settings**. Both halves are R3.5. Locked parameters, because an
experiment whose tempo or length moved between arms would be comparing those. And a *fixed
slot*, because a block landing wherever it fits would let the arm correlate with how far into
the evening it ran — §7.17's two takes rated 4 and 1 twenty minutes apart is exactly that
effect. With the slot fixed the arm alternates across sittings instead, and step 3's confound
check verifies it worked.

Arms come from `ExperimentSchedule`, and the history comes from the takes themselves rather than
a separate ledger: the assignment on the take is the record of what actually ran, and a ledger
could disagree with it.

#### The instruction-only condition, and the bug it nearly caused

For `steady-vs-melodic` both arms play the same backing at the same tempo for the same length,
so **the instruction text is the entire independent variable**. Text describing the wrong arm
would not confuse the player — it would swap the conditions, and the experiment would measure
nothing while appearing to work.

Which is what was about to happen. Both surfaces called a helper `instructions(for: block.plan)`
— and a *plan* knows the drill and its settings and nothing about the arm. Every experiment take
would have shown the generic jam text and run neither arm while being recorded as one. The
tests were written first, passed against a `SessionRunner` accessor nothing called, and the
defect was two lines away in code neither test touched.

Worse, that helper existed **twice**, once per surface — the exact duplication §7.11 warns
about, where a drill silently means two different things depending on where it was started.
There is now one `DrillInstructions.forBlock(_:)` in `TrainerKit`, taking the block rather than
the plan, and both surfaces call it.

R3.6 says instructions are generated from the configuration that will actually run. For an
experiment the arm *is* part of that configuration, and it took a third instance of this same
defect to make that concrete.

Sixteen tests across the two modules, including one that every arm the library declares has
instructions of its own — an arm added to a design without text would run as a plain jam and be
recorded as a condition it never was.

### Step 5, as built

`review experiment` on the console and an `ExperimentCard` in the app's History, mirroring each
other line for line. R3.4 says both surfaces warn identically, and a readout blunter on one of
them would be the same defect as a drill whose instructions differ by surface.

**One command, not two.** §7.22 planned `experiment` for status and `review experiment` for the
readout. The readout already reports progress when it is below target — that *is* its state
before it has power — so a second command would have been a second way to ask one question.

**No number appears before the experiment has its takes.** The card shows arm counts and how
many remain, and nothing else. A running tally on screen would bias the takes still to come, in
a project whose first principle is that watching the number changes the playing.

The metric is pulled from the recomputed report, never the stored summary (R3.1). That matters
more here than anywhere else: an experiment's two arms may be weeks apart, so an analysis fix
landing between them would otherwise compare a take under the old analysis against one under the
new — R3.1's defect with a delay fuse.

A test holds that every design in the library uses a metric a jam can actually produce. An
experiment declared on `interferenceCost` or `tempoError` would collect takes forever while
reporting "still collecting" — evenings spent on something that cannot finish, which is the most
expensive quiet failure available here.

### M13, and what it has not done

Steps 1–6 are in: storage, scheduling, analysis, planning, both readouts, documentation. The
experiment block appears in the next planned session and the first arms get assigned then.

**Nothing here has been through a live run.** The planner, the runner and the instruction path
are exercised by tests that stop at the boundary of audio, and R5.6 says that is not verification.
The specific thing to watch on the first session carrying an experiment take is that **the arm
text on screen matches the arm the debrief reports** — the defect found in step 4 lived exactly
in the gap between two tested pieces, and a second one of that shape would look like data rather
than like a bug.

**No experiment can conclude for ten takes.** Both designs ask for five per arm, so the earliest
either says anything is five sittings away. That is the stopping rule working, not a delay to be
engineered around.

The first three experiments, chosen by what they unblock: **steady vs melodic** (the
mode-of-playing hypothesis §7.19 says M12 cannot test), **silent vs filled retention pooled
across takes** (n = 2 per direction with no interval, and finding 2 must land first), and
**relaxed vs focused** (§5.1's founding prediction — that focusing drives r₁ sharply negative
— has never once been tested).

Steps 4 and 5 touch the runner and the instruction path, which have no unit tests and will not
get them. Per R5.6 they need a live session and the result goes here. Two of the three defects
the first live session found were instruction and reporting bugs; expect the same class again.

---

## 7.21 Third planned session — the tightening did not hold, the placement did

5 August 2026, second sitting of the day, 20-minute target and 21.6 minutes actual. Seven
blocks, six completed. **The form block was destroyed by finding 11** and there is no form data
for this session. The player's read of the sitting as a whole was 4 out of 5; the per-take
ratings were 3, 3, 4, 2, — and 4.

### The benchmark, on three points instead of two

| | 4 Aug | 5 Aug am | 5 Aug pm |
|---|---|---|---|
| Spread | 24.07 ms | 17.37 ms | **22.00 ms** |
| Bias | −5.85 ms | −22.59 ms | −20.76 ms |
| r₁ | +0.43 | +0.46 | **+0.20** |

§7.19 recorded the 24.1 → 17.4 tightening as real, bootstrapped at [−9.41, −3.82]. It was real
*for that pair* — and it did not hold. The afternoon benchmark is 22.0, a real change of +4.63
[+1.89, +7.60] against the morning, same locked settings, same device, same calibration, 2.7
hours apart.

So the honest reading of the benchmark is now three points bouncing around ~21 ms with no
direction, and §7.19's finding should be read as what it was: a difference between two takes,
correctly measured, and never evidence of a trend. That distinction is exactly what §7.20
finding 1 was about, arriving from the other side — the pairwise comparison was sound, and the
inference drawn from it was one take too eager.

### The placement shift is the real result

Bias went −5.9 → −22.6 in §7.19 and that looked like a large excursion in a single take. It was
not. Every jam on 5 August sits there: −22.6, −16.1, −20.8, −22.4, across two sittings and 2.7
hours. A stable new placement about 15 ms further ahead of the beat, held all day.

By this project's doctrine that is not failure (§2) — variance is the skill, and the spread did
not move with it. But it is the largest persistent change in the dataset and nothing explains
it yet. Worth watching for whether it reverts overnight, which is the one thing that would tell
warm-up apart from something that actually changed.

### r₁ fell to +0.20, which is the direction success is defined in

§10 puts it first: `r₁` near zero while playing something demanding. Every jam so far has been
+0.13 … +0.47, and the afternoon benchmark reads +0.20 — a real change from +0.46 that morning
[−0.43, −0.01]. One take, one interval, and r₁ is noisy. It is not a finding. It is the first
movement toward the thing the project is for, and the benchmark slot exists to say whether it
repeats.

### Smaller notes

- **Unaccompanied tempo: 100 BPM, −0%**, at 16-bar silences, rated 4 — the best of the whole
  dataset, after 99 BPM at the same length the sitting before. The "runs ~5% slow unaccompanied"
  finding from §7.8 is dead. The clock/motor split was unreliable on this take, so it says
  nothing about which half is looser.
- **Cold probes across the three controlled sittings: −7.9%, −4.2%, −3.3%** — monotonic toward
  target. `review cold` still fits flat, because the series it fits also contains an
  uncontrolled proxy from 3 August. Three controlled probes is the minimum §7.19 said was
  needed; three points moving one way is not yet a slope.
- **The recall drill's attrition ran the other way**: 1 of 3 filled rounds played through
  against 0 of 3 silent. The cost is withheld, correctly, and this is the first take where the
  *distractor* side lost the rounds — a useful check that step 1's rule is not one-directional.
- **`review feel` is at r = −0.64** over the rated takes and now reads "well calibrated". The
  fatigue break recorded in §7.17 has not recurred.

---

## 7.22 T1 — the take factory

**Not an M-number.** M0–M22 are one axis, product capability, and this is another: what the
project can verify about itself. Numbering it into that sequence would either renumber ten
milestones or imply it sits behind them, and neither is true. It is `T1`, it runs alongside,
and its dependency order puts it **before M13's storage step**.

### The argument, which finding 11 made rather than won

A form take was destroyed because `JSONEncoder` refuses a non-finite `Double`, and the gate was
green throughout. It was green because **no test in this project has ever written a take.** 187
tests, 40 self-test checks, and the entire path from "a drill finished" to "a file exists on
disk" was covered by nothing.

The cause is a boundary that was drawn for a good reason and then treated as a law. R1.1.1 says
anything analysable goes in the pure modules *because only those run under `swift test`* — and
that is true of `Package.swift` as it stands, not of the code. Most of `TrainerKit` is not
hardware: the session types, storage, the planner-input mapping, `DrillInstructions`,
`SessionRunner`'s sequencing. Only a thin shell genuinely needs audio and MIDI. "Testable" was
allowed to mean "pure", and everything else fell off the edge.

M13 makes this urgent rather than merely true. Its first step adds `ExperimentAssignment` to all
five take types — a schema change to exactly the code finding 11 lives in, in exactly the file
that has never been exercised by a test.

### What it builds

**1. A performance generator.** Given a grid and a description of a player — bias, SD, lag-1
correlation, drift, subdivision mix, off-grid rate, chord density, velocity spread — produce
note events with times, pitches and velocities. Seeded, so R1.2.1 holds. Every test file
currently rolls its own: `BootstrapTests` has `gaussianSeries`, `TempoMemoryTests` has its round
layout, `SelfTest` has a third. One generator means one place to add a pathology and every
drill inherits it.

**2. A degenerate corpus.** The empty take. One note. Every note off-grid. Doubled hits. Playing
through the waits. A take ending in silence. 512 bars. Each drill against each pathology, as a
matrix rather than as remembered cases. Finding 11 is one cell of it, and the interesting claim
is that a matrix would have found it before a live session did.

**3. A macOS-only `TrainerKitTests` target.** The structural change, and the one with a cost.
`TrainerKit` is macOS-only by `Package.swift`, so these tests cannot run on the Linux CI leg;
they run in `check.sh`, which the pre-commit hook enforces. That asymmetry has to be stated
plainly in `STANDARDS.md` §9.4.2 when it lands, or the CI badge will quietly imply coverage
that does not exist — which is the failure R5.6 exists to prevent, in a new place.

**4. A seam under the drill runners.** `TrainerEngine.run*` welds scheduling, capture, analysis
and saving into one function, and that is why none of it can be tested. Split it: a `TakeSource`
that yields captured events plus a grid and an environment, with the live implementation driving
`GroovePlayer` and `MIDIInput`, and a synthetic one replaying generated events. The analysis and
save half then becomes ordinary testable code, and so do `SessionRunner`'s sequencing, placement
stamping and skip behaviour.

The rule that constrains this: **the synthetic source produces inputs, never results.** R1.1.2
says there is exactly one implementation of anything measured, and a test double that computed
its own asynchronies would be a second one — a measurement path that only ever runs under test,
agreeing with itself. The seam goes on the *input* side of the analysis or not at all.

**5. The round-trip property.** For every generated take of every type: save it, reload it,
recompute the report, and require the reloaded report to equal the original. One property, and
it subsumes finding 11, the R3.1 cached-summary class that shipped three times, and every future
schema change — because a field that fails to encode, or that decodes to something the analysis
reads differently, fails it by construction.

### What it cannot do, which has to be said before it is built

It cannot validate the clock bridge, buffer-phase conversion, MIDI timestamp fidelity, or audio
scheduling. Those are M0's two-path rig and `selftest`, and they need hardware. The risk is not
that T1 fails to cover them; it is that a large green test suite makes it *feel* as though it
does. R5.6 already says hardware paths are verified by a live run or the gap is stated — T1 must
restate that gap louder, not quieter, because it will be the first time the suite is big enough
to be mistaken for complete.

### Order within T1

| | Delivers |
|---|---|
| a ✅ | `TrainerKitTests` target, macOS-only, wired into `check.sh`; the round-trip property for all five stored types |
| b ✅ | The performance generator in a shared `TestSupport` target, with the ad-hoc builders migrated onto it |
| c ✅ | The degenerate corpus as a matrix, replacing the `selftest` encode checks |
| d ✅ | The clock-bridge reduction and the config boundary under test |
| e ✅ | `SessionRunner` sequencing, placement and skip behaviour under test |

Steps a–c needed no architectural change and would have caught finding 11. Step d turned out
not to need the `TakeSource` seam at all — see below.

### a and c, as built

15 tests in a new macOS-only `TrainerKitTests`, and the suite went from 192 to 207.
`TakeFactory` builds a take of any type from a `Performance` — beats, bias, spread, drift,
off-grid rate, chord size, seed — and each stored type is round-tripped: save, reload, recompute,
and the report must not move. The three `selftest` encode checks and the three structural-validity
checks are gone, since the corpus covers both properly; `selftest` is back to 36 and is once
again only about analysis against ground truth.

**Tests must not be able to touch the real practice history.** `SessionStore.directoryOverride`
redirects storage into a temporary directory per test, `StoreBackedTestCase` sets and clears it,
and every writing test asserts the redirect is live before its first save. `check.sh` fails if
anything outside `Tests/` assigns it — verified by planting an assignment. A suite that could
scribble on primary data would be a worse defect than any it caught.

**It found a real one on its first run.** Six synthetic takes were saved and one came back.
`SessionStore.save` derives the filename from the take's own date at second resolution, so two
takes finishing in the same second resolved to one path and the second **overwrote the first** —
a stored take rewritten, which R6.2 forbids outright. Unreachable in normal practice, since a
drill runs for minutes; entirely reachable by anything that saves faster, which is what the test
suite is. `uniqueURL` now suffixes a collision rather than replacing the file.

That is the argument for T1 in miniature: not that the storage layer was badly written, but that
nothing had ever exercised it, so a rule the project states outright had no way to be enforced.

### b, d and e, as built

**One generator, in a `TestSupport` target.** `Tests/TestSupport` is a plain target rather than
a test target, so every suite can import it, and it depends only on `TimingCore` so it builds on
Linux beside the pure modules. `SeededRNG`, the Wing–Kristofferson generator, the grid tap
builder and `Performance` all live there; `BootstrapTests` lost its private Gaussian, and the
`SelfTest` LCG went with the checks it served.

**One boundary is deliberately not shared, and it is worth stating as a decision rather than
leaving it to look like an oversight.** The builders for *stored* takes stay in
`TrainerKitTests`, because `JamSession` and its siblings are `internal` to `TrainerKit`. Sharing
them would mean making the storage types `public` — a permanent API commitment, bought to save a
test helper. The boundary is forced by visibility, not chosen for convenience, and no code is
duplicated across it: the generator has one home and the builders have one home.

**Moving the generator immediately broke a test, and the break was the finding.**
`testPooledDifferenceCallsNoiseNoise` builds three takes per condition from the same
distribution and asserts the pooled difference is *not* called real. With new seeds it came out
real — a false positive. That is not the generator's fault: at three takes the cluster
bootstrap's outer stage has three distinct clusters to draw from, so its interval is a few steps
rather than a curve. The test had been passing on the seeds it happened to use. It now uses
`Bootstrap.stableIntervalTakes + 2`, which is the same threshold `review conditions` already
warns below — the console note and the test now rest on one constant.

**d needed no `TakeSource` seam.** The plan assumed the analysis had to be prised out of the
runners. It did not: `JamAnalysis.reduce` was already a pure function of a `(hostTime, sample)`
map and a list of MIDI host times, so the clock bridge's *arithmetic* is now tested directly
against maps whose answer is arithmetic — a note on the beat reads zero, the calibration
constant shifts taps earlier rather than later, the guard band drops count-in notes, an
off-nominal sample rate is absorbed by the fitted slope, and a planted −18 ms bias comes back
as −18 ms. M0's rig validates the bridge against physical reality and needs hardware. Nothing
had ever checked the maths, and a sign error there would have biased every take ever recorded
while looking entirely plausible.

Not building the seam is the result, not a shortfall. It would have moved a boundary that
currently guarantees one implementation of everything measured (R1.1.2), and it turned out to
buy nothing that mattered.

**The config boundary moved, because testing it the obvious way was dangerous.** Written as
"assert `runTempo` throws", the first version of `DrillConfigTests` **played a full
two-and-a-half-minute drill through the speakers** — a config it expected to be rejected was
legal, so the test fell through into `environment()` and ran the drill. The range checks now
live on each config as `validate()`, which every `run*` calls first, and the tests call
`validate()` directly. They cannot reach an audio device at all, and the suite went from 156
seconds to 0.3.

The empty-target case that started it is a smaller story than it first looked: `allSatisfy` is
vacuously true for an empty array, so the guard accepted a config with no targets, and
`target(forRound:)` traps on `% 0`. But `TempoConfig.init` substitutes a default, so it is only
reachable by mutating the property afterwards. `TempoPlan` in `TimingCore` has no such
substitution and its `estimatedSeconds` would have trapped; both are guarded now.

**e is the session record.** `runCurrent` needs audio and stays live-run-only, but everything
around it — skip, advance, remaining time, and the manifest — does not, and that manifest is
where §7.20 finding 11 hid: a destroyed take and a declined one both read as "skipped". Seven
tests cover the state machine and check that a plan's estimated length, the runner's remaining
time, and the stored manifest all agree.

---

## 7.23 M14 — the interval ladder, and the tempo axis

### The reframe: subdivision and tempo are one axis

§7.13 describes M14 as eighths, sixteenths and triplets. That is half of it. **Both subdivision
and tempo move the same underlying variable — the inter-onset interval.** Eighths at 100 BPM are
a 300 ms IOI, and so are quarters at 200 BPM. The hand does not know which of the two produced
the number.

So M14 is an *interval* ladder with two ways of climbing it, and the analysis regresses against
IOI rather than against tempo and subdivision as separate things. Getting this wrong would mean
two rungs of the same difficulty reported as unrelated conditions.

### The player's hypothesis, and why nothing can answer it yet

> "A faster tempo is easier — to a point — to keep up with. At slower tempos I end up rushing."

That is two claims, and they need different handling.

**Rushing at slow tempos** is a claim about signed asynchrony growing more negative as the
interval lengthens. It is a real claim, it is not mechanically forced by anything, and it is
exactly the kind of thing this app exists to confirm or kill.

**"Faster is easier"** is a claim about *precision*, and raw spread cannot test it. Timing
scatter grows with the interval it is scattered within, so SD in milliseconds falls at faster
tempos almost mechanically. Comparing raw SD across tempos would produce "faster is tighter" as
an artefact of the arithmetic — the same class of mistake as §7.18's trap 2, where spread scales
with the note values played. **Spread has to be normalised by the interval before any tempo
comparison**, and the interesting shape is then whether that normalised figure has an optimum,
which is what "easier to a point" actually asserts.

#### What the 21 jams can say: almost nothing

| Tempo | Takes | |
|---|---|---|
| 100 BPM | 16 | across every sitting |
| 110 BPM | 4 | **all one evening, six minutes apart** |
| 120 BPM | 1 | |

Within the 2 August sitting, which at least holds the day fixed: 100 BPM gave mean −9.6 ms and
SD 25.9; 110 BPM gave −4.4 ms and 24.5. Both move the way the hypothesis predicts. It is three
takes against four inside one evening, with a warm-up gradient running through them, and it is
worth nothing as evidence — recorded here so it is not rediscovered later and mistaken for a
result.

**What would answer it**: takes at spread-out tempos across *different* sittings. Four takes at
one tempo in six minutes confounds tempo with fatigue and with that specific evening; one take
at each of several tempos per sitting, rotated, does not.

### Training across tempos, without destroying the trend

The player also wants to *build* precision at the standard tempos, which is a training
requirement rather than a measurement one, and the two pull in opposite directions. R3.5 exists
because every confound in this dataset arrived by a parameter changing between takes.

The separation: **the benchmark jam stays locked at 100 BPM forever**, and the *training* blocks
rotate tempo. That way the trend line keeps its one comparable slot while the practice covers
the range, and the tempo axis is measured through blocks that were designed to vary.

### Four traps, with the numbers

**1. A latent storage defect M14 trips on day one.** The jam is analysed on
`Grid(subdivisions: backing.stepsPerBeat)` and *stored* with `subdivisions: 4` hardcoded, and
`reconstruct()` rebuilds from the stored value. They agree today only because `Pattern` defaults
to 4. The moment a backing uses a different step count, every take of that backing recomputes on
a different grid than the one it was analysed on — and since everything recomputes from raw taps
(R3.1), every number for those takes would change silently between the live report and the
review. This is the hardcoded-constant-that-happens-to-match pattern, and it is step 0.

**2. The matching window shrinks with the rung.** The window is ±40% of the grid interval. At
100 BPM: quarters ±240 ms, eighths ±120 ms, triplet eighths ±80 ms, sixteenths ±60 ms. Against
this player's ~20 ms spread that is 3.0 SD at sixteenths — acceptable. At 140 BPM it is 2.1 SD,
and roughly 3.6% of correctly aimed notes are discarded as off-grid rather than 0.3%. **Off-grid
rate becomes a property of the rung rather than of the player**, which is §7.18's censoring trap
arriving through a new door. Each rung needs a tempo ceiling, or an honest flag when it is
exceeded.

**3. Nothing is comparable across rungs without normalising.** Spread scales with the interval,
so the ladder cannot be one trend line. Subdivision and tempo join backing and level as confound
axes (R3.4), and both the trend and the pooled comparisons must split on them — while the
IOI-normalised figure is what makes rungs comparable at all.

**4. Two isochrony gates assume quarters.** The continuation drill's Wing–Kristofferson needs an
isochronous series, and the tempo drill rejects a round that is not one note per beat, though it
already normalises consistent subdividing through `notesPerBeat`. Asking for eighths means the
W-K series *is* eighths; the model still holds, but both gates have to accept the rung instead
of the beat.

### What must not move while M13 is collecting

Both running experiments are jams at the benchmark's locked settings, and they need ten takes
across roughly five sittings. **M14 must not touch the benchmark or the experiment block.** The
ladder belongs to a training block; changing the jam backing's subdivision underneath a running
experiment would either break R3.5 or silently confound five evenings of collection.

### Steps

| | Delivers |
|---|---|
| 0 ✅ | Store the grid's actual subdivision instead of a hardcoded 4. Prerequisite, and worth doing whether or not M14 proceeds. |
| 1 ✅ | `IntervalRung` in `TimingCore` — subdivision, tempo ceiling from the matching window, and the IOI it implies. Tests that the window stays at or above 3 SD at the ceiling. |
| 2 ✅ | Backings per rung in `GrooveCore`. The groove has to *imply* the subdivision or there is nothing to lock to. |
| 3 ✅ | The tempo-and-interval readout: spread normalised by IOI, signed asynchrony against IOI, and both split by rung. This is the step that answers the player's question, and on today's data its honest answer is "not enough tempo spread yet". |
| 3b ✅ | The premise underneath step 3, measured instead of assumed: does spread actually scale with the interval? It does not. See below. |
| 4a ✅ | Ground clearing found by the pre-step-4 review: one matching-window constant, one block-to-instructions mapping, one meaning for `LadderBackings`' parameter. |
| 4b ✅ | The **jam** gains a rung, end to end: config, backing, analysis grid, storage, instructions (R3.6), the CLI, and the confound axes that consume it. |
| 4d ✅ | Planner rotates tempo on a ladder training block only, picking the rung after the tempo, with tests that it never touches the benchmark, the cold probe or an experiment block. |
| 4e ✅ | The continuation and tempo drills gain a rung, and the period estimate stops guessing the note value (trap 4). |
| 5 ✅ | A `slow-vs-fast` experiment in the M13 library, so the tempo question gets a preregistered answer rather than an observational one. Queued behind the two experiments already collecting. |
| 6 ✅ | Both surfaces, and docs. |

### Step 0, as built

Each outcome now carries the grid it was **analysed** on, and storage writes that value rather
than a literal. The two cannot disagree because they are the same property of the same object —
the fix is structural, not a matter of keeping two constants in sync.

`FormSession` and `DropoutSession` gained the field too. Neither was wrong today, because both
hardcoded the same number in two files, but M14 step 4 varies both and the duplication is the
defect rather than the mismatch. Optional, so every take on disk still decodes and still
reconstructs on exactly what it was scored on — 4 for form, 1 for continuation.

**The interesting part is what a wrong subdivision actually costs**, which is not what it looks
like. For notes played *on the beat* it costs nothing: the beat is a grid point at every
subdivision, so asynchrony and spread come out identical. The first test written here asserted
that a coarser grid changes the numbers, and it failed — correctly.

It bites on notes played *between* beats. An eighth-note offbeat sits 300 ms from the nearest
quarter-note grid point at 100 BPM, well outside the ±240 ms window, so a coarse grid **discards
it as off-grid instead of scoring it**. A take reconstructed one rung too coarse silently throws
away half the performance and reports the survivors — which is §7.18's censoring trap again, this
time reached by a storage bug rather than by playing.

The test now plants straight eighths and asserts 64 matched at `subdivisions: 2` against 32
matched and 32 extras at `subdivisions: 1`. That is the defect stated as a number.

One process note. A stale incremental build produced a segfault mid-suite: struct layouts had
changed while test objects were still compiled against the old ones. It reproduced twice, passed
in isolation, and disappeared entirely under `swift package clean`. Recorded because a crash that
vanishes is exactly the kind of thing that gets waved away, and the way to tell the two apart is
a clean build rather than a re-run.

### Step 1, as built, and the ceiling it exposes

`IntervalRung` — quarters, eighths, triplet eighths, sixteenths — carrying its subdivision, the
interval it implies at a tempo, and the tempo above which it can no longer be scored honestly.
Eleven tests.

**The ceiling is derived, not chosen.** The matching window is `0.4 × 60 / (bpm × subdivisions)`,
and requiring it to be worth at least three of the player's own spreads rearranges to a maximum
tempo. Three spreads because a note 3 SD from where it was aimed still scores and only ~0.3% fall
outside; at two it is 4.6%, and the off-grid rate has become a property of the rung rather than
of the player. That is §7.18's censoring trap arriving through the ladder.

Because it is derived from the player's measured spread, the ceiling **moves as they change** —
a fact about them and the arithmetic rather than a number somebody picked. At 10 ms it doubles;
at 40 ms it halves. The window fraction now lives on `Matching` and is read from there, so the
ladder and the matcher cannot disagree about what counts as on the grid.

#### At this player's ~20 ms spread

| Rung | Ceiling |
|---|---|
| Quarters | 400 BPM (the engine's own limit of 260 binds first) |
| Eighths | 200 BPM |
| Triplet eighths | 133 BPM |
| **Sixteenths** | **100 BPM** |

This rests on the player's spread being the same number of milliseconds whatever the interval,
which was an assumption when it was written and is a measurement since step 3b below.

**Sixteenths are already at their ceiling at the reference tempo**, and one BPM above it the top
rung stops being honest. That is not a defect, and it is not a reason to loosen the rule — it is
the ladder saying that at 20 ms spread, sixteenths at 100 BPM is the edge of what this app can
measure about this player. The rung becomes available at higher tempos exactly when the spread
comes down, which is the thing being trained.

It also settles a question step 4 would otherwise have had to guess at: the tempo rotation and
the rung cannot be chosen independently. A training block at sixteenths has to stay at or below
100 BPM, so the planner picks the rung *after* the tempo, and the two together are one decision.

### Step 2, as built

`LadderBackings` — one groove per subdivision, with the hat carrying the division and everything
else held constant: kick on 1 and 3, backbeat on 2 and 4, at every rung. Only the density
changes, which is the point. Nine tests, and `jamBacking` is untouched, so the benchmark and both
running experiments play over exactly what they always did.

**Keyed by steps per beat, not by `IntervalRung`.** `GrooveCore` depends on nothing, not even
`TimingCore` (R1.1.3), so the rung-to-backing pairing belongs in `TrainerKit` and lands in step
4. The alternative — importing `TimingCore` for one enum — would trade a rule that has held since
M3 for a convenience.

**The pattern's step resolution is not the analysis grid**, and this is the distinction the whole
step turns on. The step grid is how finely the drums can be programmed; the analysis grid is what
the player is scored against. They coincide at 4 today, which is why every take so far has been
scored on a sixteenth-note grid — and why, at this player's spread, every take so far has been
scored at exactly the ceiling step 1 derived.

I then made that very conflation in the code while documenting it: the fill builder passed the
*rung's* subdivision where the *pattern's* resolution belonged, so a quarters fill came out
claiming one step per beat. The test asserting that a fill keeps its groove's resolution caught
it immediately. Worth recording because the header comment explaining the distinction was already
written above the line that got it wrong.

**Triplets carry their own step resolution** — twelve to the bar, three to the beat — rather than
an approximation on sixteenths. No step grid carries both, which is exactly why a take is
straight or triplet and never both.

The strongest test is in seconds rather than step indices. Step numbers are easy to get right and
prove nothing: the sequencer converts them at `60 / bpm / stepsPerBeat`, and a twelve-step bar is
where that could quietly produce a bar of the wrong length. So the assertion is that the gap
between hats equals the rung's own interval, and that a bar lasts four beats however it is
divided.

#### Heard, which is the only way to know

All four rungs were rendered at 100 BPM and listened to: **they sound right at the reference
tempo**, including the twelve-step triplet bar, whose maths had been verified in seconds but
whose *feel* no test could speak to. The fills keep their pulse. That is the live-run-shaped
check the ladder needed before step 4, done without booking a session.

It needed a way to hear a groove at all, so `render` now writes each backing to a WAV. Before
this, auditioning a backing meant a live run — which made "listen before promoting the player
onto a rung" a precondition nobody would actually satisfy. It reports peak level and counts
clipped samples, because a groove rendered too hot would be judged as a bad groove rather than a
bad gain, and it marks any rung sitting above its ceiling at the requested tempo — computed from
the median spread of the player's own recent takes (currently 20.1 ms, against the 20 assumed in
step 1) rather than from a constant.

Rendering at 132 BPM therefore prints exactly what step 1 predicted: sixteenths flagged, the
other three clean. The ceiling stopped being arithmetic on a page at that point.

#### What the existing takes already say about the ceiling

Step 1 put sixteenths at a 100 BPM ceiling for this player. The 120 BPM take (#21) was scored on
a sixteenth grid, so it ran above that ceiling, and its off-grid rate is 5.3% against 4.3–4.9%
for the 100 BPM takes either side of it.

The direction matches, the magnitude is about what the narrowed window predicts (roughly one
point), and it is one take. What it mainly shows is that the window effect is **small next to the
baseline**: 4–5% of notes are off-grid at the reference tempo, so most off-grid notes are
genuinely off-grid playing rather than a scoring artefact. The ceiling is worth keeping, and it
is not what is driving the off-grid rate.

### Step 3, as built, and what it says today

`IntervalResponseAnalysis` and `review interval`. Takes are bucketed by the interval they were
played at, spread is reported **relative to that interval**, and two slopes are fitted against
it: relative spread, and signed placement. Nine tests.

**The two claims are tested apart because they need different handling.** Rushing at slow tempos
is a claim about signed asynchrony and nothing forces it mechanically, so a slope there is a
finding. "Faster is easier" is a claim about precision, and raw spread cannot carry it — scatter
grows with the interval it sits inside, so milliseconds fall at faster tempos on their own. The
test that pins this plants a player whose spread is exactly 3% of the interval at every tempo and
requires the analysis to report *no* tempo effect, while the raw millisecond figures it was
computed from differ by more than a factor of two.

#### The mistake worth recording: what "the interval" means

The first version used the grid the take was *scored* on. Every jam so far is free playing scored
on a sixteenth-note grid, so it reported a 150 ms task at 100 BPM — **an interval nobody
performed**. The scoring resolution is a property of the analysis; the task interval is a
property of what the player was asked to do, and they are only the same once a rung is
prescribed.

`IntervalObservation.subdivisions` is now explicitly *notes per beat the player was asked to
produce*, which is 1 for every take on record and becomes the rung from step 4. That turned 150
ms into 600 ms and relative spread from a meaningless 14.9% into 3.7%.

This is the same conflation as step 2's fill bug — pattern resolution against analysis grid —
arriving a third time on a different axis. It is worth naming as a recurring shape rather than
three separate slips: **in this codebase, "how finely we divide the beat" always has at least two
meanings, and they are rarely the same one.**

#### What it says on the 21 jams

| Interval | Tempo | Takes | Spread | Of interval | Placement |
|---|---|---|---|---|---|
| 500 ms | 120 BPM | 1 | 19.3 ms | 3.9% | −13.5 ms |
| 545 ms | 110 BPM | 4 (one sitting) | 24.5 ms | 4.5% | −4.4 ms |
| 600 ms | 100 BPM | 16 | 22.4 ms | 3.7% | −14.1 ms |

**No slope, and the refusal is the finding.** Three intervals with at least two takes each are
needed; there are two. But the shape is informative in its own right: the 110 BPM evening is
worst on *both* measures while the tempos either side of it resemble each other more than either
resembles it. That is the signature of one different evening, not of a tempo response — and it is
exactly what a slope fitted through three points would have hidden.

It also sharpens what to record. Four takes at one tempo six minutes apart bought almost nothing;
one take per tempo per sitting, rotated, is what turns this from a refusal into an answer.

### Step 3b — the premise, measured, and it is false

Everything above rests on one sentence, stated three times in this section as fact: **scatter
grows with the interval it sits inside.** Step 3 divides spread by the interval on that basis.
Step 1 derives tempo ceilings that only bind if the *opposite* is true — a window fixed at 40%
of the interval is a constant number of spreads at every rung if spread scales, and no ceiling
would ever bind. Both cannot be right, and neither had been checked.

The takes on disk can check it. Bin every matched note by the gap **in grid steps** to the note
before it, and compare spread across bins.

| Notes apart | Share of all matched notes |
|---|---|
| a sixteenth | **0.5%** — 25 notes in 21 takes |
| an eighth | 10.5% |
| **a beat** | **82.4%** |
| two beats | 2.7% |

| Interval | Notes | Spread | Of interval |
|---|---|---|---|
| 273 ms | 220 | 25.6 ms | 9.4% |
| 300 ms | 361 | 25.2 ms | 8.4% |
| 500 ms | 292 | 19.1 ms | 3.8% |
| 545 ms | 485 | 22.4 ms | 4.1% |
| 600 ms | 3778 | 22.4 ms | 3.7% |
| 1200 ms | 131 | 26.8 ms | 2.2% |

**Absolute spread is flat and relative spread is not**: +0.02 ms of spread per 100 ms of
interval, interval [−3.53, +0.79], against −0.72 points per 100 ms [−2.35, −0.40] for the
percentage. Milliseconds are this player's invariant. Over a 4.4× range of interval his scatter
is the same ~22–26 ms throughout, and within single takes the busier passages are if anything
the *looser* ones — which is M12's within-take result (+0.40, +0.57) arriving on a second route.

**The bin key has to be the grid gap and never the measured one**, and the reason is not
fussiness. A measured inter-onset interval is `gap × interval + async − asyncOfPrevious`, so a
note's own error sits inside its own bin key; conditioning on that difference pins each bin's
mean at half its own offset. It leaves spread almost untouched and fabricates a *placement*
slope of about +0.5 ms per ms out of a player whose placement never moved — which is precisely
the "slow tempos make me rush" claim. A test plants a constant-placement player and requires the
measured-IOI binning to invent that slope. Its first version asserted the artefact would show up
in spread, and it failing is what found the real shape.

Three limits, stated because they bound what this licenses:

1. **Every spread here is a floor.** All bins are censored at the same ±40% window, so the
   comparison across bins is fair, but the tails are cut off. Censoring compresses an ordering,
   it cannot invert one — a scaling player would still read as scaling — so the flatness
   survives it while the absolute figures do not.
2. **It says nothing about sixteenths.** 25 notes in 21 takes is not a measurement, and
   sixteenths are the rung the ceiling actually binds on. The ceiling's extrapolation from a
   150 ms grid down to a 150 ms *task* is still an extrapolation.
3. **It is free playing, at one tempo per bin.** The gaps are ones the player chose moment to
   moment, not rungs he was set. Whether a prescribed rung behaves the same way is what step 4
   collects.

**Falsifier**: a prescribed-sixteenths take whose absolute spread comes back near 6 ms rather
than near 22 kills this and restores step 3's premise.

**Recomputed on 27 jams after the 5 August session, and again on 30**: absolute −0.11 ms per
100 ms [−1.85, +0.63] against −1.07 points [−2.54, −0.69] for the percentage. The conclusion has
survived three recomputes.

The table above is the 21-take snapshot the finding was made on, and the shares have moved with
every sitting since. **Among free jams, which is the population this caveat is about**, a beat
apart went 82.4% → 78.7% → 78.4% and an eighth 10.5% → 14.7% → 15.0%. Across *all* 30 jams the
beat share is 70.2% and the eighth 23.9%, because M15's two swung takes and the skank are
prescribed eighths and pull the whole corpus. Two different populations, two right answers —
quote the free-jam figure when caveating a free-jam number.

#### What it decides

**The ceiling stands** (step 1). Its assumption is the measured one, not an unexamined one.
Step 4d feeds each rung its *own* spread once that rung has takes, with a minimum count before
the per-rung figure is trusted, so one bad evening cannot lock the player out of a tempo he can
handle. The relative formulation is positively contradicted — at 3.7% it would have said no rung
ever has a ceiling.

**Step 3 stops asserting an answer.** `review interval` now fits absolute and relative side by
side and names which came out flat, rather than dividing by the interval and reporting one
number. Its headline test planted a player at "3% of the interval at every tempo" and required
no tempo effect, which encoded the assumption into the suite; it now has a mirror twin planting
constant milliseconds, and the analysis has to tell them apart.

**`steady-vs-melodic` is left exactly as preregistered.** The confound raised against it before
this was measured — that the melodic arm gets a mechanical advantage because shorter intervals
scatter less in milliseconds — predicted ~11 ms against 22 ms. The measurement is 25.2 ms at
300 ms against 22.4 ms at 600 ms. The prediction was wrong by a factor of two and in the wrong
direction, and the options built on it (normalising the metric, blocking on density, narrowing
the arms to pitch-only) were all solving a problem that does not exist.

What remains is not a confound but the hypothesis. The arms differ in density by construction,
density does track spread here, and "melodic playing is looser because it is busier" *is* an
answer to "does what you play change how you time it". So density becomes a **reported
covariate** on both surfaces — never a blocker, because blocking on the condition guarantees a
refusal after five evenings, and never a normaliser, because dividing by the treatment would
delete the effect it is meant to expose.

#### The thing this recontextualises

**82.4% of every matched note this project had recorded at the time was a beat apart from the
last one** — 78.4% over the 26 free jams on record now, and the point is unchanged. So 24.07,
17.37, 22.00, "his ~20 ms spread", the trend line, `review feel`, both experiments and the
ceiling are all, to within a rounding error, *quarter-note placement in free playing*. The
sixteenth-note grid those takes were scored on is doing almost no work.

That reframes M14. §7.13 and this section describe the ladder as extending a measured skill onto
new rungs. It is not: it is the first measurement of 90% of the space. Everything derived from
quarters should carry less confidence into it than the prose above assumed, and the value of
the milestone is correspondingly higher.

### Step 4b, as built — the jam gains a rung

`jam [bpm] [bars] [tag] [rung]`, and `JamPlan`/`JamConfig` carry an `IntervalRung?`. Fourteen
tests.

**`nil` is "no rung was prescribed", never "quarters".** They are different tasks — "play what
you like" against "play one note per beat" — and a default would have silently converted the
benchmark and both experiment blocks into drills, which is R3.5 broken in the least visible way
available. A test asserts a rung-less config still picks `jamBacking`, still scores on a
4-per-beat grid, and still produces the same settings label.

**The analysis grid comes from the rung, and this is the whole step.** `runJam` derived it from
`backing.stepsPerBeat` until now, and `LadderBackings` returns a pattern whose `stepsPerBeat` is
**4 for quarters, eighths and sixteenths alike** — all three are programmed on a sixteenth step
grid and differ only in which steps fire. So the backing cannot tell three of the four rungs
apart, and a quarters take would have been scored against a 150 ms grid at 100 BPM: a task
nobody was set. Reverting the one line fails five tests, which was checked rather than assumed.

That also makes step 1's ceilings mean something. The window is `0.4 × 60 / (bpm ×
subdivisions)`, so the subdivision here *is* the quantity the ceiling constrains. A consequence
worth stating: at quarters the window is ±240 ms, twelve of this player's own spreads, so
nothing is off-grid; at sixteenths it is ±60 ms, three of them. **Off-grid rate is not
comparable across rungs**, which is §7.18's censoring trap arriving through the ladder exactly
as trap 2 predicted — though in the opposite direction from the one that was expected.

**`grooveName` stopped being a literal.** It was `"jamBacking"` hardcoded at save, so every
confound check keyed on it — `comparabilityNotes`, the trend warnings — would have gone blind
the moment a jam played over a ladder groove. It now records the backing that actually played.

**Two subdivisions are stored, not one.** `subdivisions` is the grid the take was *analysed* on
and `rung` is what the player was *asked* for. They are equal whenever a rung was set and
different for every take on record, where the task was the beat and the scoring grid was
sixteenths. `taskSubdivisions` is that distinction, and it is what `IntervalObservation` reads —
the hardcoded `1` step 3 left behind. A test strips the key from the JSON entirely and requires
the take to read as free playing; another plants a rung name this build does not know and
requires it to be kept verbatim as the record of what ran while nothing is inferred from it.

**Instructions are part of the step, not a follow-up.** A rung the player is not told about is a
rung they will not play: the backing makes the division audible but does not *ask* for it, and a
player who hears sixteenth hats and keeps playing quarters has produced a fine free jam scored
against a grid four times finer than the one they aimed at. Each rung names its own division and
warns that a coarser one is **discarded rather than scored late**, which is the mistake that
invalidates the take rather than lowering it. An experiment arm still wins over a rung where
both are somehow set — an instruction-only design loses its conditions if the arm text goes.

**The trend groups on tempo and rung together**, because they are one axis. Free playing is its
own group rather than folding into quarters. `comparabilityNotes` gains the same row.

**Not in this step:** the app's single-take setup screen has no rung picker, so a hand-run rung
take is CLI-only until step 6. Sessions are unaffected — the planner will hand rungs to the app
through `SessionRunner` at step 4d.

### Step 4d, as built — the planner varies one block, and only one

A **ladder block** joins the evening: one jam at a rotated tempo and a prescribed rung, tagged
`ladder` so it can never pool with free playing. Eighteen tests.

**Tempo first, rung second.** Step 1 settled that these are one decision and this is where it
lands: a rung chosen before the tempo can be illegal by the time the tempo arrives, since at
140 BPM only quarters and eighths clear their ceiling at this player's spread. Choosing in this
order means the ceiling constrains rather than contradicts, and a test asserts the same history
that yields sixteenths at 80 BPM yields eighths at 140.

**80 / 100 / 120 / 140, by min-count with a seeded tie-break.** Not a cycle: a strict rotation
puts each tempo at a fixed position in the sequence, so anything varying with *where in a run* a
take falls lands entirely on one tempo — the `ExperimentSchedule` argument (§7.20 step 2) on a
different axis. The tempos stay within one of each other and the order still shuffles.

**Promotion is one rung at a time**, from the highest already recorded. That gate is not about
measurement, unlike the ceiling: no rung above eighths has ever been played and whether a groove
is playable-along-to is not something its step list can answer (R5.6), so promoting two at once
would put the player on a backing nobody has heard at a tempo nobody has tried.

**The ceiling now prefers the rung's own spread** once that rung has two takes, falling back to
the overall median otherwise. One take does not overrule it: a bad first evening would lower
that rung's ceiling and lock the player out of tempos they can handle. Step 3b is what makes the
fallback sound — absolute spread is interval-invariant for this player, so the overall figure is
a fair estimate for a rung never played.

**It takes a slot outright rather than competing**, exactly as form does and for a matching
reason: it is on a third axis. Ranked against the clock drills on their evidence it would never
be scheduled at all — the split is settled, the clock is the looser half, and the continuation
and recall drills fill every slot they are offered. `maximumTrainingBlocks` goes to four with
two reserved, so the clock drills still get the same two they had.

#### It crowded form out of every short session, and the test for that missed it

Two blocks that each take a slot outright are ordered by which is appended first, and in a
session too short for both the second one goes. Adding the ladder ahead of form dropped form
from **every 20-minute session** — §7.16's regression exactly, arriving on a new cause a
milestone later.

The test written to catch it did not, because it ran only at 45 minutes, where both fit and the
ordering is invisible. The shortest session is the only place the ordering is observable, which
makes it the only length worth testing; it now runs at 20, 30 and 45 across nine histories.

Form goes first: it has the older claim and the explicit guard, and the ladder is the block that
waits for a longer evening. When the ladder is the one that does not fit, the plan says so —
a block silently missing is a session the player has no way to disagree with.

#### The test that passed when it should not have

`testTheBenchmarkNeverMoves` compared each plan's benchmark against a reference plan built by
the same planner. Planting a benchmark at `referenceBpm + 5` did **not** fail it: the reference
moved with the thing it was checking, so the test could see variation *between* histories and
was blind to a constant that was simply wrong — which is the likelier mistake once a planner has
a tempo rotation in it at all. It now asserts the values absolutely, and the planted violation
fails 27 assertions. R5.7 is written about `check.sh` rules; it applies to any test whose whole
job is that something did not change.

### Step 4e, as built — the period estimate stops guessing

Trap 4 named "two isochrony gates assume quarters". Reading them, the gates themselves do not:
both accept a silence whose intervals sit within 0.6–1.6× of *its own* median, which is
rung-agnostic already. What assumed quarters was the step after — turning a note period into a
beat tempo — and it assumed it in a way that could invert a sign.

**The defect.** Both drills computed `notesPerBeat` as the target beat divided by the median
interval, **rounded, with no check on how far the rounding moved**. At 100 BPM a player holding
1.45 notes per beat rounds to 1 and is reported at 145 BPM — 45% fast. Round the other way and
the same playing reads 72.5 BPM, 27% slow. Same notes, same target, opposite directions, and the
analysis picked one and printed it as a fact. Between whole numbers it genuinely cannot tell
"slow eighths" from "fast quarters", so it now says so instead of choosing (R3.3).

**Prescribing removes the question entirely.** `DropoutConfig` and `TempoConfig` carry a rung,
the planner sets `.quarters` on both, and the analysis is told rather than inferring. That is
**not a change of task**: the continuation drill's instructions have said "play exactly ONE NOTE
PER BEAT" since M6 and the tempo drill's since M8. All that changed is that the analysis now
knows what the words already said. A round asked for eighths and played in quarters is reported
as not having performed the task, rather than quietly rescored against what it happened to be.

**No stored number moved.** Every take on disk sits within 6% of a whole subdivision, so nothing
trips the new refusal and `review dropout` and `review tempo` print exactly what they printed
before. This is latent protection rather than a retroactive correction — worth stating, because
"the fix changed no output" reads as evidence the fix was unnecessary and it is not. The 4-bar
and 8-bar silences are the ones at risk: the more the pulse drifts inside a silence, the further
the median can land from a whole subdivision.

**Two more duplicated pipelines collapsed.** Seven call sites paired `DropoutSession.reconstruct()`
with a `DropoutAnalysis.analyze` of their own, and five did the same for `TempoSession` — so the
rung would have had to reach twelve places, and the one that forgot would silently re-infer and
disagree with the take's own report depending on which readout asked. Both types now have a
`report()`, like `JamSession` has had since M4, and every caller goes through it.

**The form drill deliberately gains nothing.** An earlier version of this table said "the other
four drills gain a rung", which was wrong: form marks phrase tops with pads while the keys are
free playing, so there is no subdivision being scored and a rung would be a setting that changes
nothing. The recall drill inherits the fix without its own field, because its per-round scoring
*is* `TempoCalibrationAnalysis` (§7.16) rather than a parallel copy.

**Not rotated by the planner.** These two drills feed the clock/motor trend and the tempo-error
trend, and R3.5 locks drill parameters that feed a trend. The ladder block is where the interval
varies; here the rung is set to what the drill already asked for and stays there. It is available
by hand — `dropout 100 4 8 6 eighths` — for when the clock/motor question is settled.

### Step 5, as built — the tempo question, preregistered

`slow-vs-fast`, declared in `ExperimentLibrary` before a single take of it exists (§9.5.1).
Nineteen tests.

| | |
|---|---|
| Question | Does a slower tempo pull you further ahead of the beat? |
| Arms | `slow` at 80 BPM, `fast` at 140 BPM |
| Metric | **bias**, in milliseconds |
| Takes per arm | 6 |
| Falsified by | placement not differing between the arms by more than the interval |

**Which half of the hypothesis this asks.** The player's account is two claims: faster is easier
to a point, and slow tempos make him rush. This asks the rushing half, because §7.23 singles it
out as a claim about signed placement that nothing forces mechanically — the kind of thing the
app exists to confirm or kill. The precision half now has a cheaper route: the ladder block
varies tempo every sitting and `review interval` fits it observationally.

**Free playing, not a rung**, so the take is directly comparable to the benchmark and to every
take on record. The ladder varies tempo *and* subdivision together; this isolates tempo.

**Step 3b is what licenses the metric.** Comparing raw milliseconds across tempos would have
been arithmetic rather than skill if this player's scatter scaled with the interval. It does not,
measurably, across a 4.4× range — so the mechanical objection is gone and what remains is a real
question. The readout carries that premise as a note, because a result whose validity rests on
another finding should not be readable without it.

**Bias has no better direction and that is the right shape here.** The existing machinery
reports which way placement moved and refuses to call either arm better (§2). An experiment that
could score placement down would be a machine for teaching that playing ahead of the beat is a
fault.

#### The first design where the text is not the condition

For `steady-vs-melodic` the instruction text **is** the independent variable, so text describing
the wrong arm swaps the conditions silently (§7.20 step 4). Here the tempo differs whatever the
text says, so wrong text would confuse rather than invert. `ExperimentDesign.bpmByArm` makes the
difference explicit rather than leaving it to be inferred, and `variesTempo` is what the planner
and the readout branch on.

A per-arm tempo missing an arm would run that arm at the reference and turn a two-tempo
comparison into a one-tempo one while still reporting two conditions, so `init?` refuses it —
along with two arms sharing a tempo, and any tempo outside the engine's range. Everything except
the tempo stays locked (R3.5), with a test asserting the experiment block matches the benchmark
on length and on carrying no rung.

#### What it can and cannot detect, stated before any data

The between-take spread on placement is large: the three benchmark takes sit at −5.9, −22.6 and
−20.8 ms at **one** tempo, an SD of 9.2 ms. At six takes per arm the minimum detectable effect
is about **10 ms**.

That is roughly the size of the largest persistent placement change this dataset has recorded —
the ~15 ms shift that held all day on 5 August and is still unexplained (§7.21). So the design
can separate a tempo effect of that magnitude from zero and nothing smaller. A null result would
be genuinely informative rather than a shrug: the player describes rushing at slow tempos as
something he *notices*, and an effect he notices being under 10 ms would itself be a finding.

**It is a long way off.** One experiment take per session, three designs queued, ten takes for
each of the first two and twelve for this one — so `slow-vs-fast` starts after roughly twenty
sittings and finishes after thirty-two. That is the stopping rule working rather than a delay to
engineer around (§7.20), and it is the reason the ladder's observational readout matters in the
meantime: it answers the same question sooner and less cleanly, which is the right trade while
the preregistered one collects.

### Step 6, as built — the app can ask for a rung too

Until now a rung could only be set from the console, which is the shape of §7.20 finding 9: not
a presentation gap but a **capability** one, where the app cannot do something the CLI can. Jam,
Alone and Tempo gain a subdivision picker; Form deliberately does not, for the reason step 4e
gives.

**The picker offers only what the tempo can score.** Rather than listing four rungs and
explaining afterwards that some would throw away notes, it lists the scorable ones and says why
the others are missing — and moving the tempo slider drops a rung that has just gone above its
ceiling, so the picker and the take can never disagree about what is legal.

**A hidden rung has to name the way in**, which the first version did not. It said "finer
divisions are hidden at 100 BPM" — plural for what is usually one rung, without naming it and
without the tempo that reveals it. Sixteenths sit at a 99 BPM ceiling at this player's current
spread, so they are unreachable from the 100 BPM default, and a picker that hides them silently
looks like the rung does not exist rather than like it is one BPM out of reach. It now reads
*"sixteenths at 99 BPM or below … they open up as your spread comes down"*, which is step 1's
prediction arriving on screen: the ceiling is a fact about the player, and the top rung becomes
available exactly when the thing being trained improves.

**Free is the jam's default and is not quarters.** The other two default to quarters, because
their instructions have asked for one note per beat since M6 and M8.

**The take screen still shows nothing**, and the results screen now says what the take was
scored against: the rung, the grid, and the window in milliseconds. That last number is why it
is there — the window is ±40% of the division, so it is four times narrower at sixteenths than
at quarters and the off-grid count is not comparable between them. Jam and continuation history
rows carry the rung in their title, since two takes at one tempo and length are different tasks
if one was asked for a subdivision.

**One more constant collapsed.** `render`, the `jam` command and now the app all need the
player's recent spread to place a ceiling, and all three were computing "the median of the last
six" separately — three chances to disagree about which rungs exist.
`TrainerEngine.recentJamSpreadsMs()` is the one implementation, with four tests including the
one that matters: a tighter history raises the ceiling it feeds, which is the property that
makes the ceiling a fact about the player rather than a number somebody picked.

**Not tested, and worth saying plainly.** The picker itself is SwiftUI in `MusicalTrainerApp`,
which has no test target — the logic under it (`IntervalRung.scorable`, `recentJamSpreadsMs`) is
covered, the view is not. It needs eyes on it, like every other screen in this app.

### The first live run — 5 August, and what it found

A 30-minute session, 35.2 minutes actual, eight of nine blocks completed. **The chain held**:
the ladder take stored `rung=quarters`, `groove=ladder-quarters`, `subdivisions=1`, `tag=ladder`,
and the experiment take was stamped `steady-vs-melodic`. Rung → backing → analysis grid →
storage, and the arm, all survived their first contact with a real session.

**The timing data from this sitting is not usable and is not being read.** The player was
exhausted and dozing through several takes. Recorded here so it is not rediscovered later and
mistaken for a result — the same note §7.23 makes about the four 110 BPM takes.

What the session did produce is a usability report, and those have been the most reliable
signal this project gets: §6.1's form instructions, §7.17's absent cue and §7.19's unwarned
silence all arrived this way. The player lost track of which drill he was in, more than once,
and said the exercises had started to sound the same.

#### That is structural, not a mood

| Block | Asks for |
|---|---|
| Tempo (cold) | one note per beat |
| Jam (experiment, `steady` arm) | one note per beat |
| Alone | one note per beat |
| Recall (reproduction) | one note per beat |
| Jam (ladder, quarters) | one note per beat |

**Five of nine blocks asked for the identical physical action**, and three of the four jams
played over the same backing. Telling those blocks apart required metadata nobody can hear.
Losing the thread is the correct response to that session rather than a lapse in it, and no
amount of clearer instruction text fixes a session that genuinely is five variations of one
action.

#### Two fixes

**The count-in now states the rung.** It was `hatsEveryBeat` on `basicRock` regardless of rung,
so a sixteenths take announced quarters and then switched — the drill contradicting itself
before a note was played, which is §7.17's defect in the audio domain. A rung now counts in on
its own division: hats only, no backbeat, so the boundary into the groove stays audible. A free
jam keeps exactly what every recorded take has had (R3.5).

It lives on `JamConfig` rather than inside `runJam`, and that placement is the point. Reverting
it inside `runJam` compiled cleanly and broke no test, because `runJam` needs an audio device
and nothing there can be reached from a suite. Moved onto the config beside `backing` and
`gridSubdivisions`, the same revert fails nine assertions. Third instance on this branch of the
path under test not being the path that ships.

**The ladder starts at eighths.** Quarters is both the rung that duplicates those five blocks
and the one whose backing is least familiar; `LadderBackings.eighths` shares its skeleton with
`basicRock`, which every take on record has played over, so it is the *least* novel rung in the
set. The one-step promotion rule exists to keep the player off a backing nobody has heard
(R5.6) and eighths satisfies it outright. Quarters remains reachable by hand from either
surface — it is only the planner that will not choose it.

#### A sitting can now say what it is

There was nowhere to declare "I am exhausted tonight". A single take carries a `tag`; a session
take gets a role tag instead, so the one sitting that most needed a caveat had no field for one.

`SessionState` — **usual, tired, amped, distracted, stiff** — declared before the first block
and stamped on every take of the sitting via `SessionPlacement`.

**Before, or not at all.** Marking a sitting after it has gone badly is post-hoc exclusion, one
step from dropping the takes you dislike, and this project fights that everywhere else — the
preregistered stopping rule, the refusal to revise `takesPerArm`, the withheld interference
cost. Declared first it is an ordinary condition and `review tags` already knows how to pool
conditions. There is deliberately no "discard this session" switch: §7.17 found fatigue *in* the
data, which is more use than takes quietly missing.

**The five probe different mechanisms, not different amounts of "off".** `stiff` is physical and
should surface as motor noise; `distracted` is attentional and should surface as clock noise —
§5.1's founding prediction on a new axis. `tired` and `amped` are the two ends of arousal. If
they separate that way it is a result about mechanism; if they all simply widen spread, that is
informative too.

**`usual` is not a claim to be well rested.** It is the unmarked case, which is what most
evenings are, and it is first in the list because both pickers default to the first option —
pressing through has to record an ordinary evening rather than recording nothing. A list rather
than free text because synonyms never pool: "knackered", "shattered" and "tired" would be three
conditions of one take each.

**`nil` still means *not declared*** — every take before this, and any surface that does not
ask. Folding it into `usual` would erase the difference between saying nothing and saying
nothing was wrong. Same distinction as M14's `nil` rung, for the same reason.

Nothing reads it yet. Fifth time this project has stored a field ahead of the analysis that
needs it (R6.3), and the reason is unchanged: a sitting recorded without its state can never be
asked about afterwards.

#### What it says about the roadmap

§7.23 step 2 held everything but the density constant on purpose, so rungs stay comparable.
That is exactly what makes them hard to tell apart, and the tension is now a live report rather
than a prediction. **M19 (musical depth) has earned a move up the roadmap**, and M15 is part of
the answer: straight, swing and reggae are unmistakably different in a way that quarters against
eighths over one skeleton is not.

---

## 7.24 M15 — the feels

§7.13's largest measurement change since M2: every style in the stated goal moves the *target*
rather than the tolerance. Matching swing against an even grid reports **style as error**, and
does it with numbers that stay entirely plausible — §5.3's sign inversion in a costume that is
much harder to notice.

### The blast radius is far smaller than it looks

Between them, `Grid.interval`, `nearestIndex(to:)` and `time(ofIndex:)` have **one consumer** —
`Matching`. Everything else reads `beatInterval` or does index arithmetic. So the grid can keep
integer indices and a uniform beat while only the index → time mapping gains an offset, and
`TimingReport`, `MusicalContent`, `DropoutAnalysis`, `FormAnalysis`, `JamAnalysis` and every
stored type are untouched.

### Swing ratio consistency is not a measurable quantity

§7.13 says *"consistency of that ratio is the skill, in the same way SD rather than bias is the
skill for straight time."* The instinct is right and **the unit is wrong**. Ratio relates to
offbeat phase by `r = φ/(1−φ)`, so `dr/dφ = 1/(1−φ)²`:

| ratio | phase | dr/dφ | ratio SD from measurement noise **alone** |
|---|---|---|---|
| 1.0 | 0.500 | 4.0 | 0.13 |
| 1.5 | 0.600 | 6.2 | 0.21 |
| 2.0 | 0.667 | 9.0 | 0.30 |
| 3.0 | 0.750 | 16.0 | 0.54 |

At this player's 20.1 ms spread, identical physical steadiness reports as a ratio SD that
**quadruples** between r=1 and r=3. Someone who tightened up while swinging harder would look
worse. That is §7.23 step 3b's mistake — a derived unit that is not comparable across the axis
it varies on — and this time it is caught before it ships.

**So consistency is offbeat phase spread in milliseconds**: the same quantity, the same units
and the same precision as every other spread the app reports, directly comparable to the
*downbeat's* spread in the same take. The ratio is reported as a derived mean with an interval,
and never as a spread.

### Steps

| | Delivers |
|---|---|
| 0 ✅ | Live ladder run — chain verified end to end |
| 0b ✅ | What that run exposed: the count-in states the rung, the ladder starts at eighths, a sitting can declare its state |
| 1 ✅ | `Feel` as pure arithmetic, and storage for it — written and unread |
| 2 ✅ | `Grid` and `Matching` gain the feel; `interval` retired; **straight bit-for-bit identical over every stored take** |
| 3 ✅ | `SwingReport`: ratio as a derived mean, consistency as offbeat spread |
| 4 ✅ | Backings per feel, and `render` so a feel is heard before it is promoted |
| 5 ✅ | The jam gains a feel, both surfaces. The continuation drill refuses one. |
| 6 ✅ | Offbeat drill — ska and reggae |
| 7 ✅ | The first swung takes, and the grid that was not reaching the app |
| 8 ✅ | The first offbeat take, and the three stored paths the drill did not reach |

### Step 1, as built

**One number, and straight is not a special case.** A feel is the long-to-short ratio of the
divided beat, and a ratio of 1 *is* straight — long and short are equal. The identity falls out
of the arithmetic instead of being handled separately, so no code path needs an `if straight`
and every straight take stays exactly what it was. Ten tests.

**Swing applies to the finest binary division and nothing else.** Swung eighths delay the
off-eighth; swung sixteenths delay the second of each pair while the **eighths stay put**;
triplets are the division swing borrows from, so a triplet rung is always straight — "swung
triplets" is a division of a division nobody plays.

**Ska and reggae are deliberately not feels.** They put the emphasis on the offbeat, but the
offbeat is still at half the beat: the grid stays straight and what changes is which points the
player is asked to hit and what the band plays underneath. That is a drill, not a grid, and
deciding it now keeps `Feel` down to one parameter.

**The ceiling agrees with M14, which is the check that matters.** `Feel.maximumBpm` derives from
the *shortest* gap rather than an even one. At a ratio of 1 it reproduces each rung's own
ceiling exactly — 400 / 199 / 133 / 100 — because at a ratio of 1 it *is* the rung. At 2:1,
eighths resolve like triplets (133 BPM), since the short half of a swung pair is a third of the
beat. Two derivations agreeing rather than merely coexisting.

**Storage: `swingRatio` on jam and continuation takes, `nil` meaning straight.** That reading is
honest here in a way it was not for `rung`, where `nil` means *no rung was prescribed* and
emphatically not quarters. A ratio of 1 is the identity and every take on record was played
against an even grid, so an absent value reads as straight without inventing anything. Straight
writes nothing, so no stored take's JSON moves.

Not on the tempo or recall drills: those produce a pulse rather than a division, and if either
ever gains a feel nothing is lost by adding it then — every take before it genuinely was
straight. That is the one case where R6.3's "store it before you need it" does not bind, and the
reason is the identity again.

**A stale build wasted a debugging round**, in precisely the way §7.23 step 0 recorded: two
stored structs changed layout while the test objects were still compiled against the old ones,
and two `SessionRunner` tests failed on logic that `git diff` showed to be untouched. It
vanished under `swift package clean`. The tell is unchanged code failing — worth reaching for
the clean build before the debugger.

### Step 2, as built — the grid gains a feel

`Grid` carries a `Feel`, `time(ofIndex:)` applies its phases, `nearestIndex(to:)` searches
instead of dividing, and `interval` is gone. Steps 2 and 3 landed together because they had to:
`Matching` was the thing consuming `interval`, so retiring it and teaching the matcher about
uneven spacing is one change, not two.

**Indices stay uniform; only their times move.** It would have been possible to express a feel
by indexing the grid unevenly. Not doing that is what keeps the change contained — index `n` is
still the `n`th subdivision, `phase(ofIndex:)` is still a modulo, and everything downstream of
matching works in indices. A feel reaches `Matching` and stops there.

**`interval` is retired rather than extended.** Under a feel the grid has no single spacing, so
a property claiming one becomes a lie the moment swing arrives. `gap(around:)` replaces it and
asks about a *particular* point. Killing it cost four call sites and was cheaper than letting a
second meaning grow around it — which is the mistake §7.23 made four times over "how finely we
divide the beat".

**The window is symmetric on the smaller adjacent gap.** A window reaching 40% of each
neighbouring gap would be wider on the long side of a swung pair, capture more late outliers
than early ones, and **pull the mean late** — a bias rather than a lost note. Symmetric costs a
little capture and biases nothing, and it also guarantees adjacent windows stay disjoint: each
half-width is at most 40% of the gap it sits in, so two together span at most 80% of the
distance between their points. `Matching`'s precondition has always asserted disjointness; now
it is true for a reason rather than by construction. A test checks it at every ratio.

#### The regression gate, and what it actually showed

Written and run **before** the change, against arithmetic stated longhand rather than against
`Grid`'s new implementation — a test that asked the new code whether it agreed with itself would
pass through any mistake it made consistently. Every grid point, every `nearestIndex` over 400
random offsets per tempo and rung, and every reported number over the degenerate corpus.

Then the real corpus: `review list`, six individual takes, `review dropout`, `review interval`,
`review trend` and `selftest`, captured before and diffed after. **All six byte-identical.**

#### The trap, and the number it produces

The failure this step exists to prevent is not a crash. It is style reported as error, and the
first version of the test assumed swung offbeats would at least be *discarded* by a straight
grid. **They are not**, and that is what makes it dangerous: at 100 BPM a 2:1 offbeat sits 400 ms
into the beat, only 100 ms past the straight eighth, and the window is ±120 ms. So every note
matches, the off-grid rate stays at zero, and a player swinging *perfectly* reads as **dragging
50 ms with a 50 ms spread** — worse than any real take in this project's history and entirely
plausible on the page, with nothing anywhere to flag it. That is now a test.

#### Two process notes

**The blast radius was two consumers, not one.** §7.24 above says `interval` had a single
consumer. It had two — `ProducedInterval` was the other, and it was missing from the survey
because the grep that produced that claim filtered out filenames containing "Interval" to
suppress noise. A filter that hides real hits is §7.20 finding 5 in a new costume: the
force-unwrap rule that excluded lines containing a quote and so missed five violations.

**A stale build cost a second debugging round**, after already costing one in step 1. Both times
a stored property changed on a shared type — `swingRatio` then `feel` — leaving test objects
compiled against the old layout, and both times the tell was the same: tests failing on code
`git diff` showed to be untouched. It is now in `AGENT.md` next to the build commands rather
than only in this section.

### Step 3, as built — swing measured as placement, not as a ratio of intervals

`SwingAnalysis`, and a `Dividing …` block in `review <n>` whenever a take has enough
off-division playing to support one. Thirteen tests.

**The ratio is derived and never measured per pair.** A swung note's produced phase is where the
feel expected it plus how far it actually landed from there, as a fraction of the *pair's* span;
the ratio is `φ/(1−φ)` of the mean. Its interval comes from a moving-block bootstrap on the
offbeat asynchronies, transformed through the same monotonic map — bootstrapping the ratio
directly would resample a quantity whose scale changes across its own range.

**Consistency is the swung note's spread in milliseconds**, printed beside the on-division
spread from the same take so the two can be read against each other. That comparison is the
clock/motor question on a new axis: is the pulse steadier than the placement inside it?

The `dr/dφ` argument is now a test rather than only a paragraph. Two planted players with
*identical* physical steadiness, one straight and one at 3:1, must report the same consistency —
and the test also computes what the rejected unit would have said, which is that the deep
swinger is **3.5× worse** for no reason he could hear or change.

**It answers a question on takes that already exist**: a player asked for straight eighths who
is quietly swinging them. Nothing in the app could ask that before.

#### The threshold the readout found

Wiring it up immediately exposed one that reasoning had not. A free jam with **12 notes off the
division against 117 on it** reported *"you swing each eighth 1.4:1"* with an interval excluding
even — a confident statement about a feel, computed from twelve incidental grace notes. Twelve
is comfortably enough for a bootstrap and nowhere near enough to be a division.

So the count guard rose to 24 and gained a companion: off-division notes must be at least **half
as many as on-division ones**. A player genuinely dividing the unit produces roughly one of each,
while an ornamenting one produces a tenth. Both guards are needed — the count alone passed the
take that prompted this.

**No take on record qualified when this shipped**, which was the correct answer and consistent
with step 3b: at the time 82.4% of every matched note sat a beat from the last, and 78.4% of
every free-jam note still does. Step 7's swung takes are the first that qualify. The readout becomes answerable when a
prescribed eighths rung is actually played, which is what step 5 schedules.

#### Also worth recording

The headline names *what* is being divided — "the beat" at eighths, "each eighth" at sixteenths.
Every take on record is scored at sixteenths, so without that the readout would say "the beat"
while measuring swung sixteenths, which is a different question with the same words.

`review list`, `review dropout`, `review interval`, `review trend` and `selftest` are all still
byte-identical to the pre-M15 baseline.

### Step 4, as built — the band swings too

**A warp of time, not a property of hits.** A swung pattern is the same pattern: hits keep their
integer step positions and the `Sequencer` moves *when those steps happen*. `Pattern` stays on a
uniform grid, bar and beat lines do not move — which the count-in handover and the analysis
window both depend on — and a sixteenth ornament inside a swung eighth pair moves with its pair
rather than needing a rule of its own.

Still index arithmetic (R2.2): beat and step-within-beat come from integer division of the
global step, so nothing accumulates however long a take runs.

#### The two descriptions of one feel, and the test that pins them

`Feel` tells the analysis where to expect a note; `Swing` tells the sequencer when to play one.
They cannot be the same type, because `GrooveCore` depends on nothing — not even `TimingCore`
(R1.1.3) — and they cannot be defined in terms of each other for the same reason.

That is a hazard rather than an inconvenience. **A groove swinging at 2:1 while the grid scored
at 1.5:1 would teach one feel and measure another**, produce a large stable asynchrony, and look
exactly like a player who drags. Nothing on screen would distinguish it from a real finding.

So `JamConfig.swing` is the single conversion point, and `SwingAgreementTests` pins the two
derivations to the sample: every subdivision of every beat, at five ratios, on both step
resolutions the ladder uses. Drifting one side by 5% fails **98 assertions**. That file is the
only thing standing between the two derivations and a silent disagreement, and it says so.

#### Rendered, because a feel is judged by ear or not at all

`render` gains swung eighths at 1.5 and 2.0 and swung sixteenths at 1.5, beside the straight
rungs. §7.23's rule — do not promote onto a rung nobody has heard — applies at least as strongly
to a feel: a step list cannot say whether 1.5:1 sounds like a shuffle or like a mistake.

The ceiling in that readout now comes from the feel rather than the rung alone, because the short
half of a swung pair is shorter than an even division and binds sooner.

**The audio was checked rather than assumed.** The swung renders differ from the straight one
from exactly 0.300 s — where the straight offbeat sits and the swung one has moved off it. Worth
recording that the first check *appeared* to show swing never reaching the audio, and the fault
was an onset detector firing on energy tripling, which never happens after the first hit of a
bar. A broken probe reporting a defect that is not there costs as much as missing one.

Whether these are *playable* is still a live-run question and always was.

### Step 5, as built — and the two places a feel must not go

`JamPlan` and `JamConfig` carry a feel, the runner passes it through, instructions come from it
(R3.6), and both surfaces can set it. Thirteen tests, all reachable without an audio device.

#### Swing breaks Wing–Kristofferson, so the continuation drill refuses it

This was going to be a scoping judgement and turned out to be a measurement. The decomposition
assumes an isochronous series; swing makes the intervals alternate **by design**. Worse, the
isochrony gate *passes* them — at 2:1 the intervals are 400 and 200 ms, and both sit inside
0.6–1.6× of their own 300 ms median — so nothing upstream objects.

The alternation then lands entirely in the lag-1 autocovariance, which is exactly where motor
variance is derived from. On a planted 12 ms clock and 8 ms motor:

| series | reported clock | reported motor |
|---|---|---|
| straight eighths | 9.0 ms | 7.7 ms |
| swung 2:1 eighths | **negative variance** | **99.7 ms** |

A twelvefold error, reported confidently, by a drill that looked like it ran fine. `DropoutConfig`
now refuses a non-straight feel in `validate()` with that reason attached. Making it work needs
the decomposition to operate on *pairs* rather than intervals, which is different analysis and
not something M15 needs.

#### A swung take has no interval, so it leaves the interval axis

`IntervalObservation` assumes an even division. At 2:1 the notes alternate 400 and 200 ms, so the
nominal 300 describes nothing that was played — which is §7.23 step 3's mistake exactly, where
the grid a take was *scored* on stood in for the task it performed. `intervalObservations` filters
swung takes out rather than averaging them onto the axis.

Feel joins tempo and rung as a confound axis in the trend grouping and the comparability notes.

#### The planner still schedules nothing swung

**A feel nobody has heard is a feel the planner must not promote onto.** §7.23 made that a rule
for rungs; whether 1.5:1 reads as a shuffle or as a mistake is even less answerable from a step
list. Swing is hand-selected until a swung take exists in the history, at which point the same
one-step promotion argument that governs rungs can govern feels. A test asserts every planned jam
block is straight at every session length.

#### Instructions, because the straight text contradicts a swung take

The straight text says *"aim every note at a beat or an off-beat"* and warns against playing
between them — which is precisely what a swung offbeat does. Handing a swung take that text would
tell the player their own task is a mistake, which is §6.1 and §7.17's defect a third time. A
swung rung gets text that says the hat is swinging with them and that straightening up lands
off-grid rather than counting as early.

#### Two process notes

**I started a real take from the shell.** Checking the new argument parsing with `jam 100 8 test
eighths 2.5` against a *stale* binary — the build had failed on a name collision — left the old
binary sitting at its `Ready?` prompt for ten minutes. Nothing was recorded and no audio played,
but it is the §7.22 `DrillConfigTests` mistake in a new place: **anything that verifies a
command's argument handling must go through the parse and validate functions, never the command.**
Every assertion in `FeelWiringTests` does.

**A stale build cost a third debugging round**, this time surfacing as a segfault mid-suite plus a
failure on untouched code. Same cause each time — a stored property added to a shared type. It is
documented in `AGENT.md`; the lesson from the third instance is to clean *proactively* after such
a change rather than waiting for a confusing failure to prompt it.

#### The renders sounded straight, and the timing was right the whole time

The first swung backings came back from the player as *"they do not have that swing feel, sounds
like straight time"*. The timing was exact — hats at 0.000, 0.400, 0.600, 1.000 for 2:1 at
100 BPM, and near-silent at the straight 0.300. **The fault was voicing.**

| | off-beat against the framework |
|---|---|
| straight backing (for reference) | −8.8 dB |
| swung, as first shipped | **−7.9 dB** |
| after | **−2.1 dB**, uniform across all four positions |

With the kick on 1 and 3 and the snare on 2 and 4, every loud event sat on a rigidly even 600 ms
grid, and the only thing carrying the feel was a hi-hat 8 dB down. The ear locks to the even
framework and hears the displaced hats as *slightly loose* rather than as a shuffle. §7.13 said
backings per feel; the timing warp was half of that and the groove was the other half.

**Three attempts, and the first two were reasoning rather than measuring:**

1. Ghost snare before each backbeat, plus authentic ride accents — strong on the beat, light off
   it. **−7.5 dB: almost nothing.** The accent pattern *reinforced* the even framework, which is
   the thing being fought, and the ghosts marked only two of the four swung positions.
2. Kick and snare back to 70, hats to the top of the range. −5.0 dB, and now the marked and
   unmarked halves of the bar felt different — one half shuffling, the next reading straight.
   Measurably better and musically worse.
3. A ghost on **every** swung position. −2.1 dB and uniform.

The constraint that forced the framework down is measurable rather than aesthetic: the synth's
hat peaks about **2.3× below its kick**, and velocity 127 buys only 1.27× over 100. Velocity on
the hat alone cannot close the gap.

**A 4:3 option was dropped from the picker.** At 100 BPM it sits 20 ms from straight, and the
player could not distinguish it from either neighbour. Three choices — straight, 3:2, 2:1 — are
each audibly distinct. The ratio stays continuous in the model, because measuring what he
actually produces needs it; only the offered choices are coarse.

**Still unverified: whether it now reads as a shuffle.** The measurement says the swung note is
no longer buried; only an ear can say whether that is enough, and the planner still schedules
nothing swung until one has been played (R5.6).

### Step 6, as built — holding a position the band never plays

`offbeat [bpm] [bars] [level]`. A skank — a chop on every offbeat — with the downbeat removed a
step at a time: kick on 1 and 3, then kick on 1, then backbeat only, then nothing on a beat at
all. Nineteen tests.

**Not a feel, and that is why it is a drill.** An offbeat sits at half the beat, exactly where it
always did, so the grid is straight and `Feel` has nothing to say about it (§7.24 step 1). What
changes is which points the player is asked to hit and how much the band states underneath —
the same ladder shape as `DropoutLevel` turned through ninety degrees, removing the *downbeat*
rather than the *band*.

#### Two failures, kept apart

A player can be a little early or late on the offbeat — ordinary placement error, in
milliseconds. Or they can **slip onto the beat**, which is not a worse version of the same thing.
The feel has inverted, and every note afterwards is right on a grid point, just the wrong one.

Pooling them would report a lost feel as an *excellent* take, because a slipped player is dead on
the beat. A test plants exactly that: notes on the downbeat with a 4 ms spread, which placement
alone would call the tightest take in the dataset, and requires the report to call it slipped.
This is `FormAnalysis`'s split — whole bars off the phrase against milliseconds off the bar line —
arriving in a new place for the same reason.

The threshold is two thirds on the offbeat, because a player holding the feel puts essentially
everything there and one who has flipped puts essentially nothing. The middle is oscillation,
which is its own state rather than poor placement.

**Nothing is earned by a slipped take.** Promotion needs the feel held, above 90% on the offbeat
and inside a spread ceiling — otherwise the next level measures a flip rather than a placement.

#### The marker at the hardest level is not a concession

With nothing on a beat, a player can hear their own chop *as* the downbeat. Once that flips it
stays flipped, and the take then measures a phase error that happened in bar one rather than
anything about placement. A kick at the top of each phrase bounds that to a single phrase, and it
is what a real band does anyway. It can be switched off, and a test covers both.

#### Storage

A jam variant rather than a fifth stored type: same capture, same grid, same fields, and only the
task and the backing differ — exactly the shape the experiment arms already have. `offbeatLevel`
is optional on `JamSession`, so every take on record still decodes.

The grid is forced to eighths whatever else is set. On a finer one a stray sixteenth would be
neither the beat nor the offbeat, and letting it count as either would flatter the share that
decides whether the feel was held.

#### A test that crashed the suite

`testEachLevelStatesNoMoreOfTheBeatThanTheOneBefore` seeded its running comparison with
`Int.max` and then computed `previous + 1` — an overflow trap, which surfaced as a signal-4
crash **spliced into another bundle's output** because the two test targets run in parallel. It
passed when filtered to its own class and killed the run otherwise. Worth recording: a crash
attributed to the test that happens to be printing is not necessarily the test that crashed.

### Step 7 — the first swung takes, and the defect they found

6 August, 03:53 and 03:56, both tagged `tired`: 64 bars of eighths at 2:1 and at 3:2. **The first
live data M15 has ever had, and it found a defect nothing in the suite could.**

#### What it reported, and why every number was wrong

| | as reported | after the fix |
|---|---|---|
| mean | **+22.3 ms, dragging** | −16.6 ms, rushing |
| spread | **54.0 ms** | 28.7 ms |
| r₁ | **−0.52, "chasing the click"** | +0.49, drifting |
| headline | *"You're chasing the click… this is what focusing harder does"* | — |

That r₁ would have been the **first negative reading in the project's history**, from a player who
has been +0.13 to +0.47 across twenty-seven takes, and it directly contradicts §5.1's founding
claim. The spread was more than double anything ever recorded. Both were artefacts.

The tell was in the readout itself: *"Asked for 1:1 and played about 1.6:1"*, on a take stored
with `swingRatio = 2`. The grid was straight.

#### The gap

`Grid` gained a feel in step 2 and both places that build one in the running app kept their old
call: `JamAnalysis.reduce` for a live take, `SessionStore.reconstruct` for a review. Every swung
take was therefore scored against an even grid, live *and* on every recompute.

Step 2's tests did not catch it because **every one of them built its grid inside the test**. The
suite proved a swung grid places notes correctly, that a swung player on one scores as perfect,
and that the same player on a straight grid reads as badly dragging — it never asked whether the
app hands the grid a feel at all. `LESSONS.md` shape 1, and the fifth instance on this project:
the path under test was not the path that ships.

It is also shape 9 in the same breath — a constant that happens to match. `Grid`'s feel parameter
defaults to straight, so both call sites compiled unchanged and were correct for every take
recorded before M15.

`FeelReachesTheGridTests` closes it from both ends, and reverting the storage half fails three
assertions. The defect's own signature is now a test: a perfectly swung player on a straight grid
must read as 50 ms of drag with a 50 ms spread and **nothing flagged**.

#### What the takes say, now they are scored properly

| asked | produced | interval | offbeat spread | on-division spread | notes |
|---|---|---|---|---|---|
| 2:1 | **1.76:1** [1.71, 1.83] | — | 30.0 ms | 27.5 ms | 239 / 248 |
| 3:2 | **1.57:1** [1.52, 1.62] | — | 33.5 ms | 34.4 ms | 249 / 254 |

Both takes swing, both land close to what was asked, and **the two are separated by their
intervals** — 1.76 against 1.57, with non-overlapping intervals. The measurement can tell 3:2
from 2:1 even though the player reported the two backings as hard to distinguish by ear.

Read no further into these than that. Both were played at four in the morning, tagged `tired`,
at a task attempted for the first time; the spreads (30 and 34 ms) are well above his 22 ms
baseline and that is exactly what a new task played exhausted should look like. **What they
establish is that the machinery works, not anything about the player.**

One thing worth noting rather than concluding: at 2:1 he played *straighter* than asked (1.76),
and at 3:2 he played *deeper* than asked (1.57 against 1.50). Both are pulled toward each other,
which is what a player converging on their own natural swing would look like — and is exactly the
question a preregistered design would have to ask properly.

#### And it extended step 3b

The swung takes produce genuinely short intervals — the 200 ms and 240 ms short halves of 2:1 and
3:2 pairs at 100 BPM — so the produced-interval range now runs 200 ms to 1200 ms, a sixfold
spread. **The finding holds and strengthens**: absolute spread −0.17 ms per 100 ms
[−1.94, +0.59], relative −1.08 points and real.

### Step 8 — the first offbeat take, and the three places it did not reach

6 August, 04:32, level 0, 32 bars — the first offbeat take ever recorded, and like step 7 it
found what no test could. The take itself is the drill working: **26 of 112 notes on the offbeat,
86 on the beat, share 0.23 — slipped**, which is the exact failure §7.24 step 6 built the
separation for. The player lost the feel and the analysis said so, live.

Nothing that read the take back could say it. The drill was wired into the live console path and
nowhere else, so the moment the take was saved its own result stopped existing:

| Surface | What it said about a slipped skank |
|---|---|
| `review 30` | *"You sit consistently ahead of the beat — steady, just early."* No offbeat block. |
| `review trend` | Pooled it with 21 free jams at 100 BPM |
| The planner | Could not have run it at all |

**This is step 7 again, one step later.** There the grid the *test* built carried a feel and the
grid the *app* built did not; here the readout the *live path* produced carried the drill and the
readout every *stored* path produced did not. `LESSONS.md` shape 1, sixth instance on this
project, and the tell was the same both times: the code that ships was never the code under test.

#### The review was silent because nothing called the accessor

`JamSession.offbeatReport()` existed, was correct, and had **zero callers in `Sources` and zero
in `Tests`**. It was written in step 6 alongside the storage and then never wired, so the offbeat
verdict was computed once at take time and never recomputed — the only readout in the project
that disobeys R3.1. `reviewTake` now builds an `OffbeatContext` through it, so the review
re-derives the slip from raw taps like every other number.

#### The swing block would have fired on a *held* take, and that is the wrong way round

`reportTiming` ran `reportSwing` on every jam. On the eighths grid the offbeat drill forces,
every note the skank asks for sits "off the division", so `SwingAnalysis`'s share guard —
off-division notes against on-division ones — is cleared more comfortably the **better** the feel
is held. A held skank with three stray notes on the beat reports *"You swing the beat about
1.1:1, and place the swung note to 0.0 ms"*: a confident ratio for a player dividing nothing.

The one real take escaped it only by slipping so badly (26 against 86) that the share fell below
0.5 and the guard withheld the number. So the readout was silent on the take that went wrong and
would have spoken on the first take that went right. That is §7.24's own trap in a new place — a
number that stays entirely plausible while describing the wrong question.

The two blocks are now mutually exclusive, and the choice is **returned by the branch that
prints it** rather than computed beside it. A value derived alongside the branch agrees with a
branch that has been changed underneath it, which is how step 7's defect survived a suite that
tested swung grids thoroughly.

#### The trend pooled it, and it had already moved a verdict

`GroupKey` split on tempo, rung and — since step 5 — feel. `offbeatLevel` arrived in step 6 and
was not added, so a take storing no rung and no swing keyed identically to a free jam. Verified
on the real data: the take sat inside *"Jams at 100 BPM"* with 21 free jams, and it is not a
subtle passenger. Its 48.4 ms spread is the widest in the project's history.

| "Jams at 100 BPM" | with the offbeat take pooled in | split out |
|---|---|---|
| spread (SD) | +0.30/take [−0.20, +0.83] flat | −0.01/take [−0.26, +0.18] flat |
| \|bias\| | **+0.29/take [+0.01, +0.62] worsening** | +0.28/take [−0.03, +0.62] flat |

**Retracted: the group's bias was never worsening.** One take of a different drill, over a
different backing, carried the interval off zero. The mixed-backings warning did fire — R3.4 was
doing its job — but a warning beside a verdict is not the same as not computing the verdict, and
§7.23 trap 3 gave rung and feel their own *group* for exactly this reason. Naming a confound is
the floor, not the fix.

#### The planner would have run the wrong drill

`JamPlan.offbeatLevel` existed and `DrillInstructions.forBlock` already read it, so a planned
offbeat block would have printed the skank's instructions and played an ordinary jam over
`jamBacking`, scored on a sixteenth grid. Three of four pieces shipped wired; `SessionRunner`
built its `JamConfig` with `rung:` and `feel:` only. Nothing caught it because the decision lived
inside a function that opens an audio device — `LESSONS.md` shape 1's own guard, unheeded — so it
is now `SessionRunner.jamConfig(for:)` and a test asserts the level reaches the backing and the
grid. Latent rather than live: the planner never sets the field, which is why the take that found
everything else could not find this.

#### What the suite gained

Eleven tests, and each fix was verified by reverting it and watching the assertion fail — the
`Performance` generator gained `beatPhase` and `slipRate` so a skank, held or slipped, is a
shared pathology rather than a fixture in one file. `slipRate > 0` short-circuits before the
random draw so no existing test's planted taps move.

**The one line still uncovered** is `reviewTake` passing the context into `reportTiming`: it
feeds `print`, and stdout capture is not worth building for it. `offbeat:` lost its default value
instead, so a new readout cannot silently omit an offbeat take's result — a compiler guard rather
than a test, and worth saying so rather than implying coverage.

### What this cannot verify

The clock bridge is untouched, so `selftest` remains the arbiter of the maths. But the ladder
changes what the *backing* plays, and backings have no tests beyond pattern structure — whether
a sixteenth-note groove is playable-along-to at all is a live-run question (R5.6). The first rung
above eighths should not be promoted by the planner until one session has been played on it.

Step 3b is measured from free playing only. It cannot say what a *prescribed* rung does, and the
tempo half of the axis remains unmeasured — one tempo is well sampled, one evening covers 110,
and one take covers 120.

---

## 7.25 A fraction gate cannot protect a variance

Found by reading `review dropout` while re-deriving figures for a documentation pass, which is
worth recording on its own: **nothing was looking for this, and no test could have been.**

| 5 Aug, 18:23 · 4+8×8 | clock | motor |
|---|---|---|
| as reported | **193.5 ms** | 71.3 ms |
| every other usable take on record | 11.4 – 40.7 ms | 4.2 – 20.9 ms |

At 100 BPM a clock SD of 193.5 ms is a third of a beat, one sigma — a player whose internal
period wanders by two hundred milliseconds could not have produced the 97 BPM the same take
reports. The number was displayed with `splitIsReliable` **true**.

### What the raw taps said

Eight trials, none discarded, all inside the isochrony gate. The intervals:

```
trial 4:  670,612,668,604,642,606,624,635,727,2592,608,590,594,...
trial 5:  883,323,3070,586,581,600,588,589,596,619,603,638,607,...
trial 6:  ...,700,1455,592,674,665,601,1154,662
```

Nine intervals out of 232 — **4%** — are pauses and dropped notes. A 3070 ms interval at a 600 ms
beat is five beats of nothing. Per trial:

| trial | intervals | odd | share of count | **share of squared error** |
|---|---|---|---|---|
| 1 | 30 | 1 | 3% | **76%** |
| 3 | 31 | 1 | 3% | **72%** |
| 4 | 27 | 1 | 4% | **99%** |
| 5 | 27 | 2 | 7% | **99%** |
| 6 | 27 | 2 | 7% | **95%** |

### The defect is the shape of the guard, not its threshold

`maxOddFraction` admits a trial with up to 25% of its intervals outside the 0.6–1.6× band. That
is the right question for *"was this silence a continuation attempt at all"* and the wrong guard
for what happens next, because Wing–Kristofferson is **quadratic in the residuals**. A fraction
gate counts an outlier once; the variance it is protecting counts it squared. Every take above
sailed through at 3–7%.

Tightening the fraction would not fix it and would throw away good trials. The exclusion belongs
where the violation is: a hesitation is not a noisy beat, it is the sequence **stopping and
starting again**, so the stretches either side are two continuation sequences rather than one
with a hole. `DropoutAnalysis.continuationRuns` splits at every out-of-band interval and
`WingKristofferson.decompose(trials:)` takes the runs unchanged — it already centres each trial
on its own mean and never takes a product across a boundary, which is exactly what a run needs.

Nothing new is invented: the band is the one the trial-level gate already uses, and the count of
what was broken out is reported (`brokenIntervals`, on the trial and on the report, and warned
in the readout). An exclusion nobody can see is indistinguishable from quietly dropping the data
that spoiled the answer.

The same contamination reached two more statistics off the same series, both fixed with it:
`unpacedIntervalSDms` is a spread, and `withinTrialDriftMsPerBeat` is a least-squares slope —
equally quadratic in an outlier, and a gap also breaks the x-axis it is fitted against, since
the intervals either side of a pause are not consecutive beats. The tempo readout is
deliberately **not** touched: it is built from medians, and the take that exposed all of this
reported its 97 BPM correctly throughout. Only the quadratic statistics were ever wrong.

### What it did to the corpus

Twelve stored takes, recomputed:

| | before | after |
|---|---|---|
| 5 Aug 18:23 (4+8×8) | 193.5 / 71.3 | **24.1 / 15.4** |
| 4 Aug 01:54 (4+8×8) | 40.7 / 20.9 | **29.6 / 9.6** |
| seven others | — | **identical to the decimal** |
| two already withheld (γ₁ > 0) | — | still withheld |

The second one matters as much as the first: 40.7 / 20.9 was quoted in `AGENT.md` as this
player's 8-bar figure, and it was inflated by one gap.

### What it did **not** do, which was the expectation going in

I predicted the trend's clock-SD verdict would collapse. It did not. `review trend` moved from
`+12.15/take [+0.84, +25.21]` to `+1.32/take [+0.64, +3.05]` — an order of magnitude smaller and
**still "worsening"**, because the interval still excludes zero.

That verdict is confounded, and by something this document already forbids: §7.7 says do not
pool across silence lengths, because a longer silence is a harder task. The nine usable takes
are 2, 4, 4, 4, 4, 4, 8, 8 and 16 bars, and the two 8-bar takes are the two highest clock
figures. `dropoutTrends` fits one line through all of them and prints a warning instead of
splitting, which is the same defect §7.24 step 8 fixed for jams — a confound named rather than
separated. **Left standing deliberately**, with the fix queued: it is a different change, in a
different function, and folding it in here would put two arguments in one commit.

Until it is split, the continuation clock-SD trend should not be read.

---

## 7.26 M16 — the decisions, and what forcing a level actually costs

Settled with the player on 6 August, against twelve form takes. The design argument is in §7.13;
this section holds what the decisions imply for the code, and two things found while checking
them that change what one of the answers means.

### The two axes

| Axis | Ladder | What it removes | Needs M19 |
|---|---|---|---|
| **Where am I** (spatial) | 8 → 16 → 32 bar phrases at a fixed landmark level | Nothing; the span grows | **Yes** — no backing sustains 32 bars |
| **Landing cleanly** (temporal) | Levels 0 → 3 at a fixed 8-bar phrase | Landmarks, as now | No |

`formErrorBars` and `phaseErrorMs` are both already computed. The report treats the second as a
refinement of the first; the data says they move independently, so they become peers. That is
the third time this project has found a categorical failure and a magnitude failure needing
separation — `FormAnalysis`'s own original split, M15's slipping-versus-placement (§7.24 step 6),
and now this.

**One axis per sitting, chosen by the planner**, with a test that it never moves both at once.
The chooser needs both axes to exist, so it lands with the span ladder after M19.

### Level 3 is not locked, and never was

The premise going in was that the promotion gate is why level 3 has never run. Checked against
the code, that is only half true and the half that is false matters:

- The **app** offers every level — `SetupView`'s picker is over `FormLevel.allCases`.
- The **CLI** takes the level as an argument: `form 100 64 8 3`.
- The **planner** is the only thing that will not go there. `SessionPlan.swift`'s rule is
  `onFormRate >= 0.9 && !hasUnmarkedPhrases && level < 3`, and he is at 75%.

So level 3 has been one click away every evening since the drill was built. It has not run
because nothing ever *proposed* it, which is a different problem from a gate being too strict —
and it means "forcing" it is a planner change, not an unlocking.

### The trap: a probe silently becomes the new floor

The planner picks the next form level from the **last** form take. Its fallback is:

```swift
return SessionBlock(… FormPlan(… level: last.level) …,
    reason: "…stay at level N until it is above 90% with nothing unmarked.")
```

`last.level`, not the highest *earned* level. So one forced level-3 probe — however badly it
goes — becomes `last`, and every subsequent session plans level 3 and reports that he is staying
there until he clears 90%. **A probe would be read as a rung**, and the ladder's floor would have
moved on the strength of a take that was explicitly not a promotion.

This is the same shape as §7.24 step 8's trend pooling: a take of a different kind entering a
series that assumes every member is the same kind. It is worth stating that the trap is not a
reason to refuse the probe — the probe is a good idea — it is the reason the probe needs a name
in the data before it is run, not after.

**Mechanism: a `probe` case on `BlockRole`.** `SessionPlacement.role` is already stored as a raw
string precisely so a future role cannot make an old take undecodable (R6.1), so this is additive
and every take on record still reads. The planner then computes the earned level from non-probe
takes, and `review form` can show a probe without it looking like progress up the ladder.

The alternative — infer it from the level being above the earned one — is the flag-every-caller
defect of R3.3.1: three readouts would each have to remember the rule, and §7.20 finding 2 is
what happens when two of three do.

### The probe, as built — in the CLI, not in the planner

**The first version put the rule in the planner and that was the wrong place.** It proposed level
3 once the player had been held four takes at one level, which worked and was tested, and it was
still a testing affordance living in the business logic: a rule that changes what the app
recommends, built to get one reading. The planner's job is to decide what to practise, and it now
has an opinion about a level nobody earned.

So the rule is gone and the capability moved to where testing belongs. `--probe`, on any drill:

```sh
TimingSpike form 100 64 8 3 --probe
TimingSpike offbeat 100 32 3 --probe
TimingSpike jam 100 32 test sixteenths --probe
```

Level 3 was never locked — both surfaces have always offered it — so nothing new is reachable.
What is new is that the take is **recorded as a probe**, and that is the part that matters.

#### Why the marker is the whole feature

Without it, running the test take by hand walks straight into the trap the planner rule was
invented to dodge. The form rule picks the next level from the last take and `nextRung` promotes
one step from the highest rung ever played, so a level-3 form take or a sixteenths jam run for
curiosity becomes the ladder's new floor. Every later session then plans it and reports that the
player is staying there until they clear 90%. Reverting the storage wiring reproduces exactly
that.

`wasProbe` is stored on jam and form takes, optional so every take on record still decodes, and
absent means an ordinary take — which all of them were. It is the single source: `PlannerInput`
reads it when building both the form history and the ladder history, and `review form` marks a
probe `*` with a footnote so a level in the history that was never climbed to cannot read as
progress.

**Not a session role.** The draft used `BlockRole.probe` and a fabricated one-take placement, and
that would have fragmented `review cold`: sittings are inferred from 45-minute gaps between
takes, so a CLI probe carrying its own session id would split itself out of the sitting it was
actually played in while every other CLI take stayed grouped. One stored flag, no invented
session, and the enum case is gone rather than left dead.

#### The flag parser

`CommandFlags.parse` splits flags from positional arguments before anything reads them, so
`--probe` may sit anywhere on the line and every positional default keeps counting from zero. It
is a pure function for the usual reason — every drill command opens an audio device and waits, so
argument handling that lives inside one cannot be tested (§7.22, and §7.24 step 5, where checking
an argument started a real take from a shell).

**An unknown flag is refused, not ignored.** A mistyped `--porbe` that quietly ran an ordinary
take would record it as earned, which is the corruption the flag exists to prevent arriving
through a typo. The parse also happens *inside* the top-level `catch`: outside it, the refusal
arrived as a Swift crash dump rather than a sentence, which is how the first version shipped for
about a minute.

The GUI is untouched. A probe is a testing affordance, the app is for playing, and nothing about
this appears on a screen the player uses.

### What this does not settle

`markedPeriodStability` — how consistent the marked period was *within* a take — is still the
first thing to build, and still cheap: the mark times are stored, so it is computable
retroactively over all twelve takes. A player marking a steady 4 against an 8-bar setting has a
stable period at the wrong length; one marking 4, 7, 5, 8 has no period at all. The current data
cannot tell those apart, and `markedEveryBars` has been driving the planner on the assumption
that it can. It may still change the milestone's shape, which is why it comes before the ladders
rather than inside them.

---

## 7.27 Every trend is fitted over one task

The last section left a verdict standing that it had shown to be confounded, and this closes it.
Jams have been grouped since M7 — by tempo, then rung (§7.23), then feel (§7.24 step 5), then
offbeat level (§7.24 step 8). The other four drills **warned** instead, and the warnings made the
case themselves:

> *"mixed silence lengths — a longer silence is a harder task."*
> *"mixed levels — difficulty changed between takes, so a trend here reflects the ladder as much
> as you."*
> *"mixed wait lengths — a longer wait is a harder task."*

Each of those sentences is an argument for not fitting the line, printed immediately above the
line. **Naming a confound is R3.4; not computing a verdict across it is R3.5**, and the second is
what the jam trends have always done. A reader shown a verdict and a caveat has still been shown
a verdict.

### Two verdicts retracted

| | pooled | grouped |
|---|---|---|
| Continuation, clock SD | +1.32/take [+0.64, +3.05] **worsening** | +2.05 [−1.03, +4.85] flat, on the seven 4-bar takes |
| Form, on-form rate | −0.04/take [−0.07, −0.01] **worsening** | −0.01 [−0.15, +0.10] flat, at level 2 over 8-bar phrases |

Neither was the player. The continuation series ran 2, 4, 4, 4, 4, 8, 16, 16, 4, 8 bars of
silence and its two hardest takes landed late; the form series climbed levels 0 → 1 → 2, and
on-form rate falling as the landmarks are removed **is the drill working**. `review cold` reported
the same form verdict from the same cause and is not fixed here — see below.

After the change nothing in any drill trend is moving.

### What it cost, said plainly

Three groups out of eleven have the three points a fit needs. Splitting twelve continuation takes
four ways leaves most of them saying "1 usable point — need 3", and that is the honest answer
rather than a regression: those takes could not support a verdict before either, they were being
lent significance by takes of a different task. The cost is visible where it used to be invisible.

### The asymmetry that nearly split one task in two

Grouping the continuation drill by rung first produced *two* 8-bar groups — one keyed `nil`, one
keyed `quarters` — from takes recorded either side of M14. That is the opposite of §7.24 step 1's
rule for jams, and getting it right meant asking what the **player was told** rather than what the
field held: `DrillInstructions.dropout(rung:)` returns the same text for `nil` and for
`.quarters`, because this drill has demanded one note per beat in words since M6. So here an
absent rung really is quarters, and grouping them apart would have invented a distinction never
shown to anyone. A jam is the other way round — no rung means *play what you like*, which is a
different task. `LESSONS.md` shape 13, both directions in one codebase, decided by R3.6 rather
than by taste. There is a test asserting the two instruction texts are identical, so the day they
diverge the grouping stops being justified and says so.

### Two notes on method

**The tempo drill was fixed although it splits nothing today.** Every tempo take on record targets
100, so grouping changes its output not at all — and M14's ladder rotates tempo between sittings
by design, so the confound is scheduled rather than hypothetical. Three sites out of four is how
§7.20 finding 2 happened.

**A test crashed the run while this was being written**, in exactly the shape §7.24 step 6
recorded: `XCTAssertEqual` does not stop a test, so asserting a count and then subscripting turns
one failure into an index trap that kills every test after it. Found only because the revert-check
reported two passes and nothing else, which looked like the guards not firing. Suspect the probe
(`LESSONS.md` shape 16) — the guards were fine and the harness was lying.

### Not fixed here

`review cold` (`WarmUpAnalysis`) pools the same way: it reported form's cold start "worsening
−0.109/sitting" over takes spanning levels 0–2. It is a different function with a different
grouping problem — its unit is the *sitting*, and splitting by level would leave almost no
sitting with two comparable takes — so it needs a design decision rather than the same edit.
Recorded here so the next reader does not take that verdict at face value.

---

## 7.28 One list of what makes two takes a different task

`review tags` pools every take carrying a label and reports the condition's mean, spread and r₁.
`review conditions` compares two such pools. Both have to say when the takes inside them are not
the same task, and each kept its own list of what that means:

| | backing | tempo | device | rung | feel | offbeat level |
|---|---|---|---|---|---|---|
| `review tags` | yes | yes | yes | — | — | — |
| `review conditions` | yes | yes | yes | yes | yes | — |

The bottom-right corner is the one that was live. `tired` holds the two swung takes of §7.24
step 7 — one at 2:1, one at 3:2 — and the pooled summary printed their blended spread with no
warning at all, because feel was on the other list. An offbeat take tagged alongside jams would
have gone unremarked on both.

`TakeAxis.all` is the single list now and both readouts walk it. Each axis carries what stops
being comparable rather than only that something differs, because a reader told the pool mixes
feels still has to be told which number that ruins — so the pooled summary prints the consequence
under the warning.

**This is R3.4 and deliberately not R3.5.** §7.27 split the trends by task because the app chose
those parameters and a line fitted across them measures the change. A tag is a label the *player*
applied to whatever they were playing, so splitting `relaxed` into `relaxed at 100` and `relaxed
at 120` would answer a question nobody asked. Name the confound at the point of display and leave
the pool alone.

Detection is `TakeAxis.mixed(in:)` rather than a filter inside the print loop, for the usual
reason: a decision made inside something that prints is a decision no test can reach. The suite
walks `TakeAxis.all` and asserts each axis is seen by *both* readouts, so an axis added later is
covered without anyone remembering to add a case — and deleting the feel and offbeat entries
reproduces both original gaps.

---

## 7.29 M19 — musical depth

§7.13 asked for *"sectional arrangements with real dynamics, more styles, longer forms. No new
measurement."* That is right and it is not sufficient, because the thing being asked for —
**variety** — is the thing §2's invariant table names as having corrupted a finding: a changed
backing once produced a "real" 8 ms spread change that was partly just different music.

So the milestone is not "write more patterns". It is **make the music unbounded where nothing
longitudinal is read and byte-identical where it is, and make the difference structural rather
than something anyone has to remember.**

| Slot | Role | Music |
|---|---|---|
| Cold probe, benchmark jam, experiment arms | `cold`, `benchmark`, `experiment` | Frozen, for ever (R3.5) |
| Training blocks, closing jam, Play, free CLI jams | `training`, `closing`, none | Deep |

### Settled with the player, 6 August

- **Four styles to start**, with the framework built to take more — rock, motown/soul, funk,
  half-time — then one per sitting. A batch of ten is a batch nobody auditions properly.
- **The bass is rhythmic only** for now: root and fifth, locking with the kick. Harmony is not a
  smaller version of this problem, it is a different one — key, chord progression, voice leading,
  and what any of it means for a *timing* trainer — so it becomes **its own milestone** rather
  than being smuggled in as a parameter. The framework laid here has to accept it without rework:
  that is what `Hit.note` being optional and per-hit is for.
- **The closing jam rotates its style between sittings and keeps one seed within a sitting**, so
  an evening has a single musical identity and the next evening is new. Variety across sittings,
  an earworm inside one.

### Unbounded material from bounded authoring

Styles are authored — kick and snare skeleton, hat or ride behaviour, a bass figure, a fill
vocabulary, an intensity map. **Arrangements are generated** from `(style, seed, bars, intensity)`
using `GrooveCore`'s seeded RNG (R1.2.1), and **the seed is stored on the take**: `grooveName`
becomes `style@seed`. That is what makes the approach permissible rather than reckless — R1.2.2
holds, the exact backing is reconstructible from stored data for ever, `render` can reproduce any
take's music, and `TakeAxis` still sees two seeds of one style as honestly different music.

**Variation is in what fires and how hard, never in when.** The backing is the ruler the player
is measured against, so there is no jitter parameter, no groove template and no humanisation
anywhere in the generator. A hit's sample position comes from the grid and the feel and from
nothing else. It would sound better, which is exactly what makes it dangerous.

### Step 0, as built — the scoring grid stops being a property of the drums

```swift
return rung?.subdivisions ?? backing.arrangement.stepsPerBeat   // before
return rung?.subdivisions ?? Self.freePlayingSubdivisions       // after
```

**The grid a free jam was scored on was a property of the music.** `jamBacking` is programmed at
four steps per beat, so twenty-six of the thirty takes on record are analysed on a sixteenth grid
for that reason and no other. Step 1 re-voices every pattern onto a twenty-four-step grid so that
binary and ternary can share an arrangement — and that would have silently re-scored the entire
history.

This is `LESSONS.md` shape 10, one word with two meanings, **still live after §7.23 found and
fixed four instances of it**: the distinction between what content is *authored* at and what a
player is *scored* against was drawn for `LadderBackings` and never carried back to this
fallback. Four fixes and a doc comment about the distinction were not enough; the fifth instance
sat in the default branch of the same expression.

Fifteen readouts captured before and after — `review list`, `trend`, `interval`, `dropout`,
`feel`, `tags`, `form`, `cold`, `selftest` and six individual takes — are **byte-identical**,
which is the whole claim of this step.

#### No test can prove this one, and saying so is the point

Both quantities are 4 today. Reverting the change moves no observable value, so every assertion
in `FreePlayingGridTests` still passes against the defect — `LESSONS.md` shape 9, a constant that
happens to match, and the reason the first revert-check came back green and looked like success.

The real guard is therefore in `check.sh`: nothing in `TrainerKit` may read a pattern's
`stepsPerBeat` at all. `GrooveCore` must — it is the sequencer — so the rule is scoped to the
measurement layer, and comment lines are excluded so the doc comment explaining the rule does not
trip it. Verified by planting the old expression and watching the gate report FAIL (R5.7).

The tests hold the *value* rather than the decoupling, and they start proving the decoupling by
themselves the moment step 1 makes the two numbers differ.

### Step 1, as built — one grid, twenty-four steps to the beat

`Arrangement` required every section to share a step resolution, so a triplet section and a
straight one could never appear in the same piece of music. That was the format's hard limit on
depth, and it would have blocked M16.5's triplet skank, every shuffle style and any 12/8.

Sections are now **lifted** to `Pattern.commonStepsPerBeat` — twenty-four, the lowest common
multiple of 2, 3, 4, 6, 8 and 12 — and the precondition relaxes from *same resolution* to *same
beats per bar*, which is the constraint that actually matters because every drill counts phrases
in bars. Patterns are still **authored** at whatever reads naturally, sixteenths for rock and
twelfths for a shuffle, and `Arrangement` does the lifting. Nothing is transcribed by hand, so
nothing is mis-transcribed. `Sequencer` iterates hits rather than steps, so the finer grid costs
nothing to render.

#### The gate, and the probe that lied about it

Every hit of every pattern in the codebase, at three tempos and four feels — 27,744 comparisons —
lands on the **same sample** before and after the lift. All nineteen WAVs `render` produced at the
time — it writes 43 now, since styles and the per-voice kit files were added in steps 3–6 — are
byte-identical to the pre-change baseline.

Getting there took a wrong turn worth recording. The first gate was an audio hash, and it
reported two backings changed. They had not. **The probe changed between the baseline and the
comparison** — an expression in its frame count — so the two runs were not measuring the same
thing, and the "failure" was mine. Acting on it made things worse: restructuring `Sequencer` to
compute beat-plus-fraction instead of step-times-duration moved a *third* backing, and was
reverted.

`LESSONS.md` shape 16, suspect the probe, and shape 4's *capture the old output before the
change*, broken by the person who wrote the rule down two sections earlier. The hash was replaced
by comparing scheduled sample positions directly, which needs no baseline capture, is exact
rather than incidental, and is now a permanent test that fails 3,265 times on a one-step drift.

#### Four tests were proxies, and the lift found them

Updating expectations was not busywork. `testTheExistingJamBackingIsUntouched` asserted the
arrangement's step *resolution* as a stand-in for "the music every recorded take was played over
has not moved" — a proxy that would have passed had the lift been wrong, since the lift changes
resolution by design. It now schedules the whole arrangement and compares sample positions
against the authored patterns, which is the claim its name always made.
`testThreeRungsShareAStepResolution` became `testEveryRungShares…`: all four backings now report
the same resolution, so the trap it names is sharper than before.

#### Step 0 became provable

The two quantities separated. `FreePlayingGridTests` could only hold the *value* while both were
4; the free-playing grid is 4 and the arrangement is 24, so reverting step 0 now fails five
assertions outright instead of passing in silence. The `check.sh` grep stays — it is what covered
the window in between.

### What this cannot verify

### Step 2, as built — the band gets a bass, and the renders stop lying

`BackingVoice.bass`, `Hit.note`, and `BassSynth`. Drums alone cannot make something worth playing
over for half an hour; a figure locking with the kick is what gives a groove a contour to remember
and a second thing to place your own playing against.

**`DrumVoice` was renamed to `BackingVoice` first**, in its own commit. An enum called `DrumVoice`
with a `bass` case in it is `LESSONS.md` shape 10 arriving by choice rather than by accident, and
the rename was sixteen compiler-checked references while it was still cheap. `DrumKit` became
`BackingKit` for the same reason; `DrumSynth` kept its name because drums are what it synthesises.

**The note is per hit and optional**, which is the framework M25 needs: a chord is several hits at
one step with different notes, and nothing about the pattern format has to move when harmony
arrives. Putting the pitch on the *pattern* would have been simpler today and a rewrite later.

**Pitch does not reach the render callback.** R2.3 forbids allocating or synthesising there, so
the flat table the callback indexes became one slot per *sound* rather than per voice: nine drums
and one per bass note across E1–E3. The callback is unchanged. A hit whose sound was never
rendered is dropped rather than substituted — a wrong note played confidently is worse than a
missing one, and it would be wrong musically rather than visibly.

Writing that produced a real bug worth naming: the first version skipped such a hit with
`continue` *inside* the fill loop, which would have left a start time beside whichever sound and
gain the previous schedule had put at that index. Three parallel arrays read by index in a render
callback do not tolerate a hole. They are resolved and filtered before anything is written now.

**The level came from the gate, not from taste.** At the amplitude first written the demo peaked
at 1.14 and clipped 127 samples, because the bass lands *with* the kick by design and the two
stack. `render` already warned about exactly this. 0.40 leaves the demo at 0.93.

#### The renders were never reproducible, and the gate had been lying

Two consecutive runs of the same binary produced different bytes for some backings. `Pattern.make`
takes a dictionary of voice-to-steps, Swift seeds its hashing per process, so `flatMap` yielded
hits in a different order on every launch — and float addition is not associative, so two hits on
one sample summed to a value differing in its last bit. Against R1.2.2 outright, inaudible, and it
made **every byte-comparison gate in this milestone unreliable, including the one that certified
step 1**.

Found only because the bass demo made overlapping voices common enough to notice. `Pattern.make`
sorts its hits now, three consecutive renders agree, and a test builds the same pattern fifty
times and requires it identical.

One sample of one backing — `sixteenths-swung-1.5` — differs from the pre-M19 baseline by one
LSB, which is that fixed summation order landing on the other side of a rounding tie. Sorting a
list cannot change which hits it contains, and `CommonGridTests` compares sample positions
directly over 27,744 hits, so the *times* are provably unmoved. What changed is that from here
the same music renders to the same bytes, which was not true before this milestone started.

**Nothing frozen gained a bass.** `jamBacking` is the music every recorded take was played over
and R3.5 keeps it exactly as it is; `bassDemo` exists to be heard through `render` and is
scheduled by nothing. A test walks every frozen arrangement bar by bar and requires no bass hit
in any of them.


### Step 3, as built — a style is layers, and intensity is which of them play

A style is a set of **layers**: a repeating figure and the intensity at which it enters. Rock's
skeleton is a kick and a backbeat; eighths on the hat arrive at 1 with the bass; an open hat on
the "and" of four at 2; ghost snares at 3. Asking for a bar merges the layers that have entered.

**That shape is the whole discipline of this milestone in one place.** Intensity adds and removes
layers and never moves a hit, because the backing is the ruler the player is measured against —
so a loud bar is provably the quiet bar with more in it, and a test asserts every hit of a quieter
intensity survives into a louder one. There is no jitter parameter anywhere and there must never
be one.

Layers cycle at their own length, so a one-bar hat and a two-bar bass figure sit in one style and
repeat against each other. That is what makes a groove stop being a loop after four bars without
anything generative being involved yet.

#### Two styles, chosen to differ structurally

`rock` is hat-led, medium density, a bass that answers on the fifth. `motown` fills the bar —
sixteenths, a clap doubling the backbeat, a walking bass — and is marked `busy`. Two styles that
differed only cosmetically would have proved nothing about the format.

Three fields exist for milestones that have not started, and each costs a line now against a
rewrite later:

| Field | For |
|---|---|
| `playerVoices` | M20 inverts the roles; drum mode mutes exactly these and the player supplies them |
| `density` | M21 and M24 need to ask for something that leaves the mid-range clear |
| `intensityRange`, 0–3 | M17's adaptive difficulty gets one scale rather than one per drill |

`carriesBass` is derived from the layers rather than declared, so it cannot drift from what the
style actually plays.

#### The headroom test, and where it belongs

Motown clipped 68 samples the first time it was rendered: its clap doubles the backbeat, and a
mix goes hot because voices *stack*, not because one is loud. `render` warns about it, which
helps only if somebody reads the warning — so it is a test.

The first version of that test summed velocities per step, and it failed two styles that
measurably do not clip. A hat's buffer peaks far below a kick's and their peaks do not even align
in time, so coincident velocity is not a proxy for level: `LESSONS.md` shape 16, a broken probe
reporting a defect that is not there, caught because the rendered peaks said 0.89 while the test
said 278. It mixes the real buffers now, and it lives in `TrainerKitTests` rather than beside the
styles — peak level is a property of the synthesised mix, and `GrooveCore` knows nothing about
how a voice sounds.

It then found a real one. Motown cleared the rails at 100 BPM and peaked at 1.13 at 160, because
sixteenths 93 ms apart overlap where a listener hears one steady shimmer. The hat sits at velocity
46 for that reason, and the number came from the top of the tempo range rather than from how it
looked at 100.

#### Nothing plays these yet

`render` writes every style at every intensity — eight new files — so the layers entering can be
judged by ear before anything is built on them, which is §7.23's rule about rungs applied to
music. No planner, no drill and no frozen backing can reach a style, and a test walks every
arrangement takes have been measured against to prove it.

The generator and the stored seed are step 4.

### Step 4, as built — the seed, and why it is stored

`StyleArranger.arrangement(style:seed:bars:phraseBars:)`. A style is bounded authoring; the music
it produces is not, because how the intensity moves, which fill lands where and how long the
phrases run are all chosen from a seed.

**The seed is stored, and that is what makes generation permissible rather than reckless.**
R1.2.2 says a result that cannot be reproduced from stored data is not a result — so a generated
backing that could not be rebuilt would make every take played over one unexplainable the moment
the generator changed. `BackingIdentity` writes it into `grooveName` as `motown@000000005eed0001`,
which needs **no schema change at all**: the field is already stored on every take and already
treated as a confound by `TakeAxis` and the trend grouping, so two seeds of one style are honestly
different music and every take on record keeps decoding. A name without an `@` is not a generated
backing and parses as nothing, which is every take recorded before M19 — they really did play
fixed music and that distinction has to survive.

#### The intensity arc is chosen, not sampled

Intensity moves along one of five shapes — build and settle, slow burn, open strong, call and
response, two gears — rather than being drawn per phrase. **Independent random intensity sounds
like somebody nudging a fader**: nothing is built to, there is no arrival, and a listener cannot
tell a section from an accident. A shape gives a piece somewhere to go, which is the difference
between thirty minutes being worth playing and being endured.

The fill choices are drawn *before* the loop rather than per phrase, so two pieces from one seed
share their opening whatever their lengths. That is what lets the planner keep one seed inside a
sitting and rotate the style between them (§7.29's settled decisions): an evening has one musical
identity and the next evening is new.

#### The generator adds nothing

It selects among bars the style already defines and never invents or moves a hit — variation is
in what fires, never in when. A test walks every bar of several seeded pieces and requires each
one to be a bar the style produces at some intensity, or one of its fills. That is the assertion
that keeps the backing a ruler.

`phraseBars` is a parameter with a default of eight, because M16's span ladder grows it to sixteen
and thirty-two and the generator should not have to change when it does. A test drives all four.

One `Section` per bar, because a style's layers cycle at their own lengths and a section holding
one pattern for eight bars would flatten exactly the variation the layers exist to create.

`render` writes a generated piece per style so the arc can be heard, which is the only way to
judge it. Still nothing schedules a style: the planner is step 6.

### Step 5, as built — four styles, and a gate that is a flag rather than a promise

`funk` — syncopated kick, ghost snares, sixteenths — and `half-time`, one snare on beat three and
a great deal of air. Four styles now, chosen to span rather than to fill a list: `half-time` is
the only `sparse` one, which is what M24's vocal drills need, and `funk` is the busiest, which is
what makes practising *around* the beat rather than on it possible at all.

#### "Nothing enters the library unheard" is now enforced

§7.23 made it a rule in prose in M14 — *a rung the player has not heard is a rung the planner must
not promote them onto* — and prose is what a hurried afternoon ignores. `Style.auditioned` is a
flag, `StyleLibrary.auditioned` is what the planner will be allowed to see, and it is **`false`
for every style in the library right now**.

Nobody who writes a style can set it honestly. Whether a groove is worth thirty minutes is not a
property of its step list, and the only person who can answer is the one who has to play over it.
A test asserts the current state — four authored, none approved — so flipping one is a deliberate
edit that appears in a diff rather than something that drifts.

The planner in step 6 therefore starts with **nothing it may schedule**, and has to cope with an
empty list rather than reaching past the gate. That is the right shape: the fallback is the fixed
`jamBacking` every take on record already used.

### Step 6 — what an ear found that no test could

The first four styles were rendered and listened to, and the verdict was not close. Recorded in
full because it is the most useful feedback this milestone has had:

> *"They sound like someone is making their very first beats in GarageBand… the tracks sound good,
> just not Motown vibe at all. Same thing with the funk collection."*

Three separate defects, one limitation, and one opportunity.

#### Two things keeping time — a real error, and a test now

*"The ride sounds kind of like a bell with the hats going as well. Usually you keep rhythm on the
ride or the hats, never both at the same time."*

Correct, and worse than described. `motown` played quarters on the ride inside sixteenths on the
hat; `half-time` played the hat and the ride on the **same four steps** — the same rhythm in two
timbres. Two timekeepers is not a fuller sound, it is two drummers.

`Style.doubledTimekeepers(atIntensity:)` catches it and a test walks every style at every
intensity. The rule took two attempts: the first forbade *any* two timekeeping voices, which also
forbids a hat on the downbeats against a shaker on the offbeats — one pulse shared between two
hands, which is ordinary percussion. It is scoped to voices that share **steps** now, so it
describes the defect rather than the genre.

#### A hat at one velocity is a click track

*"There was a rhythmic like click that sounded like a metronome noticeable in some of the
tracks."*

Every layer was written with a single velocity for all its steps, so eight identical hi-hat hits
per bar were eight copies of one buffer at one level. That is a metronome by construction. A hand
leans on the beat and eases off between it, and the ear reads the difference as groove rather
than as timing. `Pattern.line` gives a layer a velocity per step, and the hats in every style are
accented now.

**Velocity only, never position.** Accenting is loudness; the backing stays the ruler.

Which voice the click actually *is* remains unidentified, and guessing from a step list is how a
wrong fix gets shipped. `render` writes one file per voice — `kit-kick`, `kit-snare`, and the
rest, four bars of quarter notes each — so the sound can be named rather than theorised about.

#### The kit is electronic, and a genre name is a promise

*"Drums sound great and I could and would use them to produce music, but the electronic set
brings a kind of vibe… it was more of a 'beat #3' situation rather than 'oh, a Motown beat'."*

This is the finding that matters most, and it is not a bug. `DrumSynth` synthesises everything
procedurally with zero dependencies (R7.2) and no samples, which is why the app is 2 MB and needs
nothing installed — and it is also why it will never produce a 1965 Funk Brothers session. **A
style named for an acoustic genre is making a promise the kit cannot keep.**

Four voices were added because the kit could build a groove and could not build an *identity*:
`tambourine`, `shaker`, `cowbell`, `sidestick`. The tambourine in particular was a real omission
— eighths on a tambourine *is* the Motown signature, and there was no tambourine.

Whether that closes the gap or merely narrows it is a question for an ear.

**Decided on 7 August: the genre names stay as a goal and come off these four tracks.** They are
`driving`, `pocket`, `syncopated` and `half-time` now — named for what each demonstrably does.
`half-time` was the only one already honest, because it describes a rhythm rather than claiming a
genre.

That is not a retreat from the ambition, which is unchanged and recorded as M26: keep the genre
names, make the kit deserve them, no shortcuts. It is a refusal to let a label imply a
measurement nobody made — the same discipline as `unusableReason` and `splitIsReliable`.

And it exposed the harder half. A convincing kit is necessary and nowhere near sufficient:
naming something `motown` is a claim, and there is no vocabulary here for stating what the claim
*is*, let alone checking it. Instrumentation, where the backbeat sits, the ghost-to-accent
relationship, form, bass motion, tempo range, what occupies the mid-range and what is
deliberately empty — that is a classification problem, it is deeper than a kit and a rhythm, and
it is now **M27** on the roadmap rather than something to be improvised the next time a style
gets written.

#### Where these two belong

*"These two progressions would work very well in our vocal section for when it is time to 'spit
bars'."*

Recorded as a finding, not a consolation. `motown` and `funk` as they stand are good beats to rap
over, which is exactly what M24's vocal drills need — chanting, rhyming and spoken rhythm want a
backing with a strong pocket and no melodic claim on the ear. M24 should look here first rather
than authoring its own.

### Step 6b — the click, found and measured

*"The click I am pretty sure is coming from the kick, it's got a 'closing' quality at the end.
Playing `kit-kick-100bpm.wav` sounds kind of techno-like with the rhythmic opposite of the kick."*

Exactly right, and it is a defect rather than a taste. Measured from the rendered file:

| | |
|---|---|
| Kick buffer length | 14,112 samples — 0.320 s, fixed |
| Body envelope at that point | `exp(-0.32 / 0.10)` = **4% of peak**, plainly audible |
| Last sample before the buffer ends | −841 of 32,768 |
| Next sample | 0 |

**The buffer stops mid-cycle and the signal steps to zero.** A step discontinuity is a broadband
impulse — a click — and it lands at exactly 0.320 s after *every* kick. Against a 0.6 s beat that
is 0.53 of a beat, which is why it reads as a rhythmic event of its own rather than as part of
the kick: "the rhythmic opposite" is a precise description of a click sitting just past the
offbeat.

At −31.8 dBFS it is far too loud to hide. Four voices do it:

| Voice | Level at truncation | |
|---|---|---|
| **kick** | **−31.8 dBFS** | six decibels worse than anything else |
| snare | −38.7 dBFS | |
| clap | −45.7 dBFS | |
| ride | −47.8 dBFS | |
| closedHat, cowbell, rimshot, shaker, sidestick, tambourine, tom | −51 dBFS and below | inaudible |

The cause is the same everywhere: a one-shot's length is a constant, its envelope is exponential,
and an exponential never reaches zero. Whichever value it happens to hold at the last sample is
the size of the step.

**This has been in every take ever recorded.** `basicRock` has kicked on every bar since M3, so
every jam, every benchmark and every ladder take was played over a backing with a faint click a
third of a second after each kick. It is not a measurement error — the grid comes from
`TimingCore` and never from the audio — but it is a thing the player has been hearing, at a fixed
offset from the pulse, near the offbeat. Worth holding in mind when reading the offbeat drill's
one take.

The fix is not the interesting part: fade the last few milliseconds of every one-shot, or make the
length follow the decay. What the finding is worth is the method — **an ear said "there is a click
somewhere", one file per voice turned that into "the kick", and arithmetic on the rendered samples
turned that into a number.** No test would have caught it, because nothing was wrong with the
step list.

### Step 7 — the three things that have to be settled before the planner sees a style

Step 7 is the only step in this milestone with measurement risk, and the risk is not that a
generated backing sounds bad. It is that **the failure is silent**: a take over the wrong music is
a perfectly good take that has quietly left the series it exists to extend, and nothing in any
readout would say so. The 21-take free-jam trend and the five-point benchmark are the only
longitudinal data this project has.

Three problems, settled here rather than discovered while wiring.

#### 1. The jam trend group does not include the backing, and the seed would splinter it

`TrainerEngine.groupKey` is `(bpm, rung, swingRatio, offbeatLevel)`. The backing appears only in a
warning string built from `TrendAnalysis.distinct(takes.map(\.grooveName))`. Today `Jams at 100
BPM` holds 21 takes over two backings — `basicRock` and `jamBacking` — and fits a line with a
warning under it.

Step 7's settled decision is that **the closing jam rotates its style between sittings and keeps
one seed within a sitting**, so every sitting contributes takes under a *new* `grooveName`. After
ten sittings the warning names ten backings and grows without bound, and the fit spans ten pieces
of music sharing nothing but a tempo.

**This is a defect this project has already retracted verdicts for, twice.** §7.24 step 8 measured
it on real data: one offbeat take pooled into `Jams at 100 BPM` moved that group's |bias| from flat
to **+0.29/take [+0.01, +0.62] worsening**, and the mixed-backings warning fired correctly the
entire time. §7.27 then retracted two more. `LESSONS.md` shape 19 is the generalisation: **naming a
confound is the floor, not the fix** — R3.4 versus R3.5.

Three ways out, and the third is the one:

| | Cost |
|---|---|
| Add `grooveName` to `GroupKey` | Every seed becomes a group of one. `TrendAnalysis.minimumPoints` is 3, so the free-jam series — the longest in the project — disappears, and so does the fixed group, which is the part worth keeping |
| Exclude generated backings from trends | Keeps the history and throws away every future training take. The closing jam is where most playing happens; a trend that sees only the benchmark is a trend over five takes a fortnight |
| **Split at the fixed/generated boundary, and key the generated side on the style rather than the seed** | The 21-take series is untouched, `driving` accumulates its own series across sittings, and the boundary already exists |

`BackingIdentity.parse` draws exactly that line already — a name without an `@` is a fixed backing,
which is every take recorded before M19 — so this is not a new concept and needs no schema change.

**Whether two seeds of one style pool honestly is a claim, and it is not yet measured.** It
contradicts `TakeAxis`, which treats any `grooveName` difference as a confound, so it has to be
argued and then checked rather than assumed:

- `TakeAxis` answers a different question. It asks whether two *named groups* differ, where a
  backing difference is a plausible rival explanation for a difference that was found. A trend asks
  whether one task is moving, and the task is "play freely over a `driving` groove" — the seed
  varies the intensity arc and which fill lands, not the tempo, the density, the instrumentation or
  where the backbeat sits.
- That is bounded by construction rather than by intention: `density` and `carriesBass` are
  properties of the style, and a test already walks every bar of several seeded pieces and requires
  each to be a bar the style produces at some intensity or one of its fills. **The generator adds
  nothing.**

But no take over a generated backing exists, so the between-seed variance is unmeasured. The honest
shape is therefore: group by style, warn that the pool mixes seeds, name what that costs, and
**say the between-seed variance has never been measured** — the same discipline as `unusableReason`
and `splitIsReliable`. Once a style has takes on two or more seeds it becomes directly estimable,
and it is the same two-stage question `Bootstrap` already answers for takes within a condition
(R3.2, row 3). If it comes back comparable to the between-take spread, seeds pool and the warning
comes off; if it is larger, the seed goes into `GroupKey` and the cost is accepted. **Open question,
recorded in §9 rather than settled here.**

`TakeAxis` gains a **style** axis rather than losing its backing one, so `review tags` can say
*"pools takes across different styles"* — a genuinely different task — apart from *"pools seeds of
one style"*, which is a weaker claim. One more entry in `TakeAxis.all`, which §7.28 made the single
list precisely so two readouts cannot disagree about what makes a task different.

**What must not move is the fixed group.** R3.5's locked slots keep `jamBacking`, so the benchmark
series and the 21-take free-jam series stay exactly as recorded. The guard is a test that the
pre-M19 corpus produces identical trend output either side of the change.

#### 2. `JamPlan` cannot hold a `Style`, and that is the module boundary working

`JamPlan` lives in `TimingCore/SessionPlan.swift`. `TimingCore` imports `Foundation` and nothing
else; `Style` lives in `GrooveCore`, which by R1.1.3 depends on nothing, not even `TimingCore`.
**Neither module may import the other, so a plan cannot name a style by its type.** That is not an
obstacle to route around: `SessionPlanner` decides what to practise from measured history, and it
must not be able to reach a pattern.

So the plan carries the *identity* and `TrainerKit` — the one module importing both — resolves it:

```swift
public let styleName: String?     // nil is the fixed backing, which every locked slot is
public let seed: UInt64?
```

Four consequences, all decided before the code rather than after:

- **Both fields are `Optional` and stay so** (R6.1). `JamPlan` is `Codable`, five `session-`
  manifests are on disk, and every one must keep decoding. Here `nil` genuinely *is* the identity —
  every plan ever written meant the fixed backing — which makes this the opposite case from `rung`,
  where absent means *no rung was prescribed* and never quarters. `LESSONS.md` shape 13 says decide
  which kind each optional is and write the reason beside the field; this is that decision.
- **A raw `String`, not an enum**, for the same reason as `ExperimentAssignment.arm` and
  `SessionPlacement.role`: adding or renaming a style must never orphan a stored manifest. The
  rename from `motown` to `pocket` has already happened once.
- **`StyleLibrary.named(_:)` returns `nil` and the caller needs an answer.** A manifest naming a
  style that no longer exists falls back to `jamBacking` **and says so** — never traps, never
  silently substitutes. R6.4: a decode failure that gets swallowed is how a schema change quietly
  erases history.
- **The two fields travel together or not at all.** A style with no seed is not reproducible
  (R1.2.2); a seed with no style means nothing. `JamPlan.init` refuses the half-set case rather than
  letting one path write a manifest nobody can replay — validation at the boundary (R7.6).

**Where the resolution goes is already decided.** `SessionRunner.jamConfig(for:)` exists *because*
§7.24 step 8 found the offbeat level failing to reach the backing from a decision made inside a
function that opens an audio device (`LESSONS.md` shape 1). It is the same seam, it is already
testable, and a test asserts the arrangement that comes out of it.

#### 3. Nothing structurally stops a style reaching a locked slot

`JamConfig.backing` has three branches — offbeat, rung, fixed — and step 7 adds a fourth. A comment
is not a guard, and neither is a planner that happens not to set the field. Three layers, cheapest
first:

1. **The planner cannot express it.** The locked blocks are built from `referenceBpm`,
   `benchmarkBars` and `benchmarkTag`, and the style fields are simply not set there.
   `testTheBenchmarkIsAlwaysTheSameLockedTakeWhateverTheLadderDoes` already asserts those
   absolutely rather than against a reference plan; it gains `XCTAssertNil(p.styleName)` beside the
   existing `XCTAssertNil(p.rung)`. One line, in the test that exists for exactly this class of
   leak.
2. **A test walks every role.** For every `BlockRole` in `allCases`, at 20, 30 and 45 minutes,
   across the nine planning histories: `cold`, `benchmark` and `experiment` resolve to a
   `grooveName` of `jamBacking`. Roles rather than block indices, so a block that moves cannot move
   out from under the assertion — and `allCases` means **a role added later fails this test until
   somebody decides which side of the line it is on**, which is the property worth having.
3. **The resolution refuses it.** `SessionRunner.jamConfig(for:)` ignores the style fields for a
   locked role rather than trusting the plan, with a comment naming what breaks. Not redundant: the
   planner is not the only thing that builds a block. A stored manifest is replayed, and a manifest
   written by a future version is not something today's planner controls.

**The same rule reaches the CLI.** `--probe` exists so anything can be tried without corrupting a
ladder, and a style on a free `jam` is exactly what it is for. What must not exist is a way to put
a style on a *benchmark-tagged* take from the command line — the tag is what `WarmUpAnalysis` and
the trend grouping key on, so that guard belongs beside the tag rather than beside the style.

**What none of this verifies** is that generated music is worth playing over for thirty minutes,
which is a live-run question (R5.6) and is what `Style.auditioned` is for. The gate above stops a
style reaching the *wrong* slot; it does not stop an unlistened style reaching the right one. That
is a different flag and it is still `false` for all four.

#### Step 7a, as built — a plan can name its backing, and a locked slot cannot

Hazards 2 and 3 of the three above, built first and on their own, because R6.3's rule is that
storage goes before the thing that uses it: **nothing sets the new field yet.** The planner is
untouched, no surface exposes it, and every take this can produce is byte-identical to one it could
produce before. That is what makes it a state the repository could sit in indefinitely (§8.1).

**`PlannedBacking` on `JamPlan`, `BackingIdentity` on `JamConfig`, one conversion between them.**
`TimingCore` sees `Foundation` and nothing else and `GrooveCore` depends on nothing (R1.1.3), so
the identity crosses the boundary as data and becomes music in `SessionRunner.jamConfig(for:role:)`
or nowhere. That is the shape `Feel` and `Swing` already have across the same seam, for the same
reason, and `LockedSlotBackingTests` pins the two together the way `SwingAgreementTests` does —
the name a take is stored under must rebuild exactly the arrangement that played, for every style.

**One optional value rather than two optional fields, which is a change from the plan above.** §7.29
step 7 specified `styleName: String?` beside `seed: UInt64?` with `JamPlan.init` refusing the
half-set case. Building it showed the guard cannot hold: `JamPlan` is `Codable` and a stored
manifest is *decoded*, not constructed, so `init` never runs and a file carrying one field without
the other would decode into a plan nobody can replay — R1.2.2 broken by the one path that matters,
since replaying a manifest is the whole reason the seed is stored. A single `PlannedBacking?` makes
the illegal state unrepresentable instead of merely rejected, at the cost of one small type. The
seed also stays a `UInt64` rather than becoming hex text, so `BackingIdentity.name` remains the
only place that formatting lives.

**Three layers, cheapest first, and each one verified by removing it.**

| | Fails if reverted |
|---|---|
| The planner cannot express it — `XCTAssertNil(p.generatedBacking)` beside the existing `rung` assertion in `testTheBenchmarkIsAlwaysTheSameLockedTakeWhateverTheLadderDoes` | the benchmark and experiment planning tests |
| `SessionRunner.lockedToTheFixedBacking` is **exhaustive over `BlockRole`**, so a role added later is a compiler error rather than a silent `false`, and `jamConfig(for:role:)` drops a generated backing from a locked slot rather than trusting the plan | `LockedSlotBackingTests`, **nine assertions** |
| `JamConfig.validate()` refuses a style beside a rung or an offbeat level — two backings cannot both play, and a take whose music nobody can name is a take whose number nobody can attribute | two assertions |

The middle layer is the one that is not redundant: **the planner is not the only thing that builds
a block.** A stored manifest is replayed, and a manifest written by a future version is not
something today's planner controls, so the refusal belongs where the music is chosen.

**An unknown style falls back and says so.** A manifest naming a style the library no longer has
resolves to `jamBacking` and stores that name — it does not trap, and it does not substitute a
neighbouring style. R6.4, and the rename from `motown` to `pocket` has already happened once; a
wrong groove played confidently is worse than a familiar one.

`testNoStyleIsApprovedYetSoThePlannerStillHasNothingToSchedule` asserts the library is still
unapproved, so **flipping `Style.auditioned` fails two tests and lands as a decision with a diff**,
which is what step 5 built the flag for. The listens on 7 and 8 August were defect verification —
does the click go, do the hats sound right, is the arc audible — and not an answer to whether a
groove is worth thirty minutes. Those are different questions and only the player can answer the
second.

Still to build: the planner.

#### Step 7c, as built — the surfaces come before the planner, and the reason is a dependency

**Written as "planner and surfaces", built the other way round, because the dependency runs
backwards from the plan.** `StyleLibrary.auditioned` is empty and stays empty until somebody has
played over a style; the planner may schedule nothing until then; so a planner built first would be
a code path nothing could exercise and a live run would show exactly what it shows today. There is
also no way to play over a style *at all* — `render` produces something to listen to, and listening
is not playing. Building the planner first would have meant asking for an audition that could not
be performed.

`jam --style <name> [--seed <hex>]`. Four refusals, all decided in `Commands.resolveStyle` before
an audio device is opened:

| | |
|---|---|
| A style nobody has auditioned | refused, and names `--probe` as the way through |
| A style the library does not have | refused, listing what it has |
| A style beside a rung | refused, naming the two things typed rather than talking about backings |
| A seed that is not hexadecimal | refused, showing the form a take stores |

**Auditioning is what `--probe` was built for.** §7.26's flag records a take as a deliberate look at
a setting that was not earned, read by nothing that decides what to practise next — and a style
nobody has played over is exactly that setting. So the gate is not a new mechanism; it is the
existing one pointed at music. The take is stored, marked, and cannot move a ladder.

Every refusal lives in `resolveStyle` rather than in `runJam`, which opens an audio device and
waits. `LESSONS.md` shape 1, and §7.22 records a test that checked argument handling by playing a
two-and-a-half-minute drill through the speakers.

**The seed is printed as the flags that reproduce it.** A drawn seed varies with the clock, because
variety is the point of asking for one, and it is stored in `grooveName` either way — so *"play me
that one again"* is answerable after the fact, which is the whole reason R1.2.2 wanted it stored.

`CommandFlags` gained value-taking flags, accepted as `--style driving` and `--style=driving` both.
A flag missing its value **refuses rather than consuming the next flag**: `--style --probe` is a
typo, and swallowing it would run a take over a style called `--probe` — or worse, an *unprobed*
one, which is the corruption `--probe` exists to prevent arriving through a typo. That is the same
reasoning that already makes an unknown flag an error rather than something ignored.

##### What this leaves for a live run

The happy path is deliberately unexercised here: it opens an audio device, so nothing above ran it
(§7.22, and AGENT.md's rule about drill commands). **The first take over a generated backing has not
been played**, and until it is, every grouping decision in step 7b is exercised against synthetic
takes only.

That run is also the audition. Four styles, none approved, and the question is not the one the
listens on 7 and 8 August answered — *does the click go, do the hats sound right, is the arc
audible* — but whether a groove is worth thirty minutes. Only the player can answer it, and
flipping `Style.auditioned` fails two tests until `PLAN.md` records who listened and when.

#### Step 7b, as built — the trend splits fixed from generated, and keys on the style

`GroupKey` gains a fourth confound axis beside tempo, rung, feel and the offbeat level, and it
arrives for the reason those three did: between them §7.24 step 8 and §7.27 retracted **three**
verdicts that were the task changing rather than the player.

```swift
enum BackingGroup { case fixed; case style(String) }
```

`BackingIdentity.parse` already draws that line — a name without an `@` is a fixed backing, which
is every take recorded before M19 — so the boundary is not a new concept and needs no schema
change.

**Every fixed backing stays one bucket, deliberately.** `basicRock` and `jamBacking` pool exactly
as they did, with the same warning naming the mix. Splitting them is a defensible readout and a
*different* one, and re-scoring the project's headline series while building something else is how
a finding gets attributed to the wrong cause. The label for `.fixed` is the empty string, so every
title this project has ever printed is unchanged.

**Byte-identical on the real corpus, captured before the change rather than after** (`LESSONS.md`
shape 4): `review trend`, `tags`, `list`, `cold` and `interval` over the 30 stored jams all diff
clean. That is the whole claim of the preservation half, and it is the reason the fixed side is one
bucket rather than the tidier alternative.

Reverting the key to `.fixed` for everything fails `GeneratedBackingTrendTests` six ways. The end-
to-end cases go through `TrainerEngine.trends(for:)` with takes written to a redirected store, so
the path under test is the path that ships (`LESSONS.md` shape 1) — `TakeFactory.jam` gained
`generatedBacking:` and, for symmetry with the other four factories, `dayOffset:`, since two takes
sharing a timestamp overwrite each other (§7.22).

**The seed pool says it is provisional.** Three sittings of `driving` on three seeds fit one line —
which is the point of keying on the style, since keying on the seed would give three groups of one
against a `minimumPoints` of 3 — and the group warns that it *"pools 3 seeds of driving … whether
that moves spread has never been measured"*. R3.3: the argument in §7.29 step 7 is an argument, no
take over a generated backing exists yet, and a readout that implied otherwise would be exactly the
confident-wrong-number §3 forbids. §9 open question 10 has what would settle it.

##### `TakeAxis` gains a style axis, and an existing guard caught the omission

`review tags` can now say *"pools takes across different styles"* — a different band — apart from
the backing axis's *"different music"*, which two seeds also trip. The style axis maps every take
recorded before M19 to one value, so it is **silent on the entire existing corpus** and
`basicRock` beside `jamBacking` still reports exactly one mixed axis.

`TakeAxisTests.testEveryAxisIsSeenByBothReadouts` is parameterised over `TakeAxis.all` and failed
the moment the axis was added, because it had no fixture — which is precisely what §7.28 built it
for, one list read by two readouts and neither allowed to fall behind. It also *trapped* rather
than failing, on `takes[0]` of an empty array, taking the whole run down with it; the missing
fixture is added and the guard now reports a failure instead of a crash.

---

## 7.30 Real genres, and what a synthesised kit would have to do

Settled with the player on 7 August, in answer to §7.29 step 6's open question:

> *"We should absolutely keep the genre names in general. I really would like to make some
> different genres happen for real, no shortcuts. With enough effort and refining we can
> absolutely synthesize any sound we want and I am game."*

So the direction is not "rename the styles to something the kit can honestly claim". It is to
make the kit good enough that the claim is true. That is a bigger undertaking than the rest of
M19 put together and it deserves its own reckoning.

### What actually separates a synthesised kit from a genre

The current synth is one buffer per voice, played back at a gain proportional to velocity. Five
things are missing, in rough order of how much each would buy:

1. **Velocity layers.** A drum hit harder is not the same sound louder — the spectrum shifts, the
   attack sharpens, the decay changes. A ghost snare at velocity 34 and a backbeat at 100 are
   different instruments, and rendering both from one buffer is why quiet hits sound like a fader
   move. This is the single largest gap.
2. **A kit is a parameter set, not a constant.** A Motown snare is tuned high and damped; a rock
   snare is fatter and rings. Same synthesis, different tuning, decay and noise balance. `Style`
   should carry kit parameters and `BackingKit` should take them, which is an architectural change
   rather than a tuning one.
3. **Room.** The kit is bone dry, and dryness is most of what reads as "electronic". Early
   reflections and a short tail would do more for believability than any amount of spectral work
   on the voices themselves.
4. **Deterministic variation.** Every hit is byte-identical to the last, which no acoustic
   instrument is. Round-robin sample selection or small seeded parameter jitter would break the
   machine quality — **seeded**, because R1.2.2 and the reproducibility the whole milestone rests
   on are not negotiable for a bit of realism.
5. **The bass.** A sine and an octave with a pluck. A real bass has string noise, finger attack
   and a pitch-dependent tone; it is the least convincing thing in the mix after the kick.

None of these is exotic. All of them are work, and the order above is the order of return.

### Samples: the offer, the constraint, and a third path

The player has a Roland TD-V6 with many kits, GarageBand's virtual instruments, microphones and
inputs, and asked what the position is on capturing those sounds.

**Against sampling, and it is stronger than it first looks:**

- R7.2 is zero third-party dependencies, and the reasoning generalises: every asset is content
  somebody else's licence governs. The app currently ships **no audio assets at all**, which is
  why it is small, why it needs nothing installed, and why a render is byte-reproducible from
  source alone.
- The licensing of a hardware module's ROM samples or a DAW's instrument library is a question
  about *someone else's terms*, and the honest answer is that it varies, it is often restrictive
  about redistribution specifically, and this is not the place for a confident reading of it.
- Purely local use by one player is a very different question from anything distributable, and
  this app has release tooling. The distinction would have to be maintained deliberately.

**The third path, and the recommendation: record them as a *reference*, not as a source.**

A timbre is not copyrightable; a recording is. So capture the TD-V6 and GarageBand kits, look at
their spectra, envelopes and velocity behaviour, and **tune the synthesis to match**. That uses
the hardware for exactly what it is good for — telling us what the target sounds like — while the
app keeps shipping nothing but code. It also produces something a sample never could: a kit that
can be re-tuned per style, at any velocity, without a gigabyte of assets.

That is a measurement problem, which this project is well equipped for, rather than an asset
problem, which it is not.

### The ear this project has been missing

*"My older brother is in the music business professionally as a musician / producer."*

Worth recording as a resource rather than an aside. Every acceptance question in this milestone
has come down to whether something *sounds* like what it claims, and that has been answered by
one amateur listener and by me, who cannot listen at all. A professional producer is precisely
the missing instrument: not for building anything, but for saying "that is not a Motown snare, it
is tuned too low and there is no room on it" — which is the sentence that turns a vague
dissatisfaction into a parameter.

### What this does to the roadmap

M19 finishes on its current scope: the format, the generator, the planner wiring, and styles that
are honest about being what they are. **The synthesis work above is not M19.** It is large enough,
separable enough and valuable enough to be its own milestone, and folding it into M19 would mean
M19 never lands.

Recorded as **M26 — the kit**, in §7.13.

#### The headroom test was not testing fills

`peak` walked `style.pattern(atBar:intensity:)`, which never returns a fill — so the crash that
lands on every phrase boundary, on top of the loudest bar it can follow, was the one thing in a
style most likely to clip and the one thing unmeasured. It is covered now, at the top of the tempo
range where the tails overlap worst.

The window came down from eight bars to two at the same time. Every layer cycles in one or two, so
a longer render reaches no combination the first two miss, and the suite runs unoptimised.

---

## 7.31 Third codebase review — seven findings, three of them audible

A full pass over the tree before M19 step 7, on the same principle as §7.20: the planner wiring
inherits every weakness of the music underneath it, and step 7 is the only step in this milestone
that can corrupt a measurement.

**The gate was green throughout and is green now**: 604 tests, 41 selftest checks, a warning-free
release build, every stored take decoding, a clean tree, no `TODO` anywhere in `Sources` or
`Tests`. The take counts quoted in `AGENT.md` re-derive exactly — 30 jams, 12 form, 12
continuation, 10 tempo, 8 recall, 72 takes and 5 session manifests — as does 443 pure-module tests.
So none of this is a crash or a broken build. Three findings are defects in the kit, one is a
diagnostic that cannot see the thing it was built to find, and three are the documentation drifting
from the code.

### 1. The bass truncates five times louder than the kick, and `render` cannot show it

§7.29 step 6b measured the kick's truncation click at −31.8 dBFS and tabulated every voice that
does it. **The table has no bass in it, and the bass is the worst one.**

```swift
let count = Int(decay * 1.6 * fs)      // BassSynth
let body  = exp(-t / decay)
```

The body envelope stands at `exp(-1.6)` = **20.2% of peak** when the buffer ends. The kick's stands
at `exp(-3.2)` = 4.1% — §7.29 step 6b's own figure. Both are read straight off the source and are
exact.

**Corrected on measuring it properly.** This finding was first written from a reimplementation of
`BassSynth`, quoting the bass at −17 to −22 dBFS against the kick's −31.8 — and those two numbers
are **not on the same basis**. §7.29 step 6b measured off a rendered WAV, which is the mix: scaled
by `masterGain` 0.6 and by velocity, 6.5 dB below the buffer at velocity 100. The reimplementation
measured the buffer. Comparing them made the gap look larger than it is, which is `LESSONS.md`
shape 6 committed while documenting shape 3. The fix's own revert-check measures every voice on one
basis, off the buffers the app actually plays:

| Voice | Last sample | Buffer dBFS | In a velocity-100 mix |
|---|---|---|---|
| **bass, worst note** | 0.152 | **−16.3** | −22.8 |
| bass, quietest note | 0.079 | −22.0 | −28.5 |
| kick | 0.054 | −25.3 | **−31.8** — step 6b's figure, confirmed |
| snare | 0.025 | −32.2 | −38.7 |
| clap / crash / ride | 0.011 / 0.008 / 0.009 | −39.2 / −42.0 / −41.2 | −45.7 / −48.5 / −47.7 |
| hats, tom, cowbell, shaker, tambourine | ≤ 0.006 | −44.7 and below | −51.2 and below |
| rimshot, sidestick | ≤ 0.0003 | −69.9 and below | inaudible |

So the bass is **9 dB worse than the kick, not fifteen**, and step 6b's table was right about every
voice in it. The claim that survives is the one that mattered: the loudest truncation in the kit
was in the one voice the diagnostic could not render, and it is 4.9× the kick's as a fraction of
its own peak.

**The reason it was missed is structural and is the interesting half.** `runRender` writes its
per-voice files from `BackingVoice.allCases.filter { !$0.isPitched }`, so there is no `kit-bass`
file at any pitch. The method §7.29 step 6b is rightly proud of — *an ear said "there is a click
somewhere", one file per voice turned that into "the kick", arithmetic turned that into a number* —
**has a filter in it that excludes the voice with the loudest click.** That is `LESSONS.md` shape 3,
a filter that hides real hits, applied to a rendering pass rather than to a grep, and the result
went into `PLAN.md` as a complete table.

Blast radius: **no take on record**. Nothing frozen carries a bass and a test walks every frozen
arrangement to keep it that way. But every style carries one, so this arrives the moment step 7
schedules a style — which makes it a step-7 prerequisite rather than an M26 item.

#### Fixed — step 1, and it changes frozen music

Every voice now ends on a release fade, applied in `DrumSynth.render` and at the end of
`BassSynth.render` rather than in `BackingKit`, so **there is no way to obtain a buffer that still
truncates**: `raw(_:sampleRate:)` is private and the fade is on the only path out of each
synthesiser. A caller adding a fourteenth voice gets the fix for free rather than reintroducing the
defect one call site away.

**Fading, not lengthening.** An exponential never reaches zero, so a buffer long enough to stop
honestly would run 2.4 s for the bass — and `BassSynth`'s own doc comment says the note has to be
over inside a beat so it reads as a pulse rather than a pad. Lengthening it would fix the click by
changing the music, which is the one thing a fix here may not do.

Three numbers, each derived rather than chosen:

| | |
|---|---|
| **50 ms** | Two cycles of E1 at 41.2 Hz, the lowest note the band can sound. A fade shorter than one cycle of the fundamental acts inside a single swing of the waveform and leaves most of the step. It comes from `BackingKit.bassNotes.lowerBound`, and `testTheFadeCoversTwoCyclesOfTheLowestNote` fails if that widens downward without it |
| **a quarter of the buffer, at most** | The rimshot is 50 ms long altogether and already ended at −69.9 dBFS. Without the clamp a fix for the loud voices would gut the short ones |
| **raised cosine** | A linear fade is flat nowhere: it leaves a corner in the first derivative where it begins, which is a weaker discontinuity of the same kind as the one being removed |

`OneShotTailTests` asserts the property against the buffers `BackingKit` actually hands the render
callback — the path that ships, not a reimplementation of it (`LESSONS.md` shape 1). Reverting
either `fadedOut` call fails it **fourteen ways**: every voice above except the rimshot and the
sidestick, plus all twenty-five bass notes. The other three cases are the ones that stop the fix
being a way to make the kit quiet — every voice still peaks above 0.01, every peak lands *outside*
its own fade region, and no short voice is mostly fade.

**And it is the probe that got retired, which is the point.** §7.31 quoted this defect off a
reimplementation of `BassSynth`, and `LESSONS.md` shape 16 says suspect the probe. The answer to a
finding resting on one is not to check the probe again; it is to assert the property where the app
lives, which is what the table above is measured from.

`kit-bass` now renders, walking E1 → E2 → E3 in one file rather than taking twenty-five. That
closes the filter that caused the finding in the first place, and it is what makes the fix audible
rather than merely asserted.

#### Heard, 7 August 2026

> *"I listened to the new files kit-kick-100bpm and kit-bass-100bpm and they sound good."*

**That is the half of this that no test could supply.** `OneShotTailTests` proves the buffers no
longer step to zero; it cannot say the click is gone to a listener, and a fix that removed the step
while leaving something else audible would pass every assertion in the file. The verdict above is
what closes it, and it is recorded here rather than summarised because the person who can hear it
is the only one who can give it — the same reason `Style.auditioned` is a flag nobody who writes a
style may set.

The bass file is the one that mattered, since it walks down to E1 where the truncation was loudest
and the period longest. Both were listened to against the pre-fix renders that had been sitting in
`temp/renders` since the review.

#### The discontinuity, and its date

**On 7 August 2026 the sound of `jamBacking` changed.** Every take recorded before that date was
played over a kick with a −31.8 dBFS click 0.320 s after every hit; every take after it was not.
R3.5 freezes the *music* in the locked slots and this does not move a single hit — `CommonGridTests`
compares 27,744 scheduled sample positions and none moved, every rendered peak is unchanged to two
decimals, and `selftest`'s groove RMS shifts 0.0932 → 0.0930, which is the tails being 50 ms
shorter. But §2's invariant table records a changed backing producing a "real" 8 ms spread change
that was partly just different music, so this is written down rather than waved through.

Recorded here so that a future trend across the boundary can be read with it in view. Two reasons
to expect nothing:

- The click is at a **fixed offset from the pulse** — 0.53 of a beat at 100 BPM — so if it did
  anything it acted as a faint extra timekeeper near the offbeat, and removing it should if
  anything loosen rather than tighten. It is not a plausible source of a *narrowing*.
- The grid comes from `TimingCore` and never from the audio, so nothing measured could have moved
  mechanically. Only the player could.

**What to watch**: the benchmark jam, which is the only locked longitudinal slot. Its last five
takes ran 24.1 → 17.4 → 22.0 → 21.7 → 24.9 ms, so it bounces by about 7 ms on its own — a step
smaller than that after 7 August says nothing either way, and it would take several takes to say
anything at all. **Do not read the first post-fix take as an effect.**

### 2. `driving` and `syncopated` play the closed and open hat on the same step

| Style | Intensity | Shared steps |
|---|---|---|
| `driving` | ≥ 2 | 14 |
| `syncopated` | 3 | 6, 14 |

A hi-hat cannot be open and closed at one instant. The open hat on the "and" of four is supposed to
**replace** the closed hat — that is what the gesture *is* — and instead both buffers sum, a 45 ms
"tss" laid over a 1.2-second wash.

`Style.doubledTimekeepers` cannot catch it, and the reason is exactly the narrowing that made that
rule correct: `openHat` is not in `BackingVoice.timekeepers`, and with one or two hits a bar it
falls below the three-hit threshold that stops a ride hit on the downbeat reading as a second
pulse. The rule describes *doubling a pulse*; this is *doubling an instrument*, and they need
separate checks.

Same shape as §7.29 step 6's two-timekeeper finding — a physical impossibility that reads on the
page as a reasonable step list — and the second instance of it, which is what makes it worth a
structural guard rather than two edits.

#### Fixed — step 2, by resolving rather than by forbidding

`BackingVoice.articulationGroups` lists voices that are **one physical instrument in different
states**, in precedence order, and `Style.pattern` reduces each instrument to one articulation per
step as it merges the layers. The open hat wins: the foot lifts, the stick hits, and what a closed
hat underneath it would add is a second hi-hat.

**Resolved, not forbidden, and the distinction is the whole design.** The obvious alternative is a
check that refuses a style authoring the collision — but *"eighths on the hat, and this one is
open"* is the natural way to write the figure, and the alternative is punching a hole in the hat
layer. That hole would have to open and close with the intensity, since the open hat enters at 2
and the hat line it displaces enters at 1, and **the layer format cannot express that** — a layer
is a figure and an entry threshold, with no way to say "unless". Forbidding the collision would
mean either a worse format or a worse groove.

It goes in `Style.pattern` rather than in `Pattern`, because merging is what *creates* the
impossibility: every authored layer is playable on its own, and no frozen backing has both hats at
all — `basicRock` and `halfTime` use the closed hat, `fourOnFloor` the open one, never both. So
this cannot reach the music any recorded take was played over, and `jam-backing` still renders at
peak 0.59.

**Why `doubledTimekeepers` could not be widened to cover it.** That rule is about two voices
keeping the same *pulse*, and it ignores a voice with fewer than three hits in a bar precisely so
an occasional ride hit is not mistaken for a second drummer (§7.29 step 6). An open hat is exactly
that occasional hit. Doubling a pulse and doubling an instrument are different mistakes, they need
different thresholds, and merging them would either re-forbid ordinary percussion or stop catching
the thing the first rule exists for.

#### It broke an invariant's test, and the invariant was right

`testIntensityOnlyEverAddsToWhatWasAlreadyPlaying` failed on three assertions — `driving` at step
84, `syncopated` at 36 and 84. That test holds §7.29 step 3's discipline, the most important
property in this milestone: **intensity adds and removes layers and never moves a hit, because the
backing is the ruler the player is measured against.**

The invariant is right and the assertion was stronger than it. It required the louder bar to
contain each quieter hit *identically*, when what the invariant forbids is a hit **moving** — and
an open hat replacing a closed one is the same step, the same instrument, the same sample, a louder
articulation. Nothing about where the pulse sits changed. `LESSONS.md` shape 4: the assertion was a
proxy for the claim its own name makes, and this is the second time in M19 that a proxy has had to
be replaced by the property (`testTheExistingJamBackingIsUntouched` was the first).

It is asserted per **instrument and step** now, which is stronger in the direction that matters — a
step that sounded at a lower intensity may not fall *silent* at a higher one, whatever voice it was
written for — and `testOnlyAnArticulationOfTheSameInstrumentMayBeSuperseded` holds the other half:
anything that is not an articulation of something else survives byte-identically, so only a hi-hat
may ever be superseded.

**Weakening a test to accommodate a change is the failure this project is most careful about**, so
the argument is recorded here rather than made silently in a diff.

Seven tests, and reverting the one call in `Style.pattern` fails `ArticulationTests` **eleven
ways**. Every style's peak is unchanged at every intensity — resolution only ever removes, so a mix
can only get quieter — and `testResolutionOnlyEverRemoves` asserts that no hit is invented or
moved, which is the property that keeps the backing a ruler.

**The snare drum is deliberately not in the table.** `snare`, `sidestick` and `rimshot` are one
drum struck three ways and the same rule applies, but no authored style plays two of them on a
step, and which articulation wins is a musical decision nobody has had to make. Adding it is a row
in `articulationGroups`, not a change to anything that reads it — which is what makes leaving it
out cheap rather than a debt.

#### Heard, 8 August 2026

> *"I listened to driving 2, 3 and syncopated 3 — all sound nice."*

The three bars where the collision lived, and the only ones the fix changes. As with finding 1,
the test proves the two articulations no longer sound together and only a listener can say the
result is music.

### 3. `render`'s seeded pieces do not contain their own intensity arc

`runRender` builds the arrangement at `max(bars, 32)` and then writes `for bar in 0..<bars`. At the
documented invocation — `render 100 8`, the one in `AGENT.md` — the file is **8 bars: one phrase,
one intensity**. The comment above the loop says the piece is *"long enough to hear the intensity
arc move across phrases"*.

Verified rather than reasoned: `driving@000000005eed0001-100bpm.wav` is 1,746,404 bytes, identical
to `driving-2-100bpm.wav`, and peaks at the same 0.96. The arc — the part §7.29 step 4 argues
hardest for, five shapes chosen so a piece has somewhere to go — has never been rendered at the
default and therefore has never been heard.

At `render 160 32`, where four phrases and four fills do land in the file, nothing clips: the
loudest seeded piece peaks at 0.93. So the headroom claim survives; only the audition was empty.

#### Fixed — step 3, and the length becomes a property of the subject

**Bars belong to the subject, not to the command.** `render` rendered everything at one length,
which is wrong three different ways at once: a kit voice wants four bars of quarter notes, a ladder
backing wants whatever was asked for, and a seeded piece wants however long its arc is. The
`Subject` tuple carries a bar count now, and the render loop uses it for both the schedule and the
frame count.

The floor comes from `StyleArranger.barsForAFullArc()` rather than the literal `32` that was
already sitting in the generator call. That number is `defaultPhraseBars × arcPhrases`, and
`arcPhrases` is derived from the arc table itself — so **adding a five-phrase shape lengthens the
audition instead of being silently truncated by it**, which is `LESSONS.md` shape 9, two places
holding one value for different reasons. `barsForAFullArc(phraseBars:)` takes the phrase length as
a parameter for the same reason `StyleArranger.arrangement` does: M16 grows the phrase to 16 and 32
bars, and a test drives that case.

#### The decision was inside a function that writes files, which is how it survived

`runRender` builds its subject list, renders it and writes WAVs in one function, so "the seeded
piece is generated at 32 bars and rendered at 8" was a discrepancy **nothing anywhere could
observe** — `LESSONS.md` shape 1, and the reason this defect lived through a milestone of people
reading the code around it.

`Commands.renderSubjects(bars:)` is split out and `RenderSubjectTests` asserts against it.
`testTheRenderedLengthMatchesTheGeneratedLength` rebuilds each piece from its stored seed and
requires the arrangement to be equal, which is the defect stated exactly: not "the piece is short"
but "the piece is long and the render is short, and the two disagree silently". Reinstating the old
expression fails the suite **twenty ways**.

Two properties beyond the fix itself, because a floor for one subject must not become a floor for
all of them: everything that is not a seeded piece still renders at the length requested, and a kit
voice still renders at four. The console says so where they differ — and says *"a whole arc"* only
where that is the reason, since a four-bar kit voice has nothing to do with an arc.

| | before | after |
|---|---|---|
| `driving@000000005eed0001-100bpm.wav` at `render 100 8` | 1,746,404 bytes — identical to the 8-bar audition | **6,826,724 bytes, 32 bars, four phrases** |
| Peak | 0.96 | 0.96 |
| Files written | 44 | 44 |

Nothing clips at the new length and no peak moved, which is what the headroom test already
predicted. **The §7.31 review is closed.**

#### Heard, 8 August 2026 — and the verdict is the weakest of the three

> *"Listened to the 5eed001 files and they sound pretty good."*

**Recorded as given.** The two findings before this one came back *"sound good"* and *"all sound
nice"*; this is *"pretty good"*, and the difference is not worth smoothing over, because the arc is
the thing §7.29 step 4 staked a design decision on. The argument there was specific: intensity
moves along one of five shapes rather than being sampled per phrase, because **independent random
intensity sounds like somebody nudging a fader** — nothing is built to, there is no arrival, and a
listener cannot tell a section from an accident. "Pretty good" is acceptance of the mechanism, not
evidence that the shapes are the right five.

Do not read further into one listen than that (and the four files share a seed, so they are one
draw of the arc, not four). What it does establish is that the arc is now *auditable at all*, which
it was not before this change. Two things it leaves open, for M26 or for the professional ear
rather than for M19:

- **Whether five shapes is the right vocabulary**, or whether a piece wants something the table
  cannot express — a longer build, or an arrival that lands on a fill rather than beside one.
- **Whether the arc is doing the work or the kit is limiting it.** §7.29 step 6 already found the
  synthesised kit reads as *"beat #3"* rather than as a genre, and a lukewarm verdict on a shape is
  hard to separate from a lukewarm verdict on the sounds carrying it. That is M26's question and it
  should not be re-litigated as an arc problem.

### 4–7. Documentation

| # | Finding | |
|---|---|---|
| 4 | **`LESSONS.md` was not in the repository.** Ten code comments and eleven passages across the other documents cite a shape by number, and the only copy lived in gitignored `temp/`. A fresh clone had none: every `LESSONS.md shape 10` pointed at nothing | Fixed here — it is a tracked fifth document, `STANDARDS.md` §0 has its row and §9.7 the procedure, and `check.sh` fails when a citation names a shape that does not exist |
| 5 | `AGENT.md` said M19 steps 0 and 1 were done. Steps 0–6 are | Fixed |
| 6 | `AGENT.md` said "`rock` and `motown` are authored" **thirteen lines above** the paragraph explaining that those names came off in §7.30. It also carried the `Style.auditioned` paragraph twice, near-verbatim | Fixed |
| 7 | `TrainerKitTests` quoted at 157 in `AGENT.md` and `STANDARDS.md` §9.4.2; it is 161. `render` quoted at nineteen WAVs; it writes 43. `PLAN.md` §8's tree omitted two of the four test targets | Fixed, and the test counts are now checked by `check.sh` rather than by discipline |

Findings 4–7 are all `LESSONS.md` shape 17, and this is the **fifth** documentation pass to find
counts copied forward unchecked. Four passes of "re-derive the figures" did not stop the fifth from
finding more, which is the argument for the mechanical check rather than another instruction:
`check.sh` now derives the per-target test counts and compares them against every number quoted in
the three documents that quote them, and verifies every shape citation resolves. Both rules were
verified by planting a violation (R5.7).

### What this review did not cover

`GroovePlayer`, `MIDIInput`, `AudioIO` and calibration were not read closely; they are unchanged
since M15 and remain untested by anything but a live run (R5.6). Nothing in the analysis path was
re-derived beyond confirming `selftest` and the stored-take counts. **And the three kit findings
are all things an ear would have found faster than a review did** — findings 1 and 2 are both
audible, and finding 1 exists as a *number* only because §7.29 step 6b built the method for turning
"something clicks" into a measurement.

### Fix order

| Step | Fixes | Where |
|---|---|---|
| 0 ✅ | 4–7 — `LESSONS.md` into the repository, every stale figure, the enforcement | the five documents, `scripts/check.sh` |
| 1 ✅ | 1 — fade every one-shot, and give `render` a `kit-bass` file so the fix is audible | `TrainerKit/DrumSynth.swift`, `BassSynth.swift`, `Commands.swift` |
| 2 ✅ | 2 — the open hat supersedes the closed hat as the layers merge | `GrooveCore/Voices.swift`, `Style.swift` |
| 3 ✅ | 3 — render a seeded piece at its generated length | `GrooveCore/StyleArranger.swift`, `TrainerKit/Commands.swift` |
| then | M19 step 7, with §7.29's three hazards settled | |

Finding 1 went first because it is the one thing here affecting takes recorded today, and because
fixing it changes the sound of `jamBacking` — the music every take on record was played over. That
is a change to frozen material, and the discontinuity is recorded above with its date.

---

## 7.32 An honest correction gain

The first take over a generated backing was played on 8 August and reported
**`r₁ = +0.64  95% CI [+0.36, +0.63]`** — a point estimate outside its own interval. Checking six
other takes showed every r₁ interval skewed low, by more the larger r₁ was. Two separate defects
sat underneath, and a third thing standing in the way of the playing that exposed them.

### 1. The interval bounded a statistic the block bootstrap cannot estimate

`Bootstrap.interval` resamples contiguous blocks, which is right for the mean and the SD and
**self-defeating for r₁**: every join between two blocks is a pair that was never adjacent, so a
fraction ≈ `1/L` of the products are spurious and the resampled statistic is attenuated by about
that much. This file's own doc comment claimed the intervals "stay honest for the mean, the SD, and
r₁ alike". They do not.

Measured against AR(1) series with the correlation planted by construction — a nominal 95%
interval, and the fraction of trials that covered the truth:

| true r₁ | n | block bootstrap | large-sample SE |
|---|---|---|---|
| 0.15 | 122 | 94% | 94% |
| 0.40 | 122 | **80%** | 96% |
| 0.40 | 492 | **72%** | 95% |
| 0.64 | 122 | **25%** | 93% |
| 0.64 | 492 | **24%** | 94% |

The observed attenuation, 0.70–0.85× the true value, matches `1 − 1/L` from the block joins.
**It hid for thirty takes because this player's r₁ had never left 0.13–0.50**, and the failure is
invisible at the bottom of that range — `LESSONS.md` shape 6, a derived quantity that is honest at
one end of its axis and misleading at the other.

`Bootstrap.lag1Interval` uses `√((1 − r²) / n)` with `n` the pairs actually summed. Coverage holds
across the whole range, and reverting fails `CorrectionGainIntervalTests`.

### 2. r₁ paired notes either side of a rest

`Stats.autocorrelation` pairs element *n* with *n+1* and asks nothing about what sat between them.
The correction gain asks *did the last error predict this one*, which presumes the second note is
close enough to be a response to the first — and two notes either side of four beats of silence are
not. Same shape as §7.25, where a gap broke the x-axis a slope was fitted against.

`Stats.gappyLag1` splits at any gap wider than a beat. A beat is the threshold because the beat
*is* the pulse being tracked and 78.4% of every matched note in a free jam sits one beat from the
last; eighths and sixteenths are a stream and pair normally.

#### Centring per run, and the measurement that decided it

The first implementation used one global mean and dropped only the seam products. A deliberately
broken fixture exposed the flaw — `LESSONS.md` shape 16, the probe failing rather than the code,
and useful anyway: with a global mean, **a placement shift across a rest reads as correlation**.
Every note in a run sits the same side of a mean lying between the runs, so the products are large
and positive whatever the player did.

Simulated at his own 23 ms spread, with the correlation planted at zero:

| runs of | global mean, 15 ms shift | per-run mean, any shift |
|---|---|---|
| 10 | **+0.265** | −0.106 |
| 25 | +0.242 | −0.042 |
| 60 | +0.217 | **−0.012** |

Global centring invents a quarter of a correction gain out of a player who corrected nothing, and
take-to-take bias in this project already ranges −7.6 to −24.8 ms, so a shift of that size across a
rest is ordinary rather than pathological.

Per-run centring is immune to it and costs roughly `1/n` of downward bias instead — **and that bias
points at r₁ ≈ 0, which §10 defines as success.** A method that drifts toward its own success
criterion is the more dangerous direction, so the floor is set where the drift stops mattering:
`Stats.minimumRunLength` is 30, between the −0.042 and −0.012 rows. A take with no run that long
reports **no r₁ at all** and says why, which is R3.3.1 rather than a number nobody should read.

#### What it did to the corpus

Every take recomputes from raw taps (R3.1), so all thirty-two moved. Most by little; the largest
are the takes with the most breaks in them.

| | |
|---|---|
| Median absolute change | 0.04 |
| Largest | take 7, +0.20; take 15, −0.24; take 30, +0.12 |
| Takes losing r₁ entirely | **none** — every take has a run of 30 |
| Sign changes | **one** |

**Take 15 now reads −0.06, and it is the first negative r₁ in the corrected corpus.** Read nothing
into it: its interval is `[+0.03, +0.27]` under the old method and it is a small number either
side of zero. What it does mean is that `AGENT.md`'s "positive in all 30 jams, with no negative
reading ever recorded" is no longer true and has been corrected there.

The trend verdicts did not move: `review trend` still reports r₁ flat on every group.

### 3. The instructions asked for less than the drill allows

*"Aim every note at a beat or an off-beat"* describes quarters and eighths, and a free jam has been
scored on a **sixteenth** grid since M4. *"Don't stop and start"* forbids a rest, which costs
nothing measurable. R3.6 says instructions are generated from the configuration that will actually
run, and these were narrower than it — the drill was quietly asking for a plainer performance than
it needed, in the one place the app speaks to a player who cannot look at the screen.

The player put it plainly: *"when jamming I really want to add a quick break / silence or a mixture
of different length notes, it really changes the feel and keeps things spicy."* Nothing in the
analysis was stopping that. The text was.

Both remaining pitfalls are the ones that are true: a note aimed between grid points really is
discarded, and a take made only of short bursts really does lose its correction gain.

### Withheld rather than shown wrong

`review compare` and `review conditions` still bounded r₁ with the block bootstrap, and the pooled
path is worse still — `resamplePool` concatenates a block-resampled series *per take*, so every take
boundary is a spurious adjacency on top of the block joins. Both now **withhold r₁ and say so**
rather than print a figure that answers a different question from the one `review <n>` prints for
the same take (R3.3.1).

Fixing them is a difference of two large-sample intervals and, for the pooled case, the plain
bootstrap over per-take values that R3.2's own table already prescribes. It was queued as its own
change rather than folded in: three readouts, three guards, and that branch was already two
analysis changes deep.

#### The queued change, as built

Three readouts, three methods, and **none of them a block bootstrap**.

| Readout | Unit | Method |
|---|---|---|
| `review compare` | two takes | `Bootstrap.lag1Difference` — independent samples, so the variances add |
| `review tags` | takes within one condition | `Bootstrap.pooledLag1Interval` — one value per take, resampled over takes |
| `review conditions` | two conditions of takes | `Bootstrap.plainDifference` over per-take r₁ |

The third needed no new function: `plainDifference`'s own doc comment already said it was *"the
right tool for comparing conditions when the unit of analysis is the take"*, and r₁ is exactly
that. What it had been given instead was `pooledDifference`, which concatenates a block-resampled
series per take — a spurious adjacency at every take boundary on top of the block joins.

**The guard is a false-positive rate, not an example.** Two takes drawn from the *same* planted
correlation but deliberately different lengths — 120 notes against 480 — must be called "within
noise" about as often as the level says. The old method could not do that in principle: it
attenuates each side by an amount depending on that take's own block length, so two equal takes of
unequal length differ by construction. Over 200 pairs the new method calls a real change under 12%
of the time, against a nominal 5%, and finds a genuine 0.10-against-0.60 difference every time.

The pooled interval's guard is the one §7.20 finding 1 established: four takes agreeing and four
scattered around the *same* mean must not produce the same interval. The scattered set's is more
than three times wider.

**A take with no r₁ is named rather than silently dropped.** A comparison where either side has no
continuous run says so; a condition where some takes contribute none says how many, because the r₁
row then rests on fewer takes than the rows above it (R3.3).

#### What it shows now

`review conditions relaxed focused` reports r₁ +0.32 against +0.35, change +0.02 [−0.05, +0.11],
within noise — and the tempo confound above it is still the reason not to read even that. The two
style takes compare at +0.41 against +0.55, change +0.13 [−0.18, +0.45], within noise, under two
comparability notes naming the backing *and* the style.

Nothing here changes a point estimate. All three intervals were absent an hour ago and wrong
before that.

#### And the wrong pairing is now unrepresentable

The four block-resampling entry points took any `([Double]) -> Double`, so "block-bootstrap my
autocorrelation" was a thing anybody could write — and four call sites did, for thirty takes.
Removing the callers fixed the instances and left the *spelling* available.

`SeriesStatistic` is a closed set of `.mean` and `.sd`. There is no autocorrelation case, so the
pairing cannot be written at all: the same move as `PlannedBacking` replacing two optionals that
could disagree, and stronger than the `check.sh` rule first considered, which would have missed a
call wrapped across two lines (`LESSONS.md` shape 2 — a guard that looks right and matches nothing).

Adding a case forces the right question: **does block resampling preserve what this statistic
measures?** For the mean and the spread it does, which is why they are there. For anything reading
*across* neighbouring points it does not.

A one-line `check.sh` rule remains as a backstop for the symbol itself, since a `lag1Stat`-shaped
constant reappearing beside the others is how a closed set gets quietly reopened. Verified by
planting one and watching it report FAIL (R5.7).

`CorrectionGainIntervalTests` still demonstrates the defect, but it now builds the old pairing by
hand — the clearest statement that the pairing is gone: the test that proves it was wrong can no
longer express it through the API.

### What this does not settle

The r₁ **point estimate** is what moved; nothing here revisits what it means. Whether a jam played
with deliberate breaks produces a different correction gain from one played straight is now
*askable* and unmeasured — the corpus has one take (32) with 22 breaks in it and no controlled
comparison. `MusicalContent` is where that question would go.

---

## 7.33 M19 step 7 — the planner picks a band

The last piece of M19, and the first that changes what a planned session sounds like.

### The styles are approved, 8 August 2026

> *"I do formally approve all the styles."*

`Style.auditioned` was `false` from the day it was written, and flipping it **failed three tests** —
`StyleTests`, `LockedSlotBackingTests` and `StyleRequestTests` — which is what §7.29 step 5 built
it for: an approval that arrives in a diff rather than drifting in unnoticed.

**What each approval rests on is not the same, and the record says so rather than smoothing it:**

| Style | Basis |
|---|---|
| `driving` | **Played over twice**, 32 bars and 128 bars. The long take is where the intensity arc first repeated |
| `half-time` | **Played over once**, 128 bars — and rated lowest of the two, which is what §7.29 step 5 predicted for the sparsest style |
| `pocket` | Listened to at every intensity and to its seeded piece. **Never played over** |
| `syncopated` | The same |

§7.29 step 5's argument is that whether a groove is worth thirty minutes is answered by playing over
it, not by listening. Two of these four were approved on the weaker basis, which is the player's
call and is recorded here so that a later disappointment with one of them is legible rather than
mysterious.

### The refusal became untestable, and that is a shape

With every style approved, `resolveStyle`'s unauditioned branch had **nothing left to refuse** — so
the guard that stops an unheard style reaching a take could no longer be exercised by any test, and
the next style authored would have landed unguarded. `LESSONS.md` shape 1 arriving through a *data*
change rather than a code one, which is a new way for it to happen here.

`resolveStyle` takes the library as a parameter now, defaulting to `StyleLibrary.all`, and the test
constructs an unapproved style to refuse. The complement is asserted too: all four approved styles
go through without `--probe`, or the approval bought nothing.

### One slot gets a band, and it is the closing jam

§7.29's table says training blocks and the closing jam get deep music. In practice **the closing jam
is the only free jam a planned session contains**: the ladder training block carries a rung, and a
rung and a style are two backings that cannot both play — the ladder groove exists to make its
division audible and a style does not. Everything else in a session is a different drill.

So the closing jam it is, which is also the right one on its own terms: the musical payoff, and the
longest stretch of playing in the evening.

| | |
|---|---|
| Style | `nextStyle` — min-count over what has been played, ties broken by a seeded draw |
| Seed | `sittingSeed` — one per sitting, so an evening has a single musical identity |
| Locked slots | untouched: `nil`, for ever (R3.5) |
| Nothing approved | `nil`, and the closing jam plays `jamBacking` — what every take on record used |

**Min-count rather than a cycle**, for the reason `nextLadderTempo` and `ExperimentSchedule` both
use it: a strict rotation puts each style at a fixed position in the sequence, so anything that
varies with *where in a run* a take falls lands entirely on one style. A test drives four sittings
and requires four different bands.

**The seed comes from the history, not the clock.** The planner is pure (R1.1.4) — a plan that read
the time could not be tested, and `session plan` would stop being an honest preview of `session`.
Two plans from one history are the same plan, and a test says so.

### Where the gate actually bites

One line, in `TrainerEngine`:

```swift
auditionedStyles: StyleLibrary.auditioned.map(\.name)
```

`TimingCore` cannot see a `Style`, let alone its flag, so filtering *here* is what makes it
impossible for the planner to reach past the gate — rather than a rule the planner is trusted to
follow. The planner can only ever choose from the names it was handed, and a test asserts that
handing it one leaves it scheduling only that one.

### The plan says what it will play

```
9. Jam  closing · 100 BPM · 176 bars · 7 min
   Finish by playing… Tonight the band is syncopated, one piece all evening —
   syncopated@c8c135f2e61ba989.
```

The preview did not say this at first, and a session that cannot say what it is about to play is one
the player has no way to disagree with — which is what every other `reason` in the planner exists
for. The seed is named because it is the only route back to that exact piece.

### What this does not cover

**No planned session has been run with a band yet.** Every assertion here is against planted
histories; the live path is the same `runJam` that three CLI takes have now exercised, but a whole
evening ending on a generated backing has not happened. R5.6, and it is the next live run worth
booking.

### Step 8, as built — reproducing a take's music, and closing the milestone

`render --style driving@06965a16872036af` writes that one piece and nothing else. **The argument
takes the name a take stores**, so reproducing the music a take was played over is a copy and a
paste rather than a transcription — which is the audio half of R1.2.2, and the reason the seed was
stored at all. `--style driving --seed 0696…` is the same thing spelled apart, and an explicit
`--seed` wins over one embedded in the name because it is the more specific thing the player typed.

**An unapproved style renders.** `render` is how a style gets listened to in the first place, and
§7.29 step 5 exists to stop the *planner* promoting somebody onto music nobody has heard — refusing
to let them hear it would invert the rule. `jam` still refuses without `--probe`.

The resolution lives in `Commands.renderTarget` rather than inside `runRender`, which writes files:
the same seam as `resolveStyle`, for the same reason, and a test reaches it.

#### M19 is built, and it has not been played

Steps 0–8 are complete. **No planned session has ended on a generated backing**, and nothing has
been recorded from the app's picker — three CLI takes exist over styles, all `--probe`, all in the
small hours of 8 August and tagged `tired`.

So the milestone is closed on paper and its central claim — that a generated backing reaches a take
intact through the planner — rests on planted histories (R5.6). `session 45` is the run that would
settle it, and `temp/WORKING.md` names the three things to watch.

### The app catches up

**A band picker on Jam and Play**, offering `StyleLibrary.auditioned` and nothing else. The CLI can
reach an unapproved style with `--probe`; the app deliberately cannot, because a picker is not a
deliberate look at something unearned — §7.26's distinction, applied to a surface rather than a
flag. When nothing is approved the row does not appear at all: a control whose only option is
"Fixed" is a control that does nothing, and the honest reading of an unapproved library is that
there is no choice to make.

**The two pickers clamp each other.** A rung and a style are two backings and `JamConfig.validate`
refuses the pair, so choosing a band clears the subdivision and choosing a subdivision clears the
band — the same discipline as `clampFeelToRung`, and for the same reason: a picker that can ask for
something the engine will refuse is a failure deferred to Start.

**`Play` gets a band too**, and it is the one mode where a style costs nothing to get wrong: it
measures nothing, so no locked slot and no trend can be touched by what it plays. `GrooveConfig`
resolves it exactly as `JamConfig` does, so Play and Jam cannot disagree about what a style sounds
like.

**Both surfaces name the band from one place.** `BlockPlan.settingsLabel` gained it, which is the
only mapping from a plan to its summary line — so the app's session view and the console's plan
preview cannot describe the same block differently, the same reason `DrillInstructions.forBlock` is
one function and not two. The *reason* explains the choice; the label says what it is:

```
9. Jam  closing · 100 BPM · 176 bars · syncopated · 7 min
3. Jam  benchmark · 100 BPM · 64 bars
```

A locked slot has no band to name, and does not.

**The seed is drawn when the band is chosen** and re-drawn whenever it changes, so two takes in a
row are two pieces of music and a take left set up is the same one it was. `bandAdvice` names it on
screen for the same reason the CLI prints it: it is the only route back to a piece the player
liked.

---

## 7.34 The first session with a band — 8 August

Forty-five minutes asked for, forty-seven played, ten of ten blocks completed. The first planned
session ever to end on generated music, and the live run M19 had been closed without.

> *"It was great, much more interesting than what we had before. It is a very good start."*

### M19 is verified

The three things §7.33 said to watch, all from the stored takes rather than from the screen:

| | |
|---|---|
| The band the plan announced reached the take | `syncopated@c8c135f2e61ba989` — the seed the preview printed |
| Both closing blocks share one seed | both `syncopated@c8c135f2e61ba989`, 176 bars each |
| The locked slots kept the fixed backing | benchmark and experiment both `jamBacking` |

`review trend` puts the two closing takes in their own group and leaves *"Jams at 100 BPM"* holding
23 takes of `jamBacking` and `basicRock`. The trend split of §7.32 and the planner of §7.33 both
work on real data, which until now they had only done against planted histories (R5.6).

### A voice hung, and the take it spoiled is kept rather than dropped

During the tenth block a note *"hung and just continued to ring out like I was just holding the key
down… no audible response from the keys after that, just the one tone steadily going."* The drums
and the app were unaffected.

The cost is visible in the data. Two closing takes, same length, same backing, minutes apart:

| | matched | extras | rated |
|---|---|---|---|
| Block 9 | 955 | 250 | 3 |
| Block 10 | **684** | 157 | **1** |

Twenty-eight per cent fewer notes over identical bars — the shape of a player who stopped because
he could not hear himself.

#### Four candidates, and what separates them

| | Explains the hung tone | Explains the silence after |
|---|---|---|
| A dropped note-off from CoreMIDI | yes | **no** |
| **The source disconnecting mid-take** | yes | **yes** |
| The event ring filling and dropping events | yes | yes, but needs 512 events between two render calls |
| Voice exhaustion at 16 voices | no — stealing replaces the oldest, it does not silence the keyboard | no |

**The second is the only one that explains both symptoms**, and there is a structural reason to
suspect it: `MIDIClientCreateWithBlock` is called with a **nil notify block**, so the app receives
no CoreMIDI notifications at all — not `kMIDIMsgObjectRemoved`, not `kMIDIMsgSetupChanged`. Sources
are connected in `begin()` and never re-examined. A keyboard that drops off the bus mid-take is
invisible: no further note-ons, no further note-offs, and whatever was held at that moment sustains
for ever.

That is a gap whether or not it caused this incident, and `midimon` during a session is what would
distinguish the candidates.

#### And nothing can recover a stuck voice

Independent of the cause: `LiveInstrument.release(note:)` is the only path out of a sounding voice.
There is no all-notes-off, no maximum sustain, and no periodic reconciliation — so a voice that
misses its note-off rings until the engine stops. **The cheap half of the fix is a ceiling on how
long any one voice may sound**, which converts "for ever" into "a few seconds" regardless of which
candidate is right.

#### The take stays in the corpus

Block 10 is compromised and it is **not** being excluded. This project's own rule is that data is
never quietly dropped and that any exclusion is declared *before* collection, not after — a take
thrown out because its number is inconvenient is the failure that rule exists to prevent, and
"inconvenient" and "explained" look identical in hindsight. R6.2 says the same from the storage
side.

So it is recorded here instead, and anything reading that take should read this with it: **block 10
of 8 August is a take played for part of its length on a silent instrument.** The spread it reports
(33.1 ms) is not a fact about the player.

**What is missing is a way to say so on the take itself.** `tag` is the only field that could carry
it and it is set before a take runs, not after. A field written afterwards would be exactly the
post-hoc exclusion mechanism the rule forbids — so the honest options are a note in this document,
which is what this is, or a *declared-in-advance* incident field. That is a real design question and
it is not settled here.

### The offbeat drill is not in the app, and the app does not say so

*"I tried to do the offbeat from the app and I could not because the selector was disabled no matter
what I did."*

There is no offbeat mode in the app — it has been CLI-only since M15 and §7.24 records that as the
milestone's one surface gap. What the player found instead was the **Feel** picker, which is
disabled unless a binary rung is chosen, and which said the wrong thing about why.

`AppModel.feelAdvice` returns *"Triplets are the division swing borrows from, so there is no pair to
swing"* for **any** rung that cannot swing — including quarter notes, where triplets have nothing to
do with it. Visible in the player's own screenshot: Subdivision reads *Quarter Notes* and the advice
talks about triplets. A control that is disabled and explains itself wrongly is worse than one that
is merely disabled, because the reader trusts the explanation and goes looking for the wrong thing.

Two separate fixes: the advice must branch on *why* the rung cannot swing, and the offbeat drill
needs a mode in the app.

### Mid-take feedback: two requests, two different answers

> *"In the middle of a take there is no indication you are being measured. It just continues to say
> press enter… On the longer takes it is easy to lose track of time."*

These read as one request and are not.

**Presence — yes, everywhere, and it is not a §2 question.** §2 forbids *numbers* on screen because
a live meter recruits the analytical loop the project exists to quiet. "You are being recorded"
evaluates nothing and locates nothing. The app already has this: `TakeView`'s breathing circle,
which says the take is live and nothing else. **The console has no equivalent at all** — it prints
the instructions, waits for return, and then goes quiet for up to seven minutes, which is why a take
in progress reads as a take not yet started.

**Position — yes, but not in two of the drills, and that is the whole of the design.**

| Drill | Progress indicator | Why |
|---|---|---|
| Jam, offbeat, recall, play | fine | They train placement or a held feel; how far through the take you are says nothing about either |
| **Form** | **never** | Knowing where you are in the piece *is* the skill. `TakeView`'s own comment names it: a progress indicator "would replace the felt sense of the phrase with a visual count" |
| **Continuation** | **never** | The drill measures holding a pulse with no external reference during a measured silence. **A steadily advancing bar is an external time reference** — it is a clock, and the clock is the thing being tested |

The continuation case is the one that would have been missed. It is not about self-monitoring at
all: an advancing indicator is *information the drill exists to remove*.

Where it is shown, the shape matters. **Time remaining, coarse, and never beat-locked** — "about two
minutes left" rather than a percentage that ticks, because anything advancing smoothly enough to
count against is something a player will count against. That is the same reasoning that keeps the
tempo drill's feedback in the click bars and out of the measured silence.

None of this is built. It is a change to a stated non-negotiable and wants the player's agreement on
the two exclusions before anything moves.

---

## 7.35 The hang recurred — 10 August, and what the second instance rules out

A jam asked for with **swing** — so a binary rung over `jamBacking`, since a rung and a style cannot
both play — failed the same way from the *start* of the take: one droning note, keyboard
unresponsive, drums and app unaffected. The take was stopped and discarded rather than analysed. A
second jam started immediately afterwards ran clean and is on record as
`pocket@c7da4f6fc6dbf25d`, 32 bars, tagged `relaxed` and rated 3.

### The backing is not the variable, and the pair proves it both ways

| | 8 Aug, block 10 | 10 Aug, hung | 10 Aug, retry |
|---|---|---|---|
| Backing | `syncopated@…`, **generated** | `jamBacking`, **fixed** | `pocket@…`, **generated** |
| Rung / feel | none — free | binary rung, **swung** | none — free |
| When | mid-take | from the start | — |
| Outcome | hung | hung | **clean** |

A generated backing sits on both sides of the outcome and a fixed backing produced a hang, so the
music M19 generates is not implicated. Neither is take length, the style picker, nor the planner —
the 10 August failure came from the app's Jam mode with no plan involved. **No single configuration
value is common to both failures**, which is itself the finding: this does not look like a code path
selected by a setting.

That retry is also the first take ever played over `pocket`, which §7.33 recorded as approved on
listening alone.

### What the code says without a live run, by elimination

Reading the audio path settles where the fault is *not*, which the four-candidate table in §7.34
could only guess at:

- `LiveInstrument.freeVoiceSlot()` **steals the oldest voice** when none is idle, so exhaustion at
  16 voices cannot silence the keyboard — a seventeenth note displaces the droning one instead.
- `LiveInstrument.render()` drains the **whole** event ring on every callback, so the ring filling
  cannot persist while audio is running.
- The drums kept playing, so the render callback *was* running.
- `GroovePlayer` and its `LiveInstrument` are built per take, so no state survives from a previous
  one.

Which leaves one conclusion: **the events stopped reaching `enqueue` at all.** The fault is upstream
of the synthesis, and a voice sounding at that moment never receives its note-off — which is exactly
one tone ringing on while nothing new sounds. §7.34's third and fourth candidates are eliminated;
its second is narrowed to "delivery stopped", without yet saying why.

### A second defect, which would stop the app recovering from the first

`MIDIInput.connectedSources` is **inserted into and never pruned** — three mentions in the file, no
removal anywhere. `connectSources()` skips any source whose unique ID is already in that set, so a
keyboard that drops off the bus and returns under the same unique ID, which CoreMIDI preserves per
device, **is never reconnected** and stays dead for every later take until the app is relaunched.

It constrains the diagnosis as well as the fix. The 10 August retry worked immediately, so either
that instance was not a disconnect, or the device returned under a different identity — a plain
disconnect-and-return would have left the keyboard dead. And it means §7.34's notify block buys
nothing on its own: being told the device left is useless while the reconnect path refuses to run.

### A latent out-of-bounds read, found while reading

`GroovePlayer.render` mixes `scratch[f]` across the full `frameCount`, but `LiveInstrument.render`
clamps its own work to `scratchCapacity` — 8192. A buffer larger than that would be mixed from
memory the instrument never wrote. **Not reachable today**: nothing sets `maximumFramesToRender`, so
AVAudioEngine's default of 4096 applies. It is one device or one configuration change from being
live, and it is in the same file as the fix above.

### Fixed — the instrument releases a voice nothing released for it

**`LiveInstrument.maxSustainSeconds`, 8 s.** A voice tracks how long it has sounded unreleased and,
past the ceiling, sets its own release using the identical slope `release(note:)` sets — so a voice
that times out is indistinguishable from one that was let go, rather than being cut off.

**This is not a fix for the cause, and it is not offered as one.** It converts "for ever" into a few
seconds whatever the cause turns out to be, which is worth having on its own: both hangs ended a
take, and neither had to.

**Why 8 seconds, and why the *lower* bound is the interesting one.** A whole bar of four beats at
40 BPM — the slowest tempo any drill accepts — is 6.0 s, so a bar held at the slowest tempo the app
offers still rings in full. A ceiling below that would cut off real playing, which is why
`MaxSustainTests` asserts that end too. **If the 40 BPM floor is ever lowered, nothing notices**:
that floor is a literal repeated at eight call sites rather than a shared constant, so the test pins
the ceiling and not the relationship. Said here rather than implied, per shape 21.

**It cannot move a measured number**, and that is what makes the ceiling safe to be aggressive
about. Everything analysed derives from note *onsets* — `MIDINoteOn`, `tapTimes`, the raw note-ons —
and nothing reads a note's duration anywhere. The worst case is a held note fading under a finger
still holding it: audible, and invisible to every statistic.

`MaxSustainTests` asserts against `LiveInstrument` itself rather than a reimplementation of its
envelope, because the claim is that the *shipping* voice loop times out (shape 1). Deleting the
`heldSamples` block leaves the voice at **0.223** amplitude nine seconds in and fails the test.

### Fixed — the mix can no longer read past what the instrument wrote

`render` returns `(samples, count)` instead of a bare pointer, and `GroovePlayer` mixes to `count`
then soft-clips the remainder. The bound stops being something the caller has to remember and
becomes something it cannot get wrong — the same move as `SeriesStatistic` closing the set a block
bootstrap may resample (§7.32). The tail past the instrument's frames still goes through `tanhf`, or
an oversized buffer would leave the drums unlimited on its remainder.

### What is still not established

**The cause.** Two instances, both described from the player's chair, nothing instrumented. The
elimination above narrows *where* the fault is without identifying it, and `midimon` alongside a
session remains what would separate the survivors — LESSONS.md shape 16, whose whole subject is
acting on a diagnosis no probe confirmed.

**So the two fixes above are the half that does not depend on knowing.** What they do not do is
leave evidence: the notify block and the `connectedSources` pruning are still unbuilt, and until
they exist a third instance will produce another description rather than a record. That is the next
branch, and it is the one that actually advances the diagnosis.

---

## 7.36 The app notices the keyboard leaving

§7.35 closed with the point that mattered: the two fixes it recorded make a hang *survivable* and
do nothing to make one *diagnosable*. This is the other half. It does not identify the cause either
— it makes the next instance leave something behind that is not a description.

### The notify block, which was `nil` for the life of the project

`MIDIClientCreateWithBlock(…, nil)` meant the app received **no CoreMIDI notifications at all**: not
`kMIDIMsgObjectRemoved`, not `kMIDIMsgSetupChanged`. A source leaving mid-take produced no note-ons,
no note-offs, and no record — which is precisely why two hangs left nothing but the player's account
of them.

Two messages are acted on and the rest ignored. Property changes, IO errors and thru-connection
edits are noise for this question, and a readout that fires on all of them is one nobody reads.

### The connection set forgets, so a returning device is reconnected

The insert-only `Set<MIDIUniqueID>` is gone. `MIDISourceRegistry.sourceRemoved` drops the ID, so a
keyboard returning under the same unique ID — which CoreMIDI preserves per device — is connected
again instead of being skipped for the life of the process.

**A setup change deliberately forgets nothing.** It is not evidence that any particular source
left, and clearing the whole set would reconnect sources already connected, which delivers every
event twice and makes the pairing step discard the beat. The coarse signal is recorded without
being acted on.

### The rules moved somewhere a test can reach them

Every decision here used to sit inside functions that talk to CoreMIDI, where **no test can run** —
which is why an insert-only set survived to be found by reading rather than by failing. That is
`LESSONS.md` shape 1, and the guard it prescribes is exactly this: move the decision out.

`MIDISourceRegistry` is over `Int32` rather than `MIDIUniqueID` — the same type, since the latter is
a typealias — so neither it nor its tests import CoreMIDI and the rules run anywhere.
`MIDISourceRegistryTests` covers the reconnect, the double-connect guard, the zero-ID case, take
boundaries and ordering. Deleting the `connected.remove` fails it.

### An incident is recorded, and recorded is all

`JamOutcome.midiIncidents` carries what happened, with `mach_absolute_time` on the same clock as
every captured note, so an incident is placeable against the notes either side of it.

**This is not the field §7.34 refused, and the difference is who writes it.** §7.34 rejected a way
for the *player* to mark a take compromised after the fact, because a take marked bad in hindsight
is post-hoc exclusion however carefully it is worded, and "inconvenient" and "explained" are
indistinguishable once the numbers are known. An incident is written by the machine, during the
take, from an event that either happened or did not. It carries no judgement about the playing.

**Nothing reads it to act.** No filter, no exclusion, no reweighting — an exclusion rule is declared
before collection (R3.5), and this is a record rather than a verdict. The readout says so in those
words, because a warning next to a number invites exactly the inference the rule forbids.

### Where it is shown, and the question that is not settled

The console prints it **with the results, after the rating**. That is the conservative side of a
genuine question rather than a settled answer:

- **For showing it first**: a player whose keyboard died would otherwise rate his own playing for an
  equipment failure, and that is noise landing directly in `review feel`'s correlation.
- **Against**: §2 takes the rating before anything the take produced, and this is something the take
  produced.

Left as it is until the player says otherwise.

### What this does not cover

**The cause is still not established.** This branch is instrumentation, and instrumentation that has
never fired. It says what CoreMIDI reports; it cannot say what happens if CoreMIDI reports nothing —
and "delivery stopped with no notification" remains a live candidate that would produce an *empty*
incident list on a hung take. **An empty list is therefore not evidence the connection was fine**,
and the readout is worded so it cannot be read that way.

**None of it is tested against CoreMIDI, and none of it can be.** No unit test can remove a device.
The registry's rules are covered; the wiring — whether the block is installed, whether the messages
arrive, whether the payload is read correctly — is verified only by a live run (R5.6), and no live
run has happened.

### `midimon` can now watch a whole session, which is the experiment

`MIDIMonitor.run` always accepted a length and `main.swift` never passed one, so the command was
fixed at 20 seconds — a "does the keyboard work" check, and useless for watching a take that fails
after seven minutes. `midimon <seconds>` is the diagnostic this whole investigation has been
waiting on.

**It is a second process with its own CoreMIDI client**, which is how it discriminates. Run beside a
session, the two candidates left after §7.35's elimination separate cleanly:

| What `midimon` sees when the app goes silent | What it means |
|---|---|
| `midimon` **also** stops receiving | The source stopped sending — a device or driver fault, and the app is the victim |
| `midimon` **keeps** receiving | The device is fine and the app stopped listening — the fault is ours |

That is a genuine fork, and nothing available before could tell the two apart.

**Two caveats worth stating before the run rather than after.** A second client connected to the
same source is a change to the conditions, so this is not quite the configuration the hang occurred
in — an observer effect is possible and would itself be informative. And `midimon` prints a line per
packet, so a session's worth belongs in a file rather than a terminal scrollback.

**Incidents are not stored on the take.** They reach the console and stop there, so a hang recorded
today is legible in the moment and gone by the next session. That is a deliberate hold rather than
an oversight: R6.3 argues for the field on the grounds that a take recorded without it is lost to
the question for good, and §7.34's argument about who writes a field applies here as it does above.
It is the first thing to build if the player agrees.

---

## 7.37 The diagnostic session that produced nothing, and why

A 20-minute planned session was played on 11 August with the §7.36 instrumentation live and
`midimon` watching. **It produced no diagnostic data at all**, for three separate reasons, two of
which were defects in the diagnostic rather than in the thing being diagnosed.

### What the session did establish

**No hang.** Eight of eight blocks, 22.9 minutes against 20 asked, nothing skipped.

**The instrumentation is live and harmless.** The app binary the session ran on was verified to
contain `MIDISourceRegistry` — 15 symbols — rather than assumed to. A full session with the notify
block installed behaved exactly as before, which discharges "does this destabilise the normal path"
and nothing else. It says nothing about whether it *detects* anything, because nothing happened.

The takes are unremarkable and one is worth noting: the benchmark read **26.4 ms**, the highest of
the six in that locked slot — 24.1 → 17.4 → 22.0 → 21.7 → 24.9 → 26.4. Still bouncing in one band
rather than trending, which is what §7.21 already said about it.

**The tempo axis finally has data.** `review interval` now spans five distinct intervals — 250, 429,
500, 545 and 600 ms — where it recently had one interval carrying 61% of every note. Everything is
within noise and the readout says so, including that "easier to a point" is a claim about an optimum
that five points and a straight line cannot carry. Recomputed rather than eyeballed: 17.3 ms at
140 BPM against ~24.7 at 100 *looks* like absolute spread falling with the interval, and the fit is
−0.27 ms per 100 ms [−4.71, +4.66]. It is not a finding.

### Defect 1 — the log was empty, and a working run looked exactly like a broken one

`midimon 3000 2>&1 | tee temp/midimon-session.log` produced a **0-byte file**. C stdio block-buffers
when stdout is not a terminal, so every line sat in a 4 KB buffer, and `^C` is SIGINT, which does not
flush. Fifty minutes of watching went in the bin.

Measured rather than reasoned about: the same binary redirected to a file holds **0 bytes during the
run and 888 after a normal exit**.

The worst part is not the loss. The monitor prints its header — device list, source list, port
status — *before* it starts watching, so with the buffer swallowing that too, **the terminal showed
nothing whatsoever and a correctly running diagnostic was indistinguishable from a hung one.** The
session was played on the assumption it was recording.

`setvbuf(stdout, nil, _IOLBF, 0)` in `main.swift`, globally rather than in `midimon`, because every
readout here is something somebody may pipe into a file.

### Defect 2 — it only ever printed the first twelve packets

The deeper one, and it would have survived the buffering fix. `midimon` prints packet detail under
`if umpCount <= 12` and then counts silently to the end. That is right for the check it was built
for — *does the keyboard work* — and useless for the question it was being asked, because **a log
that stops after twelve notes cannot show the moment delivery stopped**.

So the run loop is sliced instead of blocking once, and a watch longer than a minute prints a
heartbeat every five seconds: wall-clock time, packets since the last beat, running totals, and a
**`— silent —`** marker when a slice was empty. That marker is the experiment. A session's log is
now a timeline of when the keyboard was and was not sending, in about 600 lines rather than one per
note.

Below a minute nothing changed, and the twelve-packet detail limit stays — it verifies the delivery
format, which is what it is for.

### Defect 3 — the app could not show an incident, and the app is where they happen

§7.36 wired `reportMIDIIncidents` into the console and **nowhere else**. Both hangs happened in the
app; this session ran in the app. Had an incident fired, nothing would have been shown.

R3.4 requires both surfaces to warn identically and this failed it for a whole branch.
`MIDIIncidentNotice` now sits **above** the numbers in the results view, because it changes how they
should be read rather than annotating them, and it draws nothing at all on a healthy take.

### The quarantine is dropped

§7.36 left a designed-but-unbuilt path: a take that ran through an incident would be dumped to a log
directory and kept out of the corpus. **It is not being built**, and the reasoning is worth keeping
because the argument for it was sound.

- **It has happened twice in the project's life.** Handling the third by hand costs less than
  building and maintaining an automatic route-and-drop path, and §7.34 already handled block 10 that
  way successfully.
- **Automatic exclusion is delicate in exactly this codebase.** R6.2 and R3.5 are satisfiable, but
  every future reader of the corpus would have to know that a silent filter exists, and a filter
  nobody can see is indistinguishable from quietly dropping the data that spoiled the answer — the
  thing shape 18's guard exists to prevent.

**And no debug build flag**, which was the other candidate. A mode switched on when trouble is
expected cannot catch trouble that is not: the hang fired twice, unpredictably, ten days apart, and
a deliberate attempt to provoke it produced nothing. **A flag would have been off on both occasions
that mattered.** What is left always-on is a bug fix rather than instrumentation — an insert-only
connection set is a defect, and being deaf to `kMIDIMsgObjectRemoved` is a defect — plus a readout
that costs nothing and draws nothing until the day it does.

### What is still not established

**The cause.** Three sessions have now been played since the first hang without reproducing it, one
of them deliberately instrumented. The instrumentation has never fired, so **it remains unproven in
the only case it exists for** — and an empty incident list is still not evidence that the connection
was healthy, because "delivery stopped with no notification" would look exactly like this.

What is different is that the next occurrence leaves a timeline: the app says an incident happened,
and `midimon`'s heartbeat says whether the keyboard was still sending when it did.

---

## 7.38 The offbeat drill has a tempo, and 100 BPM was the wrong one

The drill has measured a **held skank** for the first time. It also produced the clearest
instrument-specific result in the project so far, and neither was planned.

### The two takes

| | 6 Aug, 100 BPM | 11 Aug, 69 BPM |
|---|---|---|
| Off the beat | 26 of 112 — **23%** | 248 of 258 — **96%** |
| Verdict | *"the feel inverting"* | *"You held the offbeat"* |
| Placement spread | 45.3 ms | 28.7 ms |

The player's account arrived before either number was looked at: at 100 BPM it was *"very difficult
to try and get any notes in"* and was abandoned inside twenty seconds; at 68 it *"had a nice flow"*.
Two independent lines pointing the same way, which is the only reason two takes are worth writing up
at all.

**The measurement was never the problem, and it is worth being exact about that.** `IntervalRung`'s
ceiling is about whether a rung can be *scored* honestly, and at this player's ~25 ms spread eighths
are scorable to about 160 BPM. 100 was comfortably inside it. What failed at 100 was the playing,
not the scoring, and those are different axes — treating one as the other would be `LESSONS.md`
shape 10 arriving through a tempo.

### Why an offbeat gets harder as the tempo rises

Stated as hypothesis, because this project has been burned by stating a tempo relationship as fact
before measuring it (shape 17, and "faster is tighter" specifically).

**The rate is not what changes — the phase is.** An offbeat take asks for one note per beat, so the
notes are no closer together at 100 BPM than a quarter-note jam is. What changes is that each note
must sit at the *midpoint* of an interval whose endpoints are not being played. At 100 BPM that
midpoint is 300 ms from the beat either side; at 69 it is 435 ms.

**The mechanism I would bet on is the instrument, and it is the player's own observation.** A ska
up-stroke is one limb oscillating at beat rate, and the offbeat is the *return* of a motion whose
down-stroke is the beat — the timing is carried by the oscillation, so the offbeat comes very nearly
free. On a keyboard every offbeat is a discrete press, independently initiated, with no return
stroke underneath it. The biomechanical scaffolding is simply absent.

That predicts something checkable: ska guitarists hold offbeats at 160 BPM, which is a 187 ms
placement — far tighter than the one that defeated a keyboard here. **So the drill on keys has a
much lower tempo ceiling than the genre it trains for, and that is an instrument limit rather than a
skill limit.** It is an argument for M21 rather than for grinding at the keyboard.

A second candidate, from the interval-timing literature rather than from anything measured here:
below roughly 250–300 ms, successive events stop being timed individually and start being chunked.
At 100 BPM the offbeat grid is *exactly* 300 ms, sitting on that boundary; at 69 BPM it is 435 ms,
clear of it.

**What would falsify the instrument explanation:** the same player holding a fast offbeat on
*any* oscillatory instrument — a strummed guitar under M21, or pads struck alternately — while
still losing it on keys at the same tempo. What would falsify the boundary explanation: the feel
holding at 100 BPM after practice, with no change of instrument.

### The default moves to 70 BPM

Grounded in the take that worked rather than derived from a threshold — two observations cannot
support a derived ceiling, and inventing one would be shape 11 exactly. **A faster offbeat is still
reachable by asking for one**, because the genre needs it: ska and punk live at tempos this drill's
default has no business pinning the player to.

### The other direction, which the player raised and the data cannot yet answer

*"Some things are way easier to play faster and playing them slow is difficult."* That is the
standard shape of timing variability against tempo — a minimum somewhere near the spontaneous motor
tempo, rising on both sides — and it is the player's own stated hypothesis from §7.23: faster is
easier to a point, and slow tempos invite rushing.

Two mechanisms are usually offered for the slow side, both literature rather than measurement here:
a fast repetitive movement becomes preprogrammed and runs open-loop, where a slow one needs
per-event feedback correction; and beyond roughly 1.5–2 s an interval exceeds what is held as a
single felt unit, so the player begins subdividing or counting — **which for this player is the
documented way to make timing worse.**

`review interval` is the readout built for this and it still says no: a straight line cannot carry a
claim about an optimum, and it names the count of distinct intervals as the limit. There are now
five. The 69 BPM take is a sixth interval and is the slowest yet, which is the side of the curve the
corpus has least of.

**One thing worth watching rather than concluding.** That take's offbeat placement spread is 28.7 ms
against this player's usual ~24 ms at 100 BPM — held the feel, placed it less precisely. That is
what the slow side of a U-shaped curve would look like, and it is also one take of a different task,
which is exactly the confound `TakeAxis` splits groups for (shape 19). Not a finding.

---

## 7.39 The last surface gap closes, and the Feel picker stops lying

M15 left the offbeat drill CLI-only and §7.34 found the app explaining a disabled Feel picker by
talking about triplets when the rung was quarters. Those turned out to be the same defect wearing
two coats: **a surface answering a question it should have been asking.**

### The Feel picker's wrong explanation was a duplicated rule, not bad wording

`AppModel.feelApplies` tested `rung.subdivisions == 2 || rung.subdivisions == 4`, while the engine
tests `Feel.applies(toSubdivisions:)`, which is *is this a power of two above one*. Those agree for
exactly the four rungs that exist today and are different rules — a 32nd rung would swing in the
engine and not in the picker. `LESSONS.md` shape 9, sitting under a visible bug rather than causing
one yet.

The wording was downstream of it. Having decided for itself that a rung could not swing, the app had
nothing to say about *why*, so it said the same sentence every time — and that sentence was true of
triplet eighths and irrelevant to quarters.

**Both now come from the rung.** `IntervalRung.canSwing` derives from the same
`Feel.dividesBinarily` the engine uses, and `swingUnavailableReason` carries the reason, switched
exhaustively with no `default` so a new rung cannot be added without deciding what it says.
`SwingAvailabilityTests` requires the two to agree, requires quarters *not* to mention triplets, and
pins the rule as a power-of-two test rather than as the two rungs it happens to be today.

**The reason belongs on the rung rather than at the surface**, and the argument generalises: a
control that explains itself has to derive the explanation from the same thing that decided the
state, or the two drift and the explanation is worse than silence. It sent the player looking for
the offbeat drill in the Feel picker, which is how the missing mode was found.

### The offbeat drill in the app

`Mode.offbeat`, a Downbeat picker over all four levels, and the level's own `advice` under it. No
gate: the CLI never gated the levels either, and `--probe` there only marks the take rather than
unlocking it, so there is nothing for the app to withhold.

**The take is a jam carrying a level, not a separate engine path.** Both surfaces now build it
through `JamConfig.offbeat(bpm:bars:level:)` — one constructor, because the rule has to match and
not merely the fields: tagged `offbeat` so console and app takes pool as one condition rather than
two meaning the same thing, and carrying neither rung nor feel. Extracted for the reason
`SessionRunner.jamConfig(for:)` was, and the same shape-1 story sits behind both.

**The results screen gets the offbeat readout**, recomputed exactly as the console recomputes it,
with slipping shown **above and apart from** placement. A slipped player is dead on a grid point —
the wrong one — so a placement figure alone would call a lost feel an excellent take. Without this
the app would have shown a skank as an ordinary jam: the take's identity surviving storage and then
dying at the surface, one step further along than §7.24 step 8's version of the same failure.

**Entering the mode moves the tempo to 70**, and only from the app's default of 100, so a tempo
deliberately chosen is never overwritten. The advice line states the geometry — how many
milliseconds from the beat the chop lands at the chosen tempo — and the two takes there are, and
stops there. **No threshold**, because one take at each of two tempos cannot support one and a
number that reads as measured would be shape 11 in a tooltip.

### What this does not cover

**None of the app path is tested, because none of it can be.** `MusicalTrainerApp` has no test
target: the config both surfaces build is now testable and tested, and the picker, the mode wiring
and the results view are verified only by the build and by playing it (R5.6). The mode is present in
the built binary; whether it reads well is a live-run question.

**Nothing has been recorded from the app's offbeat mode**, so the surface is unproven in the way
every surface here starts out. The two takes in §7.38 are both from the console.

> **Correction (§7.46).** This section's summary — *"no surface gaps left"* — was true about which
> **modes** exist and was read as a claim about the surfaces being correct. They were not: a swung
> jam from the app's menu was described with the straight instructions, which no mode inventory
> would have caught. The sentence stands as written with this note beside it, the way a retracted
> finding does.

---

## 7.40 M16 step 0 — the form drill's two axes become peers

§7.26 concluded from the form history that this player *knows where he is and cannot land on it*.
The drill has been measuring both facts all along and reporting them as one, because the temporal
figure was computed only over marks that had already passed the spatial test.

### The defect is a selection effect, not a missing number

`phaseErrorMs` was always a peer at the level of a single mark: it is the distance to the **nearest**
bar line, well defined for any mark, and its doc comment already said that landing crisply on the
wrong downbeat is a different failure from landing sloppily on the right one.

The gating was in the aggregate. `phaseErrors = onForm.map(\.phaseErrorMs)`, and `tightCount` was
on-form marks that were *also* close. So the temporal score described a population selected by the
spatial one — **get better at knowing the bar, more marks enter the pool, and the placement figure
moves for reasons that have nothing to do with placement.**

That is survivable while nothing acts on it. It is not survivable in step 1, which promotes a ladder
on the temporal figure: a ladder reading a statistic that shifts when the *other* ladder advances is
reading its own progress back to itself.

So the report carries three things where it carried two:

| | |
|---|---|
| `onFormCount` / `onFormRate` | **Spatial.** The right bar — did you know where you were? |
| `cleanCount` / `cleanRate` | **Temporal.** On a bar line, *whichever* bar — could you land on it? |
| `nailedCount` | Both at once. The intersection, and neither axis. **Nothing is promoted on it.** |

### The corpus already contained both failures, in opposite directions

Recomputed over all fourteen form takes, which R3.1 makes free — the analysis re-runs from the
stored marks, so a new axis reaches takes recorded a fortnight before it existed.

| | on form | clean | |
|---|---|---|---|
| **5 Aug, 01:41** | **5/14** — 36% | **10/14** — 71% | placement fine, the map was lost |
| **10 Aug** | **25/25** — 100% | **8/25** — 32% | the map was perfect, placement missed |

**A double dissociation, and it settles M16's premise rather than illustrating it.** Two takes, each
strong on one axis and weak on the other, in opposite directions. Under the old readout the 5 August
take read *5/14 on form, 5/14 nailed* — a bad take at everything. It was nothing of the kind: he was
landing cleanly twice as often as he was landing in the right place, and the drill had no way to say
so. One ladder cannot train two skills that come apart like this.

### What was checked before the change was believed

The old `review form` output was captured first and diffed against the new one, which is what
`LESSONS.md` shape 4 asks for when rewriting a computation. **The `both` column is identical to the
old `nailed` column in all fourteen takes** — the intersection did not move, and a peer was added
beside it. A change that altered the existing number while adding a new one would have looked the
same on any single reading.

Re-gating `cleanCount` and the phase spread behind form fails `FormAxesArePeersTests` twice.

### The objection, and what it is worth

A mark a bar and a half from the phrase top is not *aiming* at the bar line it is measured against,
so calling it "cleanly placed" reads a motor success into what may be a guess. That is the argument
the old design was making, and it is not silly.

It is answered by reporting both rather than choosing: `phaseErrorSDms` is unconditioned,
`onFormPhaseErrorSDms` is the on-form subset, and the headline — *"the map is solid; the placement is
loose"* — keeps reading the on-form figure, because that sentence is explicitly about marks that
were on form. Neither is promoted on, and R3.4's rule applies to the pair: name the two rather than
blend them.

### What this step deliberately does not do

**The promotion rule is untouched.** `SessionPlanner` still promotes on `onFormRate >= 0.9` with no
unmarked phrases, exactly as before — `cleanRate` is carried on `PlannerInput.Form` and **read by
nothing**. That is §8.1.2's order: the data lands before the rule that reads it, so the first takes
scored under a new rule are not scored under one that then changes.

**No storage change.** `FormSession.tightCount` keeps its name and stores the intersection it always
held; `report()` recomputes from `markTimes`, so nothing had to be added to a stored take for the
new axis to reach the whole corpus (R3.1).

**The temporal ladder does not exist yet.** Step 1 turns `cleanRate` into a rung the player climbs,
and step 3 is the chooser that stops both ladders moving at once.

---

## 7.41 M16 step 1 — the levels become the temporal ladder

Step 0 made the two axes peers and left the promotion rule alone. This is the rule.

### The levels remove landing cues, so landing is what earns the next one

| | what it takes away |
|---|---|
| 0 → 1 | the crash **on** the downbeat — the thing that confirms the arrival |
| 1 → 2 | the fill that warned the turn was coming |
| 2 → 3 | the band, across the boundary entirely |

Every rung of that ladder removes information about **when** to land. None of it removes information
about *which bar* — the phrase length never changes, and a player who knows where he is at level 0
knows it at level 3. So the rate that decides whether a player has outgrown a level is the placement
one, and reading `onFormRate` there was asking the wrong question of the right ladder.

Phrase span is the other axis and is promoted on `onFormRate`. That is step 2.

### What the old rule did, on this player's real history

Not hypothetical. Run against the corpus as it stands, with the promotion input flipped back:

| | planner's choice |
|---|---|
| Reading `onFormRate` | **level 3** — "silence across the boundary… no band at all" |
| Reading `cleanRate` | **level 2**, held |

The take it read was 10 August: **25 of 25 on form, 8 of 25 clean.** Perfect spatial awareness, and
landing cleanly a third of the time. The old rule's answer to that was to take away the last of the
landing help — promoting him to the top of the ladder on the strength of the skill he already had,
in a drill whose remaining levels only make the skill he lacks harder.

The player now reads:

> 100% on form last time and 32% landed on a bar line. The levels are about landing, so level 2
> holds until that is above 90% with nothing unmarked.

### One bar for both ladders

`SessionPlanner.ladderPromotionRate`, 0.9, shared by this ladder and the span ladder step 2 adds.
Two numbers would be two standards for "you have got this" and nobody could say why they differed;
one constant rather than two literals also stops them becoming the same value for different reasons,
which is shape 9.

**It is deliberately not tuned to make this player advance.** His clean rate runs 12–100% across the
fourteen takes with a recent best of 76%, so the temporal ladder holds him at level 2 — which is the
correct behaviour for a skill he has not got. A ladder tuned until the player climbs it measures
nothing.

**`hasUnmarkedPhrases` still gates, and now for a second reason.** Unmarked phrases mean few marks,
so a clean rate computed over them is a rate over a thin sample.

### What was checked

`TemporalLadderTests` plants the defect directly — 100% on form with 32% clean must not promote —
and the converse, that clean landings earn the level even from a take whose spatial rate would have
failed the old gate. Reverting the promotion input fails it four ways.

**Two existing tests failed and were changed, which is worth stating plainly.** Both built a
`PlannerInput.Form` without a clean rate and asserted a promotion, so under the new rule they
correctly declined to promote. Their intent — *a good enough take earns the next level* — is
unchanged; what they needed was to supply the axis the rule now reads. One was called
`testCleanTakeEarnsTheNextLandmarkLevel`, where "clean" meant "good"; it is
`testLandingCleanlyEarnsTheNextLandmarkLevel` now, because "clean" names a specific axis in this
file and one word with two meanings is shape 10.

**The level this player currently stands on was earned honestly.** Worth checking rather than
assuming, since a ladder inheriting a position from the rule it replaced would be starting from
somewhere it would not have chosen: the 1 → 2 promotion followed the 2 August take that was 5/5 on
form **and** 5/5 clean. Small — five marks — but earned on both axes.

### What this step does not do

**No demotion.** The ladder has never demoted and this does not add it; a player above their level
holds there rather than being moved down. Whether the temporal ladder should demote is a real
question and it is not answered here.

**The phrase length still follows the felt period.** That rule is orthogonal to promotion and is
left alone — it is the span axis's business, and step 3's chooser is what stops the two ladders
moving in the same sitting.

---

## 7.42 The drill says how long a phrase is, and the backing question is answered

Two things came out of playing a 16-bar phrase over the current form backing, which was the ear
check §7.13 left open and step 2 was waiting on.

### The backing stays as it is, and the reason is better than the question assumed

§7.13 framed the risk as *"a 32-bar phrase over it is hypnotic well before the boundary arrives, and
a player who has stopped listening is not being measured on form."* Hypnotic was assumed to be a
flaw. The player's verdict, having played one:

> *"The track was kind of hypnotic or repetitive however I would argue that is a feature not a flaw
> for this exercise. Having a track that varies could give the user an unintended reference point
> for timing."*

**That is the stronger argument, and what it does is scope the premise rather than reverse it.** A
backing with sectional variety hands the player landmarks the drill did not intend to give — a
section change is a signpost, and this drill's whole ladder is about removing signposts. Uniformity
is not the backing failing to be interesting; it is the control that makes the level mean what it
says.

**The hypnotic risk is real everywhere else, and M19 exists because of it.** The player is explicit
that a varying track makes a long jam better and easier to lock into, which is exactly what §7.29's
styles, intensity arcs and sectional arrangements were built for. Nothing here argues against that.
What is being said is narrower and only about this drill: **the form drill is a different task and
is treated as one.** A jam wants music worth playing over for seven minutes; the form drill wants
music that says nothing about where you are.

So **option 1 — leave it** — and not as the cheap choice. `FormBacking` keeps its own patterns and
step 2's span ladder runs on today's music.

**What is left open, and it is a different idea rather than a smaller version of this one:** a
backing that varies *non-uniformly* could be a deliberate distractor — training focus against
changes that carry no timing information. That is an addition to the ladder rather than a fix to
the backing, and nothing here is blocked on it.

### The instructions were telling the player the wrong number

The gap the same take found. `DrillInstructions.form` took only a level, and its first step read:

```
"A drum groove plays in phrases — 8 bars each by default."
```

**Hardcoded.** A 16-bar take announced 8. Not a missing statement — a wrong one, produced by text
written independently of the configuration it describes, which is exactly R3.6 and exactly the shape
§7.39 found in the Feel picker a fortnight earlier: a surface answering from its own assumption
rather than from the thing that decided the state.

**This drill makes it worse than it sounds, and the reason is worth stating.** Eight bars and sixteen
bars of the same groove are *audibly identical*. At level 2 — no fills, no accent, no silence — the
groove is uniform for the whole take, so nothing in the music distinguishes one phrase length from
another and **the words are the only place the number exists.** At levels 0, 1 and 3 the boundary is
marked by a fill, a crash or a silence, so the span is at least discoverable by ear; at level 2 it is
not discoverable at all. Level 2 is where this player has been for eleven of his fourteen takes.

What it costs is data rather than comfort: a player who believes the phrase is 8 bars when it is 16
marks every 8 bars and is scored as a bar out, over and over, on a task he was performing correctly
under the instruction he was given.

**And it would have corrupted the planner, quietly.** `markedEveryBars` detects a player marking a
period other than the configured one and, when two takes agree, follows it — the felt-period rule. A
player mis-told the span marks the span he was told, twice, and the planner reads a *felt period*
where there was only a misprint. The rule cannot tell those apart, and step 2 is about to start
varying the span deliberately.

`form(level:phraseBars:)` now, with the length as the first thing said, `forBlock` passing the
`FormPlan`'s own value it already had in hand, and both surfaces passing theirs. At level 2 a second
line says the music will not tell you, because being told the number is useless if you do not know
it is the only copy.

**Plain text, no markdown.** `consoleText` prints a step as-is and SwiftUI's `Text` does not parse a
runtime string, so `**` arrives as literal asterisks on both surfaces. The number leads the sentence
instead, which is the prominence that survives the medium.

### What this does not do

**The count-in is unchanged.** Making it the indicator was considered and does not scale: a count-in
equal to the phrase is four bars of lead-in at a 4-bar phrase and thirty-two at a 32-bar one. The
ladder's precedent — *the count-in is where the drill tells a player with their eyes shut what it is
asking for* — encodes the task in the count-in's **content** rather than its length, and no short
rhythm encodes an arbitrary bar count without inventing a code the player must learn.

**So the number is stated, not sounded.** An audible demonstration of the span — a lead-in phrase at
full landmarks, excluded from scoring — is the obvious next idea and is deliberately not built here:
it changes what a take contains, and recomputing the corpus under it would score fourteen historical
takes as though they had a demonstration phrase they never had.

---

## 7.43 M16 step 2 — the phrase span becomes the spatial ladder

The other half of the split. Step 1 made the levels a ladder about landing; this makes the phrase
length a ladder about holding your place, and gives it the axis step 0 separated.

### Why the span reads the spatial rate

Growing the phrase asks the player to carry his position across more music. It changes nothing about
the cues that say *when* to land — **a 32-bar phrase at level 2 has exactly the landmarks an 8-bar
phrase at level 2 has**, which is none. So the rate that decides it is the spatial one, and the two
ladders now read the axis each is actually about:

| ladder | moves | promoted on |
|---|---|---|
| Levels 0–3 | which cues are removed | `cleanRate` — landing |
| Span 4 → 8 → 16 → 32 | how much music you hold your place across | `onFormRate` — knowing the bar |

The rungs are the spans the drill offers, so the ladder can never ask for a length the player cannot
also choose by hand. The roadmap describes the progression as 8 → 16 → 32; 4 is on the list because
the felt-period rule can put a player there, and a ladder has to know where its rungs are rather
than only where it prefers to start.

### The felt-period rule is this ladder's demotion

It returns before the span ladder, so a player who marks a shorter phrase twice running is moved
back to the span he is actually tracking. **A correction beats a promotion**, because promoting
someone onto a span they are not following measures nothing — and the ladder has no demotion of its
own, so this is the only thing that walks it back down.

### Only one axis moves in a plan, and that is asserted rather than assumed

Both gates can be open at once. The early return means only one ever fires, and
`SpatialLadderTests.testOnlyOneAxisMovesInAnyPlan` pins that across every level and span
combination, because it is the property that keeps one take comparable to the one before it: two
changes at once and neither result says which change did it.

**Which one fires is currently decided by position in the function**, and that is `LESSONS.md`
shape 5's complaint about two blocks ordered by which was appended first. Step 3's chooser is what
turns it into a decision. The guarantee that *only one* moves is locked now; the choice of which is
not yet.

### A test from step 1 caught the interaction, and the behaviour was right

`testTheReasonNamesLandingRatherThanForm` planted 100% on form with 32% clean and asserted the held
level explained itself in terms of landing. With the span ladder in, that take no longer holds — it
**earns a longer phrase**, which is the correct answer and a different sentence. The plant moved to
rates below both bars so the hold reason is what speaks.

That is the split doing what it was built for: the axis the player is strong on advances while the
one he is weak on holds, from a single take, with no rule reading the wrong number.

### The cost worth stating: a longer span thins the temporal sample

At 96 bars an 8-bar phrase yields twelve marks and a 16-bar phrase yields six. So every rung of the
span ladder **halves the number of observations the *other* axis gets per take**, and `cleanRate` is
computed over marks placed.

Nothing is wrong with the number — it is a rate, and it stays a rate. What shrinks is its precision,
so a temporal ladder that will not move gets slower to move as the spatial one climbs. That is a
real argument for step 3's chooser being more than tidiness: alternating the axis keeps takes at the
shorter span in the record rather than letting the span run away from the axis that needs the data.

### What this step does not do

**No demotion of its own**, as above — the felt-period rule is the only way back down, and it fires
on a felt period rather than on a poor rate.

**The chooser does not exist.** Which axis moves is positional, and step 3 is what makes it a
decision — one axis per sitting, with a test that it never moves both.

---

## 7.44 M16 step 3 — the chooser, and why the temporal ladder goes first

Steps 1 and 2 gave each ladder its own axis. Both gates can be open at once, and only one may move
— that property was already asserted in step 2. What was missing was *which*.

### The choice was being made by the order of two branches

Nothing chose. The level ladder's `if` sat above the span ladder's, the first match returned, and
the preference that produced was invisible: not in a diff, not in a test, and changed by moving
code. That is `LESSONS.md` shape 5 — two planner blocks ordered by which was appended first, which
dropped form from every 20-minute session once already.

`SessionPlanner.formAxis(for:)` is the decision now, with a name, three cases and its own tests.
Both branches in the form block are consequences of it rather than gates racing each other.

### The temporal ladder goes first, and that is measured rather than preferred

**Advancing a level costs nothing.** The same phrase tops arrive, the same marks are placed, and
both rates are computed over the same sample as before.

**Growing the span costs data.** At 96 bars an 8-bar phrase yields twelve marks and a 16-bar phrase
six, and `cleanRate` is a rate over marks placed — so every rung of the span ladder halves the
sample the *other* ladder is judged on (§7.43). A ladder whose measurement gets noisier each time
its neighbour advances is a ladder that will stall for reasons that have nothing to do with the
player.

So when both are earned, take the free rung. **It is an ordering and not a veto**: when the level is
at the top the span moves the same sitting, rather than the opportunity being wasted.

### Strict alternation was the other candidate

It develops both skills in parallel, which §7.40's double dissociation is an argument for — they are
genuinely separate skills in different states, and there is no reason to train them serially.

It loses on the same measurement. Parallel development is self-defeating when one axis starves the
other's sample: alternating would grow the span on schedule regardless of whether the temporal
ladder was still moving, and the temporal ladder is this player's weak axis and the one with
*"enormous room"*.

**What would change it:** a temporal ladder that stalls for many sittings while the spatial one is
held behind it. That is the cost of this rule, and it would show up as lost *training* rather than
as lost data — the opposite trade from the one being avoided. The rule is a preference between two
defensible options, not a proof, and it is worth revisiting the first time the level ladder sits
still for a month.

### What is guarded

`FormAxisChooserTests` asserts the decision directly rather than through the plan it produces:
each axis chosen by its own rate, both-earned choosing temporal, the span still moving when the
level is topped, unmarked phrases holding both, and the bar being *met* rather than beaten — a
ladder that needed the threshold beaten would make the stated number wrong by a hundredth.

Flipping the preference fails it. `SpatialLadderTests.testOnlyOneAxisMovesInAnyPlan` still pins the
only-one property across every level and span, and the felt-period rule still returns before all of
it, so a correction outranks a promotion on either axis.

### Where this leaves M16

Steps 0 through 3 are done: the axes are peers (§7.40), the levels are the temporal ladder (§7.41),
the span is the spatial one (§7.43), and the chooser decides between them. **Step 4 is surfaces and
documentation**, and it is the only one left.

Nothing has been *played* under any of it. The planner currently holds this player at level 2 over
16 bars with both rates below the bar — 43% on form, 14% clean — so the first thing the chooser will
do on real data is nothing, which is the correct answer and not a test of it.

---

## 7.45 M16 step 4 — the drill says what you actually held

The surfaces step, and the first M16-era form takes decided what belonged in it.

### The take the drill could not read

12 August, 16-bar setting, level 2. Seven marks, and the gaps between them:

```
7.92   7.98   7.88   8.00   8.12   8.01   bars
```

**Six consecutive gaps inside a quarter of a bar of each other — the steadiest phrase in the
corpus.** The drill reported 3/7 on form, 1/7 clean, and a −0.92 slip: a failing take.

Both readings are correct and they answer different questions. Every figure in that row is measured
against the *setting*, and the setting was 16 while the player was holding 8. The analysis knew:
`markedEveryBars` has computed the felt period since M7, the planner reads it, and the comment
above it says the right thing — *"the player is feeling a shorter phrase than the one configured,
which is a different thing from losing the form and deserves to be said rather than scored down."*

**It was never said.** `markedEveryBars` appeared in no readout on either surface — computed,
consumed by the planner, and invisible to the person it was about. A `felt` column in
`review form`, a line in the take's own report, and a card in the app now carry it, and where it
disagrees with the setting all three say so before the figures rather than after them.

### The column immediately convicted itself

With the felt period visible, the *other* 12 August take reported **13.2 bars** — from gaps of 4.1,
12.4, 16.0 and 14.0. There is no period there.

The regularity gate was *"70% of gaps within 35% of the median"*, and 35% is the defect. A ±35% band
spans a factor of 1.35/0.65 ≈ **2.08 — wider than a doubling**, while the phrase lengths it
describes sit exactly a doubling apart. At a median of 13.2 the qualifying band ran 8.6 to 17.8 bars
and **contained both 8 and 16**: a tolerance that cannot tell one rung of the ladder from the next
cannot identify a rung.

±20% spans 1.5, comfortably inside a doubling, and three quarters of the gaps must sit in it.

**This is `LESSONS.md` shape 11 exactly** — a threshold reasoned to, wrong the first time real data
went through it — and it is the shape's own guard that caught it: *wire the readout to real data
before believing the thresholds*. Nothing designed the number 13.2; showing the column did.

**Nothing the planner does changes**, which was checked rather than assumed: a spurious period was
never in `[2, 4, 8, 16, 32]`, so the felt-period rule already ignored it. The plan for this history
is identical before and after, and the corpus loses exactly two reported periods — 5.9 and 13.2,
both from takes whose marks were plainly irregular — while every real one survives.

### A label that had stopped being true

`review form`'s placement line still read *"(on-form marks only)"*. §7.40 stopped conditioning those
figures two sections earlier and did not update the words, so the readout described the statistic it
used to compute. Corrected, with the on-form subset printed beside it rather than instead of it.

Third instance of one shape in a fortnight — §7.39's Feel picker, §7.42's hardcoded phrase length,
and this — all a surface asserting something it no longer derives from the thing that decides it.

### What this does not settle

**Why the 8-bar period was two bars out of phase.** Those marks land at bars 9.99, 17.91, 25.89 and
so on: a perfect 8-bar period offset two bars from the music's. Period and phase are different
quantities and the drill measures only their sum, through `formErrorBars`. A player with a correct
period and a wrong phase is wrong on every mark, and a player with a correct phase and a wrong
period is wrong on all but the first — the readout cannot tell those apart today, and the felt-period
column makes the gap visible without closing it.

**Whether one exceptionally steady take should move the phrase length on its own.** The rule needs
two takes to agree, which was a deliberate fix for the planner chasing a single take (§7.26). Six
gaps inside a quarter of a bar is far stronger evidence than the takes that rule was written
against, and the second take did not agree — so the drill stayed at a setting the player had already
abandoned. Worth revisiting, and not on one observation.

**Nothing in M16 has been played under the finished milestone.** These two takes ran under steps 0–3
with step 4 unbuilt, which is why the felt period had to be recovered from stored marks rather than
read off a screen.

---

## 7.46 The app described a take it was not about to play

A review before M16.5, looking for defects nothing was reporting. Eight findings; this section is
the first branch out of them, and the rest are listed at the end so the order is on the record
rather than in somebody's memory.

### A swung jam was handed the straight instructions

Pick Jam, pick eighths, set the Feel picker to *Shuffle* or *Swung*, and the instruction card read:

> Play two notes to the beat, evenly.
> Lock to the hat. It is playing the division you are being asked for.

The hat is swinging. The grid the take is scored on expects the offbeat late. Both lines are wrong
in the same direction, and the third — *"aim each note at the beat or the off-beat"* — is the one
the swung text exists to replace. `swung(rung:feel:)` has carried the argument in a doc comment
since M15: *"Handing a swung take the straight text would tell the player their own task is a
mistake."* That is what the app was doing.

**Not a wrong value — a missing argument.** `AppModel.Mode.instructions` took `formLevel`, `rung`,
`offbeatLevel` and `phraseBars`. The feel was not on the list, so `DrillInstructions.jam(rung:)`
took its straight default, while `start()` built a `JamConfig` two hundred lines away that carried
the feel into the engine and into the grid. The console passed the feel and a planned block passed
the feel; the app was the one surface that did not, and it is the surface the picker lives on.

### Why the test suite was green

`FeelWiringTests.testASwungRungGetsItsOwnTextRatherThanTheStraightOne` asserts on
`DrillInstructions.jam(rung:feel:)` directly, and it passes — the function is correct and always
was. The test beside it,
`testAPlannedBlockCarriesTheFeelIntoItsInstructions`, is documented **"Both surfaces go through
`forBlock`, so the feel has to arrive by that route"**, and that sentence is false: `forBlock` maps
a *planned block*, and a take started from the menu never touches it. The comment names the exact
assumption that made the gap invisible.

The gap is sealed at both ends. The planner schedules nothing swung until a swung take exists
(`testThePlannerSchedulesNothingSwungUntilOneHasBeenPlayed`), so `forBlock` has never once carried
a swing — **the only reachable swung-instruction path in the app was the broken one.** `LESSONS.md`
shape 1, seventh instance, and the fifth where the tell was that nothing in `Sources` called the
thing under test.

### The fix is the shape, not the argument

Adding a fifth parameter would have fixed this take and left the next setting to go the same way.
`DrillInstructions` gains `forJam`, `forForm`, `forDropout` and `forTempo`, which take the **config**
rather than its parts:

| Surface | Before | Now |
|---|---|---|
| Console | `jam(rung: prescribed, feel: swingFeel)` | `forJam(config)` |
| Planned block | `jam(rung: p.rung, feel: p.feel)` | `forJam(SessionRunner.jamConfig(for:role:))` |
| App menu | `jam(rung: rung)` | `forJam(jamConfig)` |

A surface can forget to pass an argument. It cannot forget to pass the value it is about to hand
the engine. `forJam` also carries the offbeat check, so a drill's identity travels on the config
exactly as it does through `JamConfig.offbeat` — every reader of the config sees it.

`SessionRunner` gains `formConfig`, `dropoutConfig`, `tempoConfig` and `memoryConfig` beside the
`jamConfig` it already had, for the reason that one exists (§7.24 step 8): two constructions of one
config are two chances to disagree, and the disagreement is invisible because the preview announces
one thing while the engine runs another. `runCurrent` and `forBlock` read the same four now, so the
out-of-range form-level fallback lives in one place instead of two.

In the app, `jamConfig`, `formConfig` and `grooveConfig` become properties beside the four that
already were; `start()` reads them rather than rebuilding three inline, and `currentInstructions`
asks the `for*` functions. `Mode.instructions` is deleted rather than corrected.

### What is guarded

`InstructionsComeFromTheConfigTests`, nine cases, all reachable without an audio device and none of
them building a config out of parts — that was the shape of the defect. A swung config gets the
swung text; a triplet rung keeps the straight text even when handed a feel; a free jam keeps the
plain text, which the benchmark and both experiment arms depend on (R3.5); an offbeat config
outranks an experiment arm; and each drill's text moves when the config parameter that changes its
task moves. **Taking the feel back out of `forJam` fails the first of those three ways**, including
on the literal string *"evenly"*.

**Nothing in the app is reachable by any test** — `MusicalTrainerApp` is an executable target with
no test target — which is precisely why the mapping moved into `TrainerKit`. What remains
unguarded in the app is the one line that hands the config over, and that is the smallest the
untestable part can be made.

### A second thing, found while reading the same file

The swung goal line read *"Measures how you place a `**swung**` division"* — asterisks and all, on
both surfaces. Neither renders markdown, and the comment on `form(level:phraseBars:)` says so
outright eight lines above: the console prints the string as-is, SwiftUI's `Text` does not parse a
runtime string, and *"the number leads the sentence instead, which is the prominence that actually
survives."* The rule was correct, written down, and adjacent — and the next string written broke it,
which is what `LESSONS.md` shape 21 is about. The wording takes the same route out, and `check.sh`
now holds the string layer of `Instructions.swift`, verified by planting the asterisks back.

### What this branch does not cover

The review's other seven findings, in the order they were taken. **All eight are closed** as of §7.51:

| | Finding | Why it matters |
|---|---|---|
| 2 | ~~`check.sh` cannot fail on a third-party dependency~~ | Done in §7.47, which found a second rule underneath it |
| 3 | ~~`review trend` fits `onFormRate` only~~ | Done in §7.48 |
| 4 | ~~The app's history chart pools what the console refuses to~~ | Done in §7.48, and the chart survived being made honest |
| 5 | ~~Two lists of legal phrase spans disagree~~ | Done in §7.50, which found the strand was the worse half |
| 6 | ~~`MIDIInput.onNoteEvent` crosses threads unsynchronised~~ | Done in §7.51 |
| 7 | ~~Captured note-ons are dropped in silence once storage fills~~ | Done in §7.51, which found the buffer was four notes a beat from full |
| 8 | ~~`**swung**` renders as literal asterisks~~ | Done here — it was one file away |

**No live run.** Nothing here touches audio, MIDI or the analysis, and the only untested path is a
SwiftUI property; the take it changes is the *text on the screen before* a take. What has still
never happened is a swung take played from the app — every swung take on record was started from
the console (§7.24 steps 7 and 8), which is why nobody had seen this.

---

## 7.47 Two gate rules that could not fail

§7.46's second finding, and it turned out to have a larger one underneath it. The gate has been
green at every commit for the life of the project; what that meant is narrower than it looked.

### The whole gate, audited the way R5.7 asks of one rule

R5.7 says a rule is verified by planting a violation, watching it report FAIL, removing it and
watching it report PASS — *"Reading the pattern is not verification."* That was written after the
force-unwrap rule matched eleven violations' worth of nothing (§7.20 finding 5), and it has been
applied to rules as they were added. It had never been applied to the gate as a whole.

Doing it is cheap in one pass: plant a violation of **every** static rule at once, run
`check.sh --fast`, and read which ones fire. Twenty-two rules, twenty fired.

### The supply-chain rule could not fail

```bash
if grep -q 'dependencies: \[$' Package.swift && \
   grep -A2 'let package' Package.swift | grep -q '\.package('; then
```

Both halves have to match. `grep -A2 'let package'` gives the match and two lines after it — and
SwiftPM's argument order puts `dependencies:` *after* `products:`, so in this manifest a real
declaration lands four lines below that window. The first half never matched either: no line in
the file ends in `dependencies: [`.

Planted `swift-algorithms` in the position SwiftPM actually accepts, confirmed with
`swift package dump-package` that the manifest still resolves — so this is a working dependency,
not a typo — and ran the gate:

```
PASS  zero third-party dependencies
```

R7.2 is the rule that every dependency is *"code you did not read running with your privileges"*,
and it has been enforced by nothing. **Every dependency-free run this project has had was
dependency-free for reasons the gate had no part in.** `LESSONS.md` shape 2, fourth instance, and
the first on a security rule rather than a hygiene one.

The replacement greps for a `.package(` line anywhere in the manifest, and for `Package.resolved` —
which SwiftPM writes only once something has been resolved, and which is gitignored, so it catches
a dependency resolved locally rather than one somebody committed. Two signals because they fail
independently.

### Underneath it, a rule that cannot run reports PASS

`expect_empty` ran its command, discarded stderr, and read empty stdout as compliance. Those are
not the same thing. A rule produces no stdout when it finds nothing **and** when it cannot run at
all — a file renamed out from under it, a malformed pattern, a flag this platform's grep does not
have.

Pointing the autocorrelation rule at `BootstrapRenamed.swift`, a file that does not exist:

```
PASS  no autocorrelation is offered to a block-resampling bootstrap
```

**Every rule that names a file was one rename away from silently disarming**, and this project
renames things on purpose — `DrumVoice` to `BackingVoice`, `DrumKit` to `BackingKit`, sixteen
compiler-checked references at a time (§7.29 step 2). The compiler covers the Swift side of a
rename. Nothing covered the gate's side.

That is the same defect as the dependency rule with a larger blast radius, and it is why this
branch is not a one-line fix. grep writes to stderr in all three cases, so stderr is what separates
*found nothing* from *looked nowhere*; the rule now fails with `the rule itself could not run, so
it proved nothing` and prints what grep said.

### What was checked, and what was nearly broken by tidying

Both fixes were verified by planting, not by reading: the dependency declared → FAIL, removed →
PASS; the file renamed → FAIL naming the missing file, restored → PASS. Removing `Package.resolved`
between runs is part of it — the second signal fired correctly on the lock file `dump-package` had
just written, which is the rule working rather than a false positive.

**The `grep -P` branch in the tab rule was nearly deleted as dead code.** It cannot run on macOS,
where BSD grep has no `-P`, and the `||` fallback is what has always done the work here. It is not
dead: `.woodpecker/test.yaml` runs `./scripts/check.sh --fast` in `swift:5.7-jammy`, where GNU grep
has `-P`. Checking the pipeline before deleting is the whole of `LESSONS.md` shape 16 — the probe
that says "this is unused" was looking at one of two platforms. It stays, and it redirects its own
stderr, so the new check does not fire on it.

### What this does not cover

**The audit is a snapshot, not a standing guard.** Twenty-two rules were planted against on this
date; the twenty-third will be verified by whoever writes it, exactly as R5.7 has always said. What
*is* now mechanised is the failure mode that made the audit necessary — a rule that stops being able
to run says so instead of going green — and that is the half a script can hold.

**No source, analysis or audio change.** Nothing here touches a measurement; the tests, the
selftest and the stored takes are untouched by design, and the only file that changes is the gate
itself.

---

## 7.48 The history screen says what it is about

§7.46's findings 3 and 4, taken together because they are one screen and one argument: a readout
that covers less than it appears to. One under-described its **axes**, the other its **takes**.

### The trend fitted the axis the player is already good at

`review trend` fitted `onFormRate` for the form drill and nothing else. §7.40 made `cleanRate` a
peer — *"in the report, planner input and both readouts"* — and the trend was not on that list.

The consequence is worse than a missing row. The spatial axis is the healthy one: 75% on form at
8 bars, which is why §7.13 scheduled it second. **M16 exists to train the temporal one**, the
temporal ladder is promoted on `cleanRate` (§7.41), and nothing anywhere fitted a line through it.
A ladder whose progress cannot be read is a ladder nobody can tell is working.

Both rows now, and both surfaces gain it together because `TrendCard` and the console both render
whatever rows a series carries. The first thing it says, on 7 takes at level 2 over 8-bar phrases:

| | slope/take | 95% interval | verdict |
|---|---|---|---|
| on-form rate | −0.02 | [−0.12, +0.04] | flat |
| clean rate | −0.04 | [−0.13, +0.00] | flat |

**Read nothing into that beyond the fact that the line now exists.** Seven takes, an interval that
touches zero, and a ladder that was still being rebuilt underneath them.

### The chart pooled what the cards refuse to pool

The app charted every take of a drill as one line, while the cards under it split the same takes
four ways and named the confounds. For jams that put an offbeat take — the widest spread on record
and a different task — on one line with 21 free jams, beside a swung take, at four tempos and two
backings.

The comment above the chart conceded the whole thing:

> That chart draws one line through every take, which is only honest if the takes are comparable.

and drew it anyway, on the grounds that the cards below carried the warnings. That is exactly the
distinction `LESSONS.md` shape 19 exists for: naming a confound is R3.4, separating it is R3.5, and
**a reader who sees one line has been shown one line.** §7.24 step 8 retracted a verdict built this
way; §7.27 retracted two more.

### Grouping alone would have made the chart worse, which is why it nearly did not survive

One line per group, drawn naively, gives this history **eighteen jam groups, thirteen of them a
single take** — a thicket of disconnected dots under an eighteen-row legend. That is a worse
picture than the dishonest one, and a worse picture is how an honest change gets reverted.

The rule that resolves it was already here. `TrendAnalysis.minimumPoints` is 3, the cards refuse to
fit below it, and **the chart draws what the cards fit**. A two-point line is an invitation to read
a slope off two points, which is the thing that threshold exists to refuse. What the chart actually
draws now:

| Screen | Lines | Not drawn |
|---|---|---|
| Jams | 2 — 100 BPM (27 takes), 110 BPM (4) | 20 takes in 16 groups |
| Continuation | 2 — 4-bar (7), 16-bar (5) | 3 takes in 2 groups |
| Form | 2 — level 2 over 4 bars (5), over 8 bars (7) | 4 takes in 3 groups |
| Tempo | 1 — 100 BPM (13) | none |
| Recall | 2 — 2-bar (6), 4-bar (5) | none |

What is left out is **counted and named** under the chart rather than going missing quietly (R3.3),
and every one of those takes is still in the list below it.

### One grouping, not two

`HistoryEntry.group` is the **title of the `TrendSeries` that take contributes to**, character for
character, and it comes from the same key types rather than being rebuilt: `GroupKey`, `DropoutKey`
and `FormKey` gain a `title`, the two scalar keys gain a title function beside them. Two answers to
*which takes belong together* is one answer too many (`LESSONS.md` shape 9), and it is how a chart
and the card under it came to disagree in the first place.

`chartable()` lives in `TrainerKit` for the reason `TakeAxis.mixed(in:)` was extracted (§7.28): a
filter applied while drawing is a decision no suite can reach.

### What was checked

The group titles are transcribed into `testTheTrendGroupsAreStable` from the readout rather than
rebuilt from the code under test (`LESSONS.md` shape 4), and the pre-existing
`GeneratedBackingTrendTests` assertion on `"Jams at 100 BPM"` still holds — the strings are
character-identical to the ones they replaced, which is the claim the whole change rests on.

`ChartsAndTrendsAgreeTests` asserts the property that stops the two drifting apart: **the set of
groups a chart would draw and the set the cards fit are the same set.** Reverting the grouping
fails it with the two sets printed side by side; reverting the clean-rate row fails the form-axes
test; a group below `minimumPoints` and a take with a non-finite metric are each asserted to be
omitted and counted rather than drawn.

### What this does not cover

**The chart still follows one number per drill.** The form drill has two peer axes and the chart
draws the spatial one, with a note saying so and pointing at the fit below. Plotting both would
need a second series dimension competing with the group legend, and the verdict — which is what
"is this improving" actually means here — is in the card either way. Worth revisiting if the
temporal ladder starts moving.

**No live run and no measurement change.** No stored field, no analysis, no audio. Every number on
the screen is recomputed from raw taps exactly as before; what changed is which of them are drawn
together.

---

## 7.49 What a screenshot found that the suite could not

§7.48 landed with an honest gap stated in its own PR: *"I could not verify the chart visually."*
The player opened History and sent two screenshots. Both defects below are in the words a readout
uses about itself, and **neither is reachable by any test this project can write.**

### The Alone chart and the card beneath it plotted different quantities

The chart draws `tempoBiasBpm`. The card immediately below fits `|tempo bias|`. One heading, two
quantities, and nothing on screen said so.

It matters in one specific way. A reader follows the drawn line, and a line **descending through
zero** is improving until it crosses and worsening afterwards — while its own slope never changes
sign. The screenshot has exactly that shape available: the 4-bar series sits between −3 and +1,
straddling zero, with no rule drawn at zero to read it against.

**The signed line stays.** Rushing and dragging alone are different faults with different work
behind them, and the absolute value throws that away before the player sees it — which is why the
fit and the picture legitimately differ here. So the fix is not to make them the same:

- a `RuleMark` at zero, drawn only where zero is the target (`marksZero`, true for this drill
  alone — a spread or an error percentage cannot be negative, so a rule at zero would be a line
  along the axis);
- the note says which side is which and that **the fit below is on the distance from zero, so it
  does not care which**.

This is not shape 19. Nothing here is a confound blended into a pool; it is one quantity drawn one
way and fitted another, for defensible reasons on both sides. What was wrong was that the screen
did not say so.

### "1 takes"

Sixteen of the eighteen jam groups hold a single take, so *"1 takes"* is the commonest line in the
readout — in the console and on screen, both of which interpolated a count beside a bare plural.

`TrendSeries.takeCountLabel` is written once and read by both surfaces. Same move as
`DrillInstructions.for*` in §7.46: a surface cannot phrase it differently if it is not phrasing it
at all.

### What this says about the gap

§7.48's tests assert the grouping, the thresholds and the omission counts, and all of them pass on
both defects above. **Neither is a property of the data; both are properties of the sentence.** The
suite was not weak here — it was aimed at a different question, and this project has no way to
assert on a rendered view (`MusicalTrainerApp` has no test target, R5.6).

What closed them was a person looking at the screen and sending a picture. That is the same
resource as the listening verdicts in §7.31 and §7.33, applied to a surface rather than to audio,
and it is worth naming as such: **render → look → decide**, alongside render → listen → decide.

### What this does not cover

**The cards for un-fittable groups are long.** A one-take group still renders a full card with a
row per metric, each reading *"1 usable point(s) — need 3"*, so the Jams screen carries sixteen of
them below the chart. That is honest and it is a lot of scrolling; collapsing a group that cannot be
fitted to a single line is a real improvement and a design decision, not a defect fix, so it is
noted here rather than taken.

**No measurement change.** No stored field, no analysis, no audio, no grouping. Two strings and a
rule mark.

---

## 7.50 One ladder of phrase spans, and no way off it

§7.46's fifth finding. Two lists of legal spans, disagreeing about one entry, and the disagreement
was reachable.

### The two lists

| Where | Legal spans |
|---|---|
| `SessionPlanner.phraseSpanLadder` | `[4, 8, 16, 32]` |
| The felt-period rule, written out **twice** | `[2, 4, 8, 16, 32]` |
| `SetupView`'s picker | `[4, 8, 16, 32]`, its own literal |
| `FormConfig.validate` | `2...32` |

They agree about four entries of five. That is not a near miss — it is how long a disagreement of
this shape goes unnoticed, and it is `LESSONS.md` shape 9: two places holding the same value for
different reasons, correct together by coincidence rather than by construction.

**The fifth entry was reachable.** A player marking a steady 2-bar period across two takes running
was moved onto a 2-bar phrase: a span the ladder did not contain and the app's picker could not
display. The doc comment on `phraseSpanLadder` claimed *"Matches the lengths the app offers, so the
ladder can never ask for a span the player cannot also choose by hand"* — true of the ladder, false
of the planner that owns it.

### The strand, which is the worse half

`nextSpan(after:)` looked its argument up **by identity** and returned the successor:

```swift
guard let rung = phraseSpanLadder.firstIndex(of: phraseBars), … else { return nil }
```

So any span off the ladder returned `nil`, and `formAxis` — which only answers `.spatial` when
`nextSpan` is non-nil — could never do so again. **The spatial ladder was finished for that
player**, on an axis whose entire job is to widen. Two ways to get there: the felt-period rule
above, and a take run by hand at `form 100 64 6 2`, which `FormConfig.validate` accepts on purpose.

It returns the first rung wider than where you are now. No precondition, identical answers on every
rung — 4 → 8, 8 → 16, 16 → 32, 32 → nil — and 2 → 4, 6 → 8 for anything off it.

### A reversal, stated rather than slipped in

`FormAxisChooserTests.testASpanOffTheLadderDoesNotGrow` asserted the old behaviour, with a reason:
*"inventing a 'next' from an unknown rung would be guessing."*

It is not guessing. The ladder is ordered, and *the first rung wider than where you are* is what
climbing means — there is nothing to invent. What the old rule actually bought was a permanent
stall, and the test's own name described the defect as though it were the design. It is renamed to
the claim it now holds and cites this section, because a test quietly edited to match new code is
the guard becoming a mirror.

### What the data says about the entry being removed

`review form`, sixteen takes. Every felt period on record: **8.0, 8.0, 8.0, 7.9, 8.0, 4.0, 4.0,
8.0, 4.0, 4.0, 8.0**, and five takes with none. Nothing has ever felt a 2-bar period, so this
changes no take, no plan and no number already recorded. It closes a door rather than moving
anybody through one.

### Declining a measurement out loud

A felt period the ladder does not have is still a measurement. Refusing it in silence would leave
the drill at a span the player has visibly abandoned with nothing on screen accounting for it, so
the plan says what it saw and why it is not acting on it (R3.3) — and names the rungs from the list
rather than from a third copy of them, so a rung added later appears in the sentence without anyone
remembering to edit it.

The wording leans on what an off-ladder period usually means: marking a period the form does not
contain is more often the phrase being lost than a different phrase being felt. That is a judgement
and it is written as one.

### What this does not cover

**The felt-period rule still needs two takes to agree**, which §7.45 flagged as worth revisiting —
six gaps inside a quarter of a bar is far stronger evidence than the takes that rule was written
against. Untouched here, deliberately: this branch is about *which* spans are legal, not about how
much evidence moves between them.

**`FormConfig.validate` still accepts 2–32.** A span tried by hand is the same affordance as
`--probe`, and the planner is what must not choose one — which it now cannot, and which no longer
costs the player their ladder if they do.

**No live run**, no storage change, and no take is re-scored: `phraseBars` is read from the stored
take exactly as before.

---

## 7.51 The capture stops losing notes and races in silence

§7.46's last two findings, both on the path every take is recorded through, and both silent by
construction. A third came out of fixing them.

### The buffer was too small, and only just

`MIDIInput` preallocates its note-on buffer so the delivery thread never allocates — right — and
the number was 8192, chosen once and never revisited. Against the engine's own limit:

| | |
|---|---|
| Longest take a drill will run | 512 bars = 2048 beats |
| Old buffer | 8192 note-ons = **4.0 per beat** |
| A keyboard player at four-note chords on sixteenths | **16 per beat** |

Not theoretical headroom. §7.34's block 9 logged 955 matched notes and 243 extras over 176 bars, so
an ordinary take already runs to ~1200 events; a long dense one is a factor of four from the ceiling
rather than an order of magnitude. `captureCapacity` is 32,768, and `notesPerBeatCovered` derives
the rate from `TrainerEngine.maximumTakeBars` — which is a named constant now rather than a `512`
written into three validators, so raising the bar cap without the buffer fails a test instead of
silently shortening how much of a take gets recorded (`LESSONS.md` shape 9). Half a megabyte, held
once for the process lifetime.

### And it stopped writing without saying so

```swift
if storageCount < capacity { … }        // and no else
```

A take that overran lost the rest of its playing with **no incident, no warning, and nothing to
distinguish it from a take where the player stopped early** — while every number it reports is
computed over the truncated series. That is `LESSONS.md` shape 20 in its second instance: the error
path discarding exactly the observation that says something went wrong, and it fires hardest on the
densest take, which is the one worth having.

Drops are counted now, with the host time of the first, and surface as an incident beside the
connection events. Nothing is excluded — §7.34's rule holds: an incident is a record, never a
verdict.

### The handler race, which the file already had the argument against

`onNoteEvent` was written on the take thread (`runJam` sets it, `end()` clears it) and read on
CoreMIDI's delivery thread, with nothing between them. The comment fifteen lines below it rejects
precisely that pattern for the note *count*:

> That pattern happens to be safe on x86_64's total store order, but it is a data race under the
> language model and would break on Apple Silicon.

A closure property does not get as far as needing that argument. Assigning one releases a box a
reader may be retaining, and a refcount underflow is a use-after-free on **any** architecture — so
the field beside it was locked while this one, holding a closure that captures the live
`GroovePlayer`, was not.

It goes behind the same kind of lock, **copied once per packet and called outside it**. Both halves
matter: monitoring must never be able to block capture, and a handler retained for the duration of
the call keeps what it captured alive if the take thread tears down mid-packet.

### A third defect, found by adding the third kind

Both surfaces counted incidents by subtraction — removals by identity, and *everything else* as a
setup change:

```swift
let changes = incidents.count - removals.count
```

So a `captureFull` incident would have been reported under `setupChanged`'s name, on both surfaces,
with nothing failing to compile. `LESSONS.md` shape 1: a decision made while printing is a decision
no suite can reach, which is why §7.28 extracted `TakeAxis.mixed(in:)` and why this is now
`MIDIIncidentReport.of`, exhaustive over `Kind`.

It carries the consequence as well as the counts, because the two losses are not the same one and
one sentence cannot describe both:

| Incident | What it means for the take |
|---|---|
| `sourceRemoved` | Notes were **never delivered** — the take may be missing playing that happened |
| `captureFull` | Notes were **delivered and heard, and not stored** — every number is computed over a truncated take |

### What is guarded, and what cannot be

The overflow cannot be provoked without CoreMIDI handing over tens of thousands of packets, and the
race cannot be tested deterministically — a two-thread hammer either crashes or passes, which R5.4
rules out. What `CaptureLossTests` covers is the arithmetic that sizes the buffer (reverting to 8192
fails with *"8192 note-ons over 512 bars is 4.0 per beat"*) and the readout that describes the
result, which is where the third defect lived: counting `captureFull` as a setup change fails three
assertions.

That split is worth stating plainly rather than implying the whole thing is covered. **The two
defects this section is named for are argued, not tested** (R5.6). The one found while fixing them
is tested, because it was the one that had escaped into a print.

### The review is closed

All eight findings of §7.46 are done: the app's swung instructions and the markdown (§7.46), two
gate rules that proved nothing (§7.47), the form trend's missing axis and the pooled chart (§7.48),
the phrase-span lists and the ladder strand (§7.50), and these two. §7.49 is the one nobody
predicted — two defects a screenshot found after §7.48 had already shipped.

**Nothing here has been played.** Six branches, no live run, and the next thing this project needs
is a session: M16 has never been exercised under its finished ladders, no take has been recorded
from the app's swung or offbeat paths, and the new incident readout draws nothing until the day it
does.

---

## 7.52 The readouts were fixed and the decision was not

Found while checking whether the offbeat drill's level ladder is wired into the planner. It is not
— and something worse was.

### The planner was reading skanks as free jams

```swift
let allJams = SessionStore.loadAll()
let jams = allJams.map { session -> PlannerInput.Jam in …
```

`map`, not `filter`. The offbeat drill is stored as a `JamSession` because it is the same capture,
the same grid and the same storage, so **every skank went into the planner as an ordinary jam**,
carrying a spread that runs half again as wide as free playing.

That input is not a readout. `SessionPlanner.spreadEstimate` takes the median of the last six jams
and it decides **which rungs the interval ladder may schedule**; `recentJamSpreadsMs` feeds the same
number to the app's subdivision picker, which offers only the rungs that survive it.

At the moment this was found, five of the six most recent takes were offbeat takes:

| Assumed spread | quarters | eighths | triplets | 16ths |
|---|---|---|---|---|
| 22.9 ms — free jams | 349 | 175 | **116** | 87 |
| 31.2 ms — the last six as they stood | 256 | 128 | **85** | 64 |
| 39.5 ms — a session of skanks | 203 | **101** | 68 | 51 |

Triplet eighths were **already gone** from the picker at 100 BPM, because four evenings of skank
practice had displaced the free jams out of a six-take window. And a planned run of offbeat takes —
which is exactly what M16.5 needs before it can be designed — would have taken eighths down to a
101 BPM ceiling and shut the ladder down.

### The part worth learning from

This confound has been found and fixed **twice before**, both times in a readout:

| | Where | Fix |
|---|---|---|
| §7.24 step 8 | An offbeat take inside *"Jams at 100 BPM"* in the trend, turning that group's bias "worsening" | `GroupKey.offbeatLevel` |
| §7.48 | The app's chart drawing it on one line with 21 free jams | `HistoryEntry.group` |

Both fixed **what the player reads**. Neither touched what *acts* on the same corpus — and the
asymmetry is the whole point: a wrong readout shows a wrong number, which somebody eventually
notices, while a wrong decision silently changes what you are asked to practise and removes a rung
from a picker with no line of text anywhere saying why. `LESSONS.md` shape 22.

### One place the distinction lives

`SessionStore.loadAllPlayAlong()` — takes where the player was playing *along* with the band —
against `loadAll()`, kept for the surfaces that should show everything. Six readers move onto it:

| Reader | Why it must not see a skank |
|---|---|
| `plannerInput().jams` | Sets the spread that gates every rung |
| `recentJamSpreadsMs` | The app's picker reads it |
| `intervalObservations` | The interval axis asks how the *gap* changes placement |
| `producedIntervalProfile` | Same question at note level |
| `warmUpReport(for: .jam)` | A 40 ms take mid-sitting distorts the within-session slope |
| `review content` | **The sharpest.** The drill's own instructions forbid the varied playing this readout correlates against — *"don't fill the gaps"* |

The history, `review list` and the trend keep `loadAll`, because they group by task rather than
averaging across it. Hiding the drill from those would be the opposite mistake.

### What this does not cover

**The offbeat drill still has no session slot.** `OffbeatAnalysis.suggestedLevel` has exactly one
production caller — the console's own end-of-take readout — and `SessionPlanner` never builds an
offbeat block, though `JamPlan.offbeatLevel` and `SessionRunner.jamConfig` are both wired for one.
Offbeat takes therefore accumulate only when the drill is chosen by hand. That is a real gap and it
belongs to M16.5's planning rather than to a filter fix: adding a second drill to the family without
it would leave both at one take per setting indefinitely.

**Whether a swung take belongs on the play-along side is not settled here.** It is left in, because
a swung jam still measures placing notes with the band — only the expectation moves. The offbeat
drill is categorically different, and that is the line this draws.

---

## 7.53 The 13 August setlist — the skank is held, and r₁ went up all afternoon

Not a planned session: a **setlist**, ordered by hand, because the planner has no offbeat slot and
every offbeat group on record held exactly one take. Ten takes, cold-sensitive first.

### The skank at 70 BPM is held, five for five

| Take | Off the beat | Placement | Spread |
|---|---|---|---|
| 54–58 | **128/128, 100%**, every one | −35 ms (ahead) | 21.7 / 30.8 / 23.4 / 29.0 / 23.1 |

The first offbeat series in this project that can be fitted at all: spread +0.08/take
[−2.68, +5.55], flat. §7.38 moved the default to 70 BPM on **one** take against one at 100; this
is that decision confirmed with depth, and the drill now says *"Ready for level 1."*

**Holding a position the band never plays costs this player nothing in precision.** Offbeat
placement spread is ~23 ms against ~25 ms for free jams — the same within noise. That is a result
with real consequences for M16.5: if holding *one* unplayed position is free, the bubble's whole
claim to be a different skill rests on whether holding **two** is.

**The chop sits 35 ms ahead, every take.** Free jams run −4 to −20 ms, so this is not the player's
general rush — it is drill-specific and it is stable across five takes. Pushing the chop is
stylistically real in ska, and §2 holds that bias is not failure, so this is recorded as a question
rather than a fault: **is 35 ms ahead the feel he wants?** Unanswered, and the drill scores it the
same either way.

### Triplet eighths at 80 BPM came down 10 ms, and r₁ went up 0.63

The one M14 rung with a single take on it — 42.7 ms, the widest spread on record — repeated at the
same tempo, rung, length and backing. `review compare` flags no confound:

| | 8 Aug | 13 Aug | change | |
|---|---|---|---|---|
| Spread (SD) | 42.66 | **32.54** | −10.12 [−18.13, −2.34] | **real change** |
| Mean async | −22.99 | −23.35 | −0.37 [−9.17, +8.31] | within noise |
| r₁ | +0.09 | **+0.72** | +0.63 [+0.51, +0.76] | **real change** |

So the widest take on record was **partly unfamiliarity** — the honest answer to a question the
player could not answer from memory, which is why the repeat was on the setlist. Two takes is not a
trend, and the bias not moving while the spread did is what a familiarity effect should look like.

The r₁ half is the uncomfortable one, and it is not confined to this pair.

### r₁ was high all afternoon

| Take | | r₁ |
|---|---|---|
| 59 | swung eighths, 100 BPM, from the app | +0.58 [+0.47, +0.68] |
| 60 | triplet eighths, 80 BPM | +0.72 [+0.65, +0.79] |
| 61 | free jam over `syncopated`, 100 BPM | +0.44 [+0.12, +0.77] |

This player's r₁ has run **0.13–0.50** across thirty takes, and §7.32 records 0.64 as the first
reading to leave that range at all. Three takes above it in one afternoon, on three different
tasks, is worth writing down.

**It is an observation, not a finding, and the reasons are stated so it is not read as one.** Three
takes, one sitting, three different tasks, at the end of ten takes in an afternoon — fatigue is at
least as good an explanation as anything about the tasks. §5.1 is explicit that r₁ near zero is the
project's definition of success, so a sitting that moves it this far in the wrong direction is worth
watching rather than acting on.

**What would settle it:** the same three settings played cold at the top of a session. If r₁ is back
in its usual range, this was the tenth take of an afternoon; if it is not, something has changed and
the benchmark jam will show it too.

### Two form takes, both at 8 bars, and one answered an open question

The setting was never touched. What moved was the playing:

| | marks | felt | on form | clean |
|---|---|---|---|---|
| Cold | 7 | **16.0** | 6/7 | 6/7 |
| Warm | 24 | **4.0** | 12/24 | 16/24 |

Consistent both times, in opposite directions, against a fixed 8-bar phrase. The felt-period column
did exactly its job in both, and `hasUnmarkedPhrases` correctly refused to promote the first: seven
marks over twelve phrase tops means half were skipped, so 86% on form is 86% of the half he marked.

**This answers §7.45's open question about whether one exceptionally steady take should move the
phrase length.** Had the rule moved on a single take, it would have gone 8 → 16 after the first and
16 → 4 after the second — the oscillation §7.26 wrote the two-take rule to stop, reproduced exactly.
The rule stays at two, and the "strength condition" §7.50 floated as a possible refinement is
**dropped**: these two takes are precisely the case a tightness threshold would have been fooled by,
since both were highly regular and both were wrong.

### Two fixes verified live

**§7.46 reached the built app.** The swung jam's instruction card reads *"letting the offbeat fall
late the way the hat does"* — screenshot on the day. That path had never been played before, which
is why the defect survived.

**§7.52 reached the picker.** The rung caption now derives from a **25 ms** spread; before the
filter it read 31.2, because four evenings of skank practice had displaced the free jams out of a
six-take window.

---

## 7.54 The app reads the history once

Reported from use, not from a profile: *"the UI in the app was laggy, I noticed it while typing the
condition for the take. Going back and forth to history also creates a lag."*

### Where the time went

Measured on the real corpus rather than guessed at:

| | |
|---|---|
| Decode every stored take | **437 ms** |
| One re-analysis from raw taps | ~32 ms |
| `recentSpreadMs` — decode plus six reports | **562 ms** |

`SetupView` reads `model.scorableRungs` **and** `model.rungAdvice`, and each independently resolves
the player's recent spread. `tag` is `@Published`. So **every keystroke in the Condition field cost
about 1.1 seconds** of disk and analysis.

History was worse: `jamHistory`, `trends`, `warmUpReport` and `experimentResults` each load
independently and the first three re-analyse every take, so a visit was four decodes and roughly
**180 analyses**, on the main thread, while the window tried to draw.

### What was not done

**The analysis was not made faster.** It is measurement code, and R3.1 requires every readout to
recompute from raw taps — that rule is why a chord-clustering fix reached takes recorded before it.
Nothing here caches a derived value. What changed is how often the work is asked for:

| | |
|---|---|
| `SessionStore` holds the **decoded** takes for the process | 437 ms → 2.6 ms |
| `AppModel` stores the spread estimate, refreshed after a save | out of the render path entirely |
| `TrainerEngine.historyPayload` builds the screen in one pass, loaded on a background queue | off the main thread |

The store cache is safe for two reasons that are properties of the rest of the system rather than of
the cache: a stored take is immutable (R6.2), and new ones arrive only through `save`. Both are
asserted rather than trusted — `StoreCacheTests` covers a take saved after a read, all six stored
types, and the test redirect moving underneath, and each reverts to a failure.

The spread estimate is a **value**, not a getter, and that is the shape of the fix rather than an
optimisation of it: something read twice per render cannot be allowed to touch the disk at all.

### What this does not cover

**History still does ~180 analyses**, now off the main thread with *"Reading your history…"* on
screen — an honest loading state, because a history that takes two seconds to analyse must not read
as a history with nothing in it. Cutting that to 61 means the three readouts sharing one pass over
the corpus, which is a restructuring of three public entry points and was not worth bundling into a
fix for a lag reported while typing.

**Nothing was profiled beyond these three numbers.** They were enough to explain the symptom and to
choose between fixes; there may be other slow paths and none of them were looked for.

---

## 7.55 M16.5 step 0 — both bubbles, and why neither was chosen

The milestone rests on a musical premise §7.13 recorded as unconfirmed: *"the bubble rests on the
beat and plays the second and third of each beat's triplet."* Asked directly, the player could see
the argument both ways and thought it might depend on the piece. So both were built and rendered
rather than one being picked and scored against.

### Two candidates, and what they share

`BubbleFeel` carries the pair. What makes both of them the skank family is the property §7.13
generalised: **nothing on the beat, two notes after it.**

| | steps | played |
|---|---|---|
| `triplet` | 3 to the beat | the 2nd and 3rd |
| `sixteenth` | 4 to the beat | the "and" and the "a" |

`BubbleBacking` states the figure the way the straight skank states its chop, and reuses
`OffbeatLevel` rather than growing a second ladder — what the levels remove is the *downbeat*, and
that does not change between figures. A parallel ladder would be two names for one idea, which is
`LESSONS.md` shape 10 before it happens.

### Writing the geometry down found what the roadmap had not

§7.38 established that tempo changes this family's task rather than its speed, because a note has to
land at a point whose neighbours nobody plays. Generalised from one position to a **set**, the
quantity is the *closest approach* any note of the figure makes to a beat:

| | closest approach |
|---|---|
| Straight skank — the "and" | **1/2** beat |
| Triplet bubble | **1/3** beat |
| Sixteenth bubble | **1/4** beat |

Three different tasks at one tempo, so the offbeat drill's 70 BPM default transfers to neither.

**And the sixteenth bubble's first note *is* the chop** — the same half-beat position the player
held at 100% across five takes on 13 August (§7.53), with the "a" added after it. The triplet
bubble contains no position the corpus has anything on. One candidate extends a measured skill and
the other asks for a new one, which decides what the milestone measures rather than only how it
sounds.

**This was found by a failing test.** The first version measured from the *first* note of each pair
and asserted both bubbles sit tighter than the chop, which is false. The test kept the wrong
version's story beside the right one, because a reader would otherwise re-derive the same mistake.

### The verdict, and the way it was contaminated

Five files at 70 BPM: both feels at levels 0 and 2, and the straight skank beside them. On rimshot,
deliberately — a placeholder timbre keeps a *placement* decision clean. The player's words:

> They both kind of sound right and I think it would depend on the piece of music you are actually
> playing. The 16ths sounded like the chop with a second note. Using the rimshot sound it had a nice
> double skank feel to it. The triplets had more of a noticeable gap between the notes. […]
> Initially I wanted to say 16ths for my choice but I think my ears were biased because that one had
> a better baseline groove.

**The "chop with a second note" observation is worth nothing as confirmation, and the reason is
this document.** The hand-over said, before he listened, that the sixteenth bubble's first note *is*
the chop with the "a" added. He then heard that. Two other verdicts here — the wider gap between the
triplet's pair, and the double-skank feel — were not primed and stand on their own.

That is a process failure of exactly the kind this project catalogues, in the one place it has been
careful everywhere else: ratings are taken before numbers, experiment arms are declared before
playing, and a style's audition is a listen before a flag. **A listening test whose conclusion is
stated in the question is not a listening test.** §7.33 already records approving two styles on
listening alone as "the weaker basis"; this is weaker still.

The player caught the second bias himself — that the sixteenth version had the better baseline
groove — which is a real observation and not a confound in the renders: both files carry an
identical drum pattern, kick on 1 and 3 and snare on 2 and 4, and only the figure differs. So
"better groove" is a property of the figure, and a legitimate reason to prefer it.

### The decision: both ship, and that follows from the verdict rather than working around it

*"Both kind of sound right and it would depend on the piece"* is not a failure to choose. It is the
answer, and §7.13 already anticipated the shape of it — the milestone's whole premise was
generalising one asked-for phase to a **set**. So `BubbleFeel` stays a two-case axis the player
selects, the way `IntervalRung` has four rungs and `Feel` has swing ratios. Consequences:

- **Each feel is its own trend group.** They differ in closest approach, so by §7.38 they are
  different tasks and a line fitted across them measures the change (R3.5, `LESSONS.md` shape 19).
- **Each gets its own tempo default**, derived from `closestApproachMs` rather than inherited from
  the straight skank.
- **The data decides what the listening could not.** With takes on both, which one this player holds
  better is measurable — and that is a stronger answer than either of us picking one today.

### What is still open, and how the listening gets redone properly

**The organ voice.** `BackingKit` has thirteen drum voices and a bass; there is no organ, and the
player was *"trying to imagine it with an organ sound to identify the bubble."* Asking someone to
imagine past the timbre is the audition equivalent of a caveat under a verdict. It is its own
render → listen → decide loop, and M16.5 needs it.

**A blind re-listen, with the organ, and without the answer in the question.** Opaque filenames, no
statement of which is which, and the verdict taken before the reveal — the same discipline as
rating a take before the numbers appear. Only then is a preference worth recording as one.

**Neither blocks the milestone**, which is the point of the decision above: both feels ship, so
M16.5 does not wait on a verdict it now does not need.

### The bias question, which §2 already answered

The player was asked whether the 35 ms he sits ahead of the chop is the feel he wants. His answer —
*"It isn't intentional… I just want my timing to be tight, in the pocket, and on the mark"* — is
recorded, and the question should not have been put to him without checking §2 first, which says:

> **Never present bias as failure.** Playing ~20–40 ms ahead of the click is normal for trained
> musicians (negative mean asynchrony).

His skank sits at −35 to −43 ms, **squarely inside that band**. His free jams run −1 to −20, which
is *below* it. So the reading is the opposite of the one the question implied: the skank is
ordinary, and his free playing is unusually close to the mark.

What is real and unexplained is the **27 ms gap between the two tasks**, which a calibration
constant cannot produce — the constant is one number for both, derived at 2.58 ms against a
reference measured at 8.96 (SD 0.89), so it is worth about a millisecond of doubt at this scale.
Something about holding an unarticulated position moves this player 27 ms earlier, and nothing here
explains it.

**Nothing is built to correct it.** The stated goal is added to §10 as a success criterion, because
"on the mark" was not among them and the player says it should be — but a drill that trains bias
toward zero would be training against §2, and the 27 ms task difference is a finding to understand
before it is a fault to fix.

### The rest of M16.5's shape, decided in conversation and recorded here

| | |
|---|---|
| **A curated data-session mode** | The 13 August setlist done by hand. The planned session's locked slots must not adapt (R3.5), so a new drill cannot be peppered into the longitudinal one — and the offbeat drill has no planner slot precisely because of that tension (§7.52). Collect *n* takes at fixed settings, comparable by construction, unable to disturb the benchmark |
| **The anticipation drill** | The player reframed §7.42's non-uniform backing: *"being able to feel when the music is going to change and being able to time it right with your playing is one of the skills we are developing."* That is not a robustness gotcha, it is a skill with its own measurement — signposted change, scored on where the player lands relative to it. Its own entry, not a footnote on the form backing |
| **Hand span as a metric** | Two simultaneous note-ons an octave-plus apart are two hands; a tight cluster is one. Unreliable on the Launchkey Mini's two octaves, and **the data to answer it is already stored** — `rawNotes` has carried pitch since 4 August (R6.3). Available the day the wider keyboard arrives, with no schema change |
| **The organ voice** | Above. Its own audition |

---

## 7.56 The organ, and the handicap it did not remove

§7.55 recorded a listening test taken through the wrong timbre: the two candidate bubbles were
auditioned on a rimshot, and the verdict was *"I was trying to imagine it with an organ sound to
identify the bubble."* So the family got a voice.

### What was built

`OrganSynth` is **additive, because that is what a tonewheel organ is** — near-sinusoidal partials
at drawbar ratios, summed, with no filter to model. Sub-octave, fundamental, the 5⅓' fifth that
gives the instrument its edge, the octave and two upper partials; **nothing at the 5th partial**,
which is a major third and would put a key quality inside the timbre where no voicing could remove
it. Flat while it sounds rather than decaying, since a Hammond is on and then off, with two
milliseconds of key click doing the work the bass's pluck does.

The stab is **115 ms and that is bounded, not chosen**: the tightest gap in the family is the
sixteenth bubble's quarter-beat, 150 ms at 100 BPM, so a longer note runs into its own neighbour.
`OrganStabTests` holds it against `BubbleFeel`'s own geometry rather than a constant written twice.

`BubbleBacking` plays the figure on it, voiced root and fifth.

**Two defects surfaced while wiring it in.** `BackingKit.buffer` switched on `isPitched` alone —
the same question as "is it the bass" while there was one pitched voice, and not afterwards; it
would have sounded every organ note as a bass note. And the one-shot tail guard *named* the bass by
hand, which is how the bass came to be missed there for a milestone (§7.31 finding 1); the fix at
the time was to add it explicitly, which is the same fix waiting to be forgotten the next time a
pitched voice arrives. It did. Both now enumerate rather than name.

### The verdict: right instrument, wrong organ

> The organ sounds like an organ and the click isn't too much. The organ kit we generated sounds
> good but I don't think it's the right organ sound for a reggae vibe. […] I still do not have a
> decision on triplets vs sixteenths yet, neither really sounded like a bubble. The triplets with
> the right voicing and more of a legato vs a staccato might sound good and the sixteenths still
> sound kind of like a doubled skank.

**The timbre passed and the milestone did not move.** Building the organ was the right thing to do
and it did not settle the question it was built to settle, which is worth stating plainly rather
than filing as progress.

The player named the cause himself, and it is one this project has already been caught by:

> This might be the same problem we ran into when we were making the different backing tracks, we
> got handicapped by the currently available tones.

That is §7.33 exactly. Four styles came out sounding like *"beat #3 rather than oh, a Motown
beat"*, and three of the four were renamed because a genre name was claiming something the kit could
not deliver. **The same handicap has now blocked a measurement decision rather than a naming one**,
which is worse: M16.5 cannot choose between two figures while neither can be heard as the thing it
is supposed to be.

### Three things the verdict adds that were not in the design

**Articulation is part of the figure, and nothing models it.** *"The triplets with the right voicing
and more of a legato vs a staccato might sound good."* `OrganSynth.bodySeconds` is one number for
every figure, deliberately bounded by the tightest gap in the family — which makes every bubble
staccato by construction. A legato triplet bubble wants a note that nearly fills its 1/3-beat
spacing, 285 ms at 70 BPM, which is more than twice the current stab. So **note length belongs to
the figure**, not to the voice, and the current bound is a floor on how staccato things are rather
than the right model.

**The voicing is unsettled and root-and-fifth may be why the triplet failed.** It was chosen to keep
the band out of M25's territory, which is still the right instinct and may be the wrong answer here:
a bubble with no third is a bubble missing the interval that makes it sound like an organ part
rather than a pair of stabs. The question is now explicit rather than assumed.

**Nobody here knows what a bubble is well enough to build one.** *"We really need to expand our
understanding of the bubble so we can accurately recreate one."* That is a prerequisite, not a
task, and it is the first time this project has been blocked on musical knowledge rather than on
code, hardware or data.

### What is deliberately not being built

The player asked for several organ and keyboard voices — *"the classic Bob Marley / The Wailers
sound, and a more modern organ sound displayed on Kash'd Out's albums"* — and said the reference
material would take him time to assemble.

**Those are not being guessed at, and the rule that forbids it is already written down.** `AGENT.md`
says *"Do not describe how something sounds. An agent cannot listen"* and *"Do not name a new style
after a genre"*, and §7.33 is the entry recording what happened the last time a name promised
something the synthesis could not deliver. Building a voice called "wailers" from a description
would be the same mistake with a shorter feedback loop.

**What makes it cheap when the references exist** is §7.30's argument, which already covers this
case: capturing a recording to *measure* — spectra, envelopes, drawbar balance, key-click level —
and tuning synthesis to match is a measurement problem rather than a licence problem, and this
project is good at measurement problems. The professional ear in the resources table is the other
half.

**The seam it needs**, so the next voice is a table row rather than a rewrite: the drawbar table
becomes a named `Registration`, `BackingKit` renders per registration and note, and the registration
is a property of the *arrangement* rather than of a hit — a band sets the drawbars for a song, not
for a note. Not built, because a seam with one implementation behind it is a guess about the second.

### What this means for M16.5

**The milestone is blocked on an ear and a reference, not on code.** The analysis generalisation
(a phase *set*, a completeness measure, per-phase placement) is still worth building and is
independent of which figure wins — but the figure cannot be chosen, and a drill that scores a
figure nobody can confirm is a drill measuring an assumption.

The honest state: `BubbleFeel` ships both, §7.55's reasoning holds, and the decision waits.

---

## 7.57 Fourth codebase review — two defects, and the queue the rest of it makes

A whole-tree review against a clean `main` at `23e9b4a`. **The gate passed every check before it
started and passes every check now**, which is the finding that frames the others: nothing below was
reachable by it.

The state it passed in, for the record: 33,655 lines of Swift across five modules, 823 test cases
carrying 1,843 assertions, 41 selftest checks, zero third-party dependencies, no force-unwrap and no
`TODO` anywhere in `Sources`. `check.sh --fast` — the pre-commit path — takes 77 seconds.

### Finding 1 — the one field §7.51's lock did not reach

`MIDIInput.lastNoteOn` is 128 host times, one per note number, holding the 3 ms window that rejects
double delivery. CoreMIDI's delivery thread read it and updated it; `reset()` cleared all 128 entries
from the take thread. Neither took `storageLock`, so a keyboard played between takes had both running
at once.

**§7.51 is the review that fixed the field beside it.** `onNoteEvent` was found crossing threads
unsynchronised in that pass and put behind `handlerLock`, with a doc comment arguing the case in full
— that the unguarded pattern *"is a data race under the language model"* which *"happens to survive
x86_64's total store order"*. `lastNoteOn` is declared **between that comment and the one under
`storage` that it cites**, and was touched by neither.

So this is `LESSONS.md` shape 21 in its sharpest form yet. Not a rule nobody wrote down: a rule
written down, in the right file, in the right words, in the comment the broken field is declared
immediately above, during a pass explicitly hunting for that exact defect.

**Nothing is known to have gone wrong and nothing would have shown it.** The symptom is one note
swallowed as a duplicate, or one double delivery admitted as a note, at a take boundary — with no
incident, no count and nothing in the record to say which. It is fixed because it is undefined
behaviour in the capture path, not because it was caught misbehaving. That distinction is worth
keeping: this project's other concurrency entries all came with a wrong number attached, and treating
"no observed symptom" as "no defect" is how a capture path accumulates them.

**The fix folds two adjacent critical sections into one.** The window is now read, tested and updated
inside the same `storageLock` region as the append, and `reset()` clears it before releasing. A
side-effect worth naming: "this note was accepted" and "this note was stored" become a single
decision rather than two that could come apart if CoreMIDI ever delivered on more than one thread.
The monitor callback still fires outside the lock — monitoring must never be able to block capture.

**What the fix does not come with is a guard**, and shape 21's own rule says to build the smallest
thing that says no. Grep cannot express "this field is only touched inside a critical section". What
can is the pattern already in this file twice: `withRegistry` and `withHandlerLock` make the guarded
state unreachable except through a closure that holds the lock. Moving `storage`, `storageCount`,
`droppedNoteOns`, `firstDropHostTime` and `lastNoteOn` behind a `withStorage { }` of the same shape
would make the next instance a compile error instead of a review finding. Not done here, because it
is a refactor of the capture path and this branch is a defect fix; it is the first item in the queue
below.

### Finding 2 — thirty-eight lines of argument attached to the wrong declaration

Everything explaining `Stats.gappyLag1` — the per-run centring, the measured +0.27 the global-mean
alternative invents, the `- Parameter` and `- Returns` — was bound to `minimumRunLength`, because no
blank line separated the two doc comments and Swift binds a contiguous `///` run to whatever follows
it. `minimumRunLength`'s own first line arrived as the thirty-ninth line of an essay about a function
it is merely mentioned in, and **`gappyLag1` itself had no doc comment at all**: Quick Help showed
nothing for the function carrying §7.32's entire argument.

Text unchanged, block moved, blank line added. It is worth an entry only because of what it says
about the enforceable subset: `check.sh` re-derives every test count quoted in prose and resolves
every `LESSONS.md` citation, and cannot see that the most carefully written comment in `TimingCore`
was pointing at the wrong line for as long as it has existed.

### What the review found and did not fix

Recorded here rather than acted on, in the order they are worth doing.

| | Finding | Why it waits |
|---|---|---|
| 1 | **`MIDIInput`'s capture state has no structural guard** — see finding 1 | A `withStorage { }` refactor of the capture path, not a defect fix |
| 2 | **`events` holds `storageLock` across an allocation and up to 32,768 struct copies**, and the tempo drill calls it mid-take while notes arrive (`TrainerEngine.runTempo`). The comment justifying the lock says it is *"held for a handful of instructions"*, which stopped being true when §7.51 quadrupled the capacity | Same file, same seam as item 1; do them together |
| 3 | **Task identity lives in `TrainerKit`** — `GroupKey`, `BackingGroup`, `DropoutKey`, `FormKey` and `groupKey` are pure logic on the wrong side of the CI line. §7.28 calls this "one list of what makes two takes a different task" and three separate defects (§7.24 step 8, §7.48, §7.52) have been about it | R1.1.1 says analysable logic belongs in `TimingCore`; moving it puts the highest-defect-density logic in the project under the Linux leg |
| 4 | **CI covers 588 of 906 cases and compiles none of the macOS code.** `TrainerKit` (9,840 lines), the app (2,863) and `TimingSpike` never build in CI; `TrainerKitTests`' 318 cases and `selftest`'s 41 checks never run there | Known and stated (STANDARDS §9.4.2, `release.yaml.disabled`), and the reasons not to point an agent at the workstation still hold. What is *not* stated is that `--no-verify` is the only thing between that and nothing |
| 5 | **`OffbeatAnalysis.completeness` can exceed 1.0** on a repeated phase: `askedSet` dedupes for matching, `asked.count` does not, so `asking: [1, 1]` reads 2.0 on a field documented 0–1 | No caller does this today. Worth closing before the skank family grows past one figure, which is M16.5 |
| 6 | **62 merged branches survive locally and on the remote.** §8.1 says a merged branch that still exists reads as work in flight; `prune-branches.sh` exists and has not been run | Chore, one command |

**Items 1 and 2 are closed — see §7.58**, which also corrects item 2's cost, stated too high here.
**Item 3 is closed — see §7.60**, which landed it as M17's step 0 rather than as a chore, and moved
what CI covers from 550 of 832 cases to 566 of 848.

Item 3 was the one with a measurement argument behind
it rather than a hygiene argument. Item 4 is a decision rather than a task — the options are a macOS
agent on hardware that is not the workstation, or writing down that the hook is the enforcement so
its readers know they are it (shape 21's own fallback). Items 5 and 6 are small enough to ride along.

---

## 7.58 The capture state stops being reachable unlocked

§7.57 item 1, and it is the guard `LESSONS.md` shape 21 asks for rather than a second fix of the
same defect. The race was already closed; what was still true is that nothing stopped the next
field being added beside the lock instead of under it, which is exactly how `lastNoteOn` came to
sit there for the life of the project.

### The smallest thing that says no

Five properties and a lock became one `Capture` struct and a `withCapture { }` accessor — the shape
`withRegistry` and `withHandlerLock` already use twice in this file. `capture` is private, so the
only way to reach any of it is through the closure that holds the lock. **The next field added to
that struct is guarded by having been added to it**, which is the difference between a rule and an
enforcement.

It also removes the second way the defect could be spelled. Admitting a note and storing it used to
be two statements with a lock boundary available to fall between them; `Capture.admit` is one call,
so *"this note passed the dedup window"* and *"this note is in the buffer"* cannot come apart. What
that call returns is deliberately the first of those and not the second — a note the buffer had no
room for is still a note the player played, and the live instrument has to sound it. `dropped` is
what says whether it was kept.

### The payoff nobody was looking for

`CaptureLossTests` opens by saying the overflow *"cannot be provoked without CoreMIDI delivering
tens of thousands of packets"*, and that was true while the buffer's rules lived inside a private
method on the class that talks to CoreMIDI. A struct carrying a pointer and a count can be handed a
capacity of three.

So the two paths this project has only ever argued about in prose now have nine tests. **The end of
the buffer** — shape 20's fix, which has been shipped and reasoned about since §7.51 and never once
executed under test — and **the take boundary**, where §7.57's race lived. Neither test would have
caught the race, and no test could; what they hold is the behaviour either side of it, which had
nothing.

That is worth naming as a general result rather than a happy accident: **the refactor that made the
state unreachable also made it constructible**, and those are the same property seen from the two
sides. State only reachable through the object that owns a CoreMIDI port is state only testable
through a CoreMIDI port.

### Item 2, corrected downward

§7.57 said `events` holds the lock across *"an allocation and up to 32,768 struct copies"* and that
§7.51's capacity increase quadrupled the hold. **Both halves are wrong.** The snapshot maps over
`count`, the notes actually played, not `capacity` — so a dense take is tens of kilobytes and tens
of microseconds, and raising the buffer's ceiling changed nothing about it. The finding keeps its
heading and has its body corrected, the way a retracted result does.

What was actually wrong there was smaller and in three parts, of which only the last is a defect:

- The comment justifying the lock said it is held *"for a handful of instructions"*, which is true
  of the delivery path and not of the snapshot. `Capture.snapshot` now states its own cost where a
  reader meets it, rather than being covered by a claim that does not describe it.
- A comment in `runTempo` said `events` *"is written only by CoreMIDI's single delivery thread and
  read here on the take thread; a read racing a write can miss the very latest note"*. That
  reasoning predates the lock and describes an unsynchronised read the code has not performed for
  some time. A stale comment about concurrency is worse than none: it is what the next reader
  reasons from.
- **`runJam` and `runForm` each took two snapshots and treated them as one.** `notesCaptured` came
  from a second read of a buffer the delivery thread is still writing to, so a note arriving between
  the two was counted in the figure reported to the player and stored with the take, without being
  in the series that was analysed. One note, in a window of microseconds, on a number nobody fits a
  trend to — but it is a stored figure that could disagree with the take it describes, and the fix
  is a local variable.

---

## 7.59 The plan comes level with what is known

Two reviews and one conversation with the player left the roadmap describing a project slightly
different from this one. Nothing here is new work; it is the plan catching up to what §7.56, §7.57
and the player have already established.

### The milestone table was missing a third of the milestones

`AGENT.md` says *"PLAN.md §7's milestone table carries the status of each and is the one to trust."*
It carried M0–M22 and T1. **M16.5, M23, M24, M25, M26 and M27 were not in it at all** — they exist
as prose in §7.13, which is where their dependency order lives, and the table that a reader is
directed to as authoritative simply did not list them.

That is `LESSONS.md` shape 17 in the structural register rather than the numeric one: not a stale
figure, but a document pointing at another document as the source of truth for a set it does not
contain. Six rows added, and a line under the table saying the number is an identifier rather than
an order — because with these six included, numeric order and dependency order disagree badly
enough that the table would mislead on its own.

### M26 moves in front of the things waiting on it

Argued at M26's own entry. The short form: a kit that cannot deliver a genre has now blocked twice,
and the second block is worse than the first. §7.33 cost four style *names*. §7.56 cost a
*decision* — M16.5 cannot choose between two figures while neither can be heard as what it is meant
to be, and the player named the cause himself as the same handicap.

Only items 1, 3 and 4 are on M16.5's path — velocity layers, room, deterministic variation. The
whole milestone does not have to land to unblock the one waiting on it.

### M17 is a correctness milestone, and its step 0 already exists

Argued at M17's entry. §7.52 is the evidence and §7.57 item 3 is the first commit.

### M18 is gated on sittings, and the gate is now a number

Six sittings carrying the same task, three takes of it per sitting. Stated so it can be met and so
nobody builds against one afternoon.

### M21 and M22 stay, and the instrument axis is the genre axis

A review draft proposed parking both on the grounds that they serve players who do not exist. **The
player rejected that, and was right to.** He is the only user today and a public release is not
ruled out; more to the point, *"not everyone plays keys"* is the design stance rather than an
afterthought — he is a guitarist first, chose keys because it is the skill he is actively learning
and the best-instrumented input available, and wants guitar, bass, mic'd piano and voice when the
work reaches them.

What he added is the shape the roadmap should be read in: **instrument and genre are one axis, not
two.** Jazz is piano, drums and scat. Ska and reggae are guitar, organ and drums. A genre arrives
with its instruments and its kit or it does not arrive.

**The plan already contained that argument and had not connected it to the ordering.** The "M20
note" says a guitar skank, an organ bubble and a drum one-drop are *the same measurement* with
three inputs and three backings, and that a vocal skank is the same measurement again. M21's entry
already knows the TS→USB adapter exists, already says the thing to characterise is **spread rather
than offset**, and already warns that a driven amp smears the attack a detector needs. None of that
needed writing. What it needed was to be read together: the seam M20/M21/M24 widen is the seam
M26's kits sit in, and that is a third argument for M26 being early rather than late.

### The 35 ms is not a chosen feel — the player says so

§7.53 recorded the chop sitting ~35 ms ahead in every take and filed it as *"may be the feel he
wants… an open question rather than a fault"*. **Asked directly, the answer is no:**

> I do not know if the 35 ms I am ahead is intentional or not. Nor am I intentionally playing
> loose. I just want my timing to be tight, in the pocket, and on the mark in a general sense.

The question is answered and closed. It was worth asking rather than assuming, and the assumption
the readouts were carrying — that a consistent deviation is probably a preference — was wrong for
this player.

**What it exposes is a different gap from the one it closes.** §10 added "on the mark" on the
player's own words, with the rider that *"the measurement cannot tell those apart; the player
can."* That rider assumed the player knows which side of the beat he is on. He has just said he
does not. So the gap is not intent, it is **perception** — and a bias you cannot feel is one no
amount of practice corrects, because nothing tells you which way to move.

**The candidate instrument already exists in another form.** `review feel` asks whether a sense of a
good take matches the measurement, and gets a correlation. The same pattern one level down: before
any numbers, say whether that take felt **ahead, behind, or on it**, and correlate the answer
against the measured bias. It is the rate-before-results discipline applied to direction rather
than to quality, it needs no new drill and no new capture, and it settles which of two very
different problems "on the mark" is:

| If the correlation is | Then | And the work is |
|---|---|---|
| near zero | he cannot feel the direction he is off in | perception first — nothing else will stick |
| strong | he can feel it and is not acting on it | a correction target, and bias stops being decoration |

Not built, and deliberately not given a milestone number yet: it is one question on one screen, and
the honest first move is to ask it on the next few takes rather than to design a subsystem around a
correlation nobody has measured.

---

## 7.60 M17 step 0 — one list of what makes a task, where CI can read it

§7.57 item 3, and the first commit of M17 rather than a chore done beside it (§7.59).

### What moved

`GroupKey`, `BackingGroup`, `DropoutKey` and `FormKey` were private types inside `TrainerEngine` —
in the module that links CoreAudio, CoreMIDI and AVFoundation, on the side of the boundary the
Linux CI leg cannot compile. They are now `JamTask`, `BackingGroup`, `ContinuationTask` and
`FormTask` in `TimingCore/TaskIdentity.swift`, unchanged.

R1.1.1 says anything analysable goes in a pure module, and *"are these two takes the same task"* is
the most analysable question in the project. It is also the question three shipped defects were
about — §7.24 step 8 pooled the first skank ever recorded with 21 free jams, §7.48 drew one chart
line through groups the cards beneath it refused to pool, and §7.52 fed every skank to the **planner**
as an ordinary jam. All three were reachable only through a type that needs audio hardware to
instantiate, so none of them was reachable by the leg of CI that runs on every push.

**Sixteen tests now cover the list, and CI runs them.** What CI covers goes from 550 of 832 cases to
**566 of 848** — the first movement in that ratio since the review recorded it, and it lands on the
rules with the worst defect history in the codebase.

### The boundary, and what stayed behind

`TimingCore` depends on nothing (R1.1.3), and two things this logic used live in `GrooveCore`:
`BackingIdentity`, which parses a groove name, and `OffbeatLevel`, which names a level. Neither
could come. Both are resolved at the boundary rather than by weakening the rule:

- **The groove-name parse** is an `extension BackingGroup` in `TrainerKit`, where both modules are
  visible. The *rule* — fixed against generated, generated keyed on the style rather than the seed —
  is a grouping decision and sits with the other grouping decisions; reading it off a stored string
  is not. One construction site still, and `GeneratedBackingTrendTests` comes through it.
- **The offbeat level's word** is injected: `JamTask.title(offbeatLevelName:)` takes a function, and
  `TrainerKit` supplies the one implementation. `OffbeatAnalysis.suggestedLevel` already crosses this
  boundary the same way, taking an `Int` because the enum is `GrooveCore`'s. The level *number* is an
  axis and belongs here; what it is called is the backing module's word.

An unrecognised level now **drops its clause** rather than printing `offbeat level 9 — ` with nothing
after it, which is the honest behaviour and was not reachable before.

### The guard that came out of writing it down

`JamTask.rung` is a `String?` — the stored raw value, not an `IntervalRung`. That was true before the
move and looked like laziness; writing the doc comment made it load-bearing. **Decoding to the enum
would fold every unrecognised string into `nil`, and `nil` is free playing** — the largest and oldest
group in the corpus, and the series this project reads its progress from. A rung written by a newer
build would join it silently. As a string it groups on its own, and `title` gives it no name, so it
appears as a distinct unnamed group rather than as extra free jams.

That is `LESSONS.md` shape 13's shape again — a default that is not the identity — caught in a field
that already had the right behaviour for no recorded reason. It has a test now.

### What did not change, and how that is known

Every title, every grouping and every sort order. The evidence is that **all 832 tests that existed
before this branch pass unmodified**, including `TrendGroupingTests` and `ChartsAndTrendsAgreeTests`,
which are the two suites that exercise grouping through the engine. The only test edit was
`GeneratedBackingTrendTests` naming `BackingGroup` instead of `TrainerEngine.BackingGroup`.

---

## 7.61 The take says which kit it heard — M26 step 0

Found while scoping M26's velocity layers. **The kit is a confound and nothing has ever keyed on
it**, and that is not a hypothetical about the milestone ahead — it has already happened twice,
under a corpus that is still being fitted.

### The kit has changed under the corpus

| Date | Commit | What every take after it heard |
|---|---|---|
| 6 Aug | `58412ce` | A bass, where there had been none |
| 7 Aug | `b50d678` | Timekeepers accented — *"eight identical hi-hat hits a bar were eight copies of one buffer at one level, which is a metronome by construction"* — and two styles no longer doubling their timekeepers |
| 7 Aug | `f60b14a` | Every one-shot faded, removing a truncation click measured at −31.8 dBFS on the kick |
| 14 Aug | `bf2d7fc` | An organ |

Takes run 22 July to 13 August. **The 7 August pair sits in the middle of that**, and the click it
removed was found *by ear* — §7.31 calls it audible and an ear named it immediately. So takes either
side of it heard measurably different bands.

`JamTask.backing` keys on the groove name, and the groove name did not change. So `basicRock` before
the fade and `basicRock` after it are one group, and the project's longest series — 21 free jams at
100 BPM — spans the change with nothing saying so.

**This is §7.28's own rule failing on an axis §7.28 did not think of.** `AGENT.md`'s hard-won
invariants already carry *"a changed backing produced a 'real' 8 ms spread change that was partly
just different music"*. The list that came out of that reasoning covers *which* backing and never
*which kit played it*.

### What is and is not lost

**Nothing, as it happens** — and that is luck rather than design. A take stores its date, and the
changes are commits with dates, so which kit any existing take heard is recoverable by inspection.
That is the only reason this is a gap rather than a hole.

It stops being recoverable the moment the kit changes more than once between sittings, or changes
without a commit boundary a reader can find. M26 changes every voice at once and will take several
branches to do it.

### The field, and why it lands before the synthesis

R6.3 and §8.1.2's rollout order both say the same thing: **storage and identity first, written by
nothing.** A take recorded without a field is lost to that question for good, and an unused optional
breaks nothing. So `kitFingerprint` lands now, on all five take types, while the kit it describes is
still the one 104 takes heard.

**Derived, not declared.** A hand-bumped version number is a rule nobody is stopped from breaking —
`LESSONS.md` shape 21, which this project has five instances of and has just added a fifth guard for.
`BackingKit.fingerprint` is an FNV-1a digest over every rendered voice: change a decay constant and
it moves, leave the kit alone and it does not. It cannot be forgotten because nobody has to remember
it.

Three decisions inside it, each of which had a wrong answer available:

- **Rendered at a fixed 44.1 kHz, not at the output rate.** The buffers genuinely differ by sample
  rate, so a digest taken off the kit being played would make headphones and speakers read as two
  different bands. `KitFingerprintTests` asserts that difference exists, so the reason for the fixed
  rate is visible rather than folklore.
- **FNV-1a, not `Hasher`.** Swift's hasher is seeded per process: every take would record a kit
  nobody else had ever heard. A pinned literal in the tests fails the day someone swaps it back.
- **Length is mixed in.** The 7 August change was a *fade* — most samples identical, the tail and the
  length different. A digest over samples alone could collide on exactly the change that motivated
  the field.

**`nil` means unrecorded, not "the current kit".** Every take on record has it, and they span at
least two kits, so reading absence as any particular kit would be inventing data. It is the honest
value and it is why the field is optional.

### What this deliberately does not do

**Nothing reads it.** The kit is not an axis in `JamTask` and must not become one yet: there is
exactly one fingerprint in existence, so adding the axis today would split the corpus into
"unrecorded" and "current" on a distinction that is currently vacuous — and the 104 existing takes
would stop pooling with new ones for no acoustic reason. The axis is M26's to add, on the branch that
actually changes a voice, when there is a second fingerprint for it to mean something.

**It covers the sounds, not the music.** A style's steps and velocities are `GrooveCore`'s and are
keyed by style name and seed already. The *fixed* backing's patterns are keyed by neither — so
`b50d678`'s accent change to the generated styles is covered by nothing here, and a future change to
`jamBacking`'s own pattern would be equally invisible. That gap is real, smaller, and not closed by
this branch; it is recorded here rather than implied.

---

## 7.62 The kit becomes an axis, and changing it becomes a decision

§8.1.2 step 2, after §7.61's step 1. The grouping has to be right **before** the data exists, or the
first takes over a new kit are scored by a rule that then changes — and M26's whole job is to change
the kit.

### `nil` and the original kit are one group

The obvious reading of an absent fingerprint is "unknown, so its own group". **That is wrong here,
and expensively so.** All 104 takes on record predate the field. Grouping unrecorded apart from
recorded would split the corpus from every take made from now on — orphaning the 21-take free-jam
series, the longest in the project, on a bookkeeping distinction rather than an acoustic one. The
takes either side of the field's arrival heard the same kit; one of them wrote it down.

So `KitGroup(fingerprint:)` maps both `nil` and the pinned original to `.original`, and anything else
to `.changed`. Every title and every group is byte-identical to before today, which is the property
that says a grouping change has not quietly re-scored the history.

**The cost, stated where it is decided:** the 6 and 7 August kit changes sit *inside* `.original` and
this does not separate them. §7.61 found them; separating them needs the historical kits rendered and
fingerprinted, which nobody has done. **The method, for whoever wants it:** check out `58412ce^`,
`b50d678^` and `f60b14a^`, render `BackingKit` at 44.1 kHz under each, digest, and map takes to eras
by date — with the caveat that a take heard whatever build was *installed*, which can lag a commit,
so the attribution is bounded rather than exact. That uncertainty is why it is not being guessed at
here.

### The pin is a historical constant, and the test is the notification

`KitGroup.originalFingerprint` is `227944508dd5`: `BackingKit.fingerprint` as it stood on 15 August
2026. **It describes a kit that already existed, so it can never need updating** — which is what
separates it from a "current version" number, the kind of thing somebody has to remember to bump
(`LESSONS.md` shape 21, and this project's sixth encounter with that shape).

`KitFingerprintTests.testTheLiveKitIsStillTheOneEveryTakeOnRecordHeard` asserts the live kit still
matches it. **That test failing is not a defect — it is the notification.** The first change to any
voice fails it, and its message says what to do: add an era to `KitGroup` rather than editing the
pin, because takes over the new kit are a different task from the 104 before them. A kit change stops
being something that can happen by accident.

### All three drills, not just jams

The axis is on `JamTask`, `ContinuationTask` and `FormTask`. The continuation drill's band drops out,
but it plays either side of every silence and the re-entry error is measured against it. The form
drill's fills and crash **are** the landmarks the ladder removes rung by rung, so which kit plays
them is the task rather than decoration. A kit change that moved only the jam grouping would leave
the two drills whose landmarks are drum voices pooling across it.

### What this does not do

**It does not change a single group today.** There is one kit in existence and every take maps to
`.original`. That is deliberate and is the whole point of landing it before the mechanism: when M26
changes a voice, the rule is already in place and already tested, so the first take over the new kit
is grouped correctly rather than being grouped by a rule written after seeing it.

---

## 7.63 M26 item 1 — a drum hit harder is a different sound

The first change to the kit itself, and the first to trip §7.62's guard.

### What changed

Every unpitched voice now renders at **four strengths** instead of one, and the player picks the
layer from the hit's velocity before anything is scheduled. The render callback still indexes a flat
table and still never asks how hard a hit was (R2.3); the table just has four times as many rows.

**The boundaries come from what the styles actually write**, not from a tidy split. The patterns use
velocities from 40 to 108, clustered hard at 100: 40–60 for ghost notes and quiet timekeeper steps,
80–100 for everything that marks the beat. Four layers put the ghosts genuinely on their own —
three would have grouped 40 with 76, and the distance between those two is the milestone.

| Layer | Velocities | Strength | What it is |
|---|---|---|---|
| 0 | 1–55 | 0.30 | ghost notes, quiet timekeeper steps |
| 1 | 56–79 | 0.55 | the middle of an accented hat line |
| 2 | 80–103 | **0.75 — nominal** | the backbeat, and every take on record |
| 3 | 104–127 | 1.00 | the hardest thing a pattern asks for |

### Two properties that hold it together

**The nominal layer is the sound this kit has always made.** Every strength-dependent term goes
through `tilt`, which returns exactly 1 at nominal — *returns*, rather than computing `soft + (1 −
soft)·1`, which in binary floating point is 0.9999999999999999 at `soft = 0.3`. A hair on every
sample would have moved the kit fingerprint and re-scored the backing of 104 takes to no purpose. A
test walks the soft/hard pairs the voices actually use and asserts an exact 1.

**Strength carries timbre and length; loudness stays velocity's job.** Every layer is peak-matched to
the nominal one, so the gain formula is untouched and no new clipping is reachable — a hard layer
that were both brighter *and* hotter could push a coincident kick and crash past 0 dBFS on a
downbeat. `selftest` reports the mix peaking at 0.59 and every dynamics render lands between 0.12
and 0.58.

### What each voice does with it

Per voice, not one global tilt — §7.30's direction was *"no shortcuts"*, and a shelving filter over
a finished buffer is the shortcut. The snare is the voice §7.30 names: a hard hit throws the snares
and the rattle dominates, a ghost barely engages them and what is left is the head, over much sooner.
The kick moves the beater against the body, because on a hard kick the click *is* the attack. The hat
gets noisier and rings longer. The crash is the voice where length simply is the dynamic.

**The shaker ignores strength, and that is the interesting one.** Its own doc comment already said
why — *"a shaker that could be accented would become a second snare"* — so it is the one voice where
the correct response to a harder hit is no response. There is a test asserting it stays that way.

### The guard worked, and so did its instruction

`testTheLiveKitIsStillTheOneEveryTakeOnRecordHeard` failed on the first build, which is what §7.62
built it to do. It also caught something else: the fingerprint moved *before* the layers existed,
because one edit had routed the cowbell's `tanh` through `saturate`, which works in `Float` where the
original was `Double`. A rounding difference in one voice, found by a test written for a different
purpose an hour earlier.

The kit is now `e4304cb6e4c3`, and `KitGroup.known` names it "velocity layers". **The list is appended
to, never edited**: each row describes a kit that takes were played over, so correcting one would
re-label takes that heard something else. A kit missing from the list still groups correctly and
prints its digest instead of a name.

### What is not done

**The bass and organ are not layered.** They are pitched, so layering them multiplies buffers by
notes — 25 bass notes × 4 layers — and neither has a dynamic role in any current pattern. A gap
rather than a decision, and it is where this should go next if the ear asks for it.

**Nobody has heard it yet.** `render` now writes a `dynamics-<voice>` file per voice: four bars, one
per layer, four hits a bar, nothing else playing. That is the file this milestone is judged on.
`selftest` can say the mix does not clip and a test can say the buffers differ; whether a ghost note
stops sounding like a fader move is a listening question, and §7.56 is what happens when one of those
gets answered by argument instead.

---

## 7.64 The layers were inaudible, and every test passed

§7.63 shipped velocity layers. The listening verdict:

> I listened to the files, it sounds like the same sound just quieter to louder.

**The milestone's own goal, not met** — and nothing in the suite noticed, because the tests asserted
the layers were *different* and a difference nobody can hear satisfies that.

### What the measurement said

Nothing had ever measured the thing the layers exist to move. Adding a spectral centroid and an
audible-duration function took ten minutes and settled it immediately:

| Voice | Soft centroid | Hard centroid | Ratio |
|---|---|---|---|
| snare | 349 Hz | 1189 Hz | 0.29 |
| **closed hat** | 6609 Hz | 6449 Hz | **1.02 — and the wrong way round** |
| **kick** | 114 Hz | 130 Hz | **0.88** |
| **ride** | 5183 Hz | 5292 Hz | **0.98** |

The snare moved because its two components — head and rattle — sit in different registers, so
shifting the balance between them shifts the spectrum. Every other voice's components sit on top of
each other, and rebalancing them moves nothing. **The first pass changed what the voices were made
of and not where their energy sat**, which is the half an ear listens to.

### Three fixes, and one of them was a bug

**Darkening, relative to the voice's own centroid.** A softer strike excites fewer high modes, and
that cannot be expressed as a rebalance of components already present — it needs a filter. Cutoff
scales with the voice's *own* centroid rather than an absolute corner, because one corner cannot
serve a kick at 128 Hz and a hat at 6.4 kHz: it annihilates one or misses the other.

**Capping the peak instead of matching it.** Matching was in §7.63 as the clipping guarantee, and
darkening exposed what it does: filtering lowers a layer's peak, matching scales it back up, and the
ghost snare came out carrying *more* total energy than the backbeat — 198 against 209. A quiet stroke
that carries more energy than a loud one is not a quiet stroke. Capping keeps the guarantee (nothing
is hotter than what already shipped) and lets a soft layer be genuinely quieter, so the timbre and
the velocity gain pull the same way instead of against each other.

**The shaker was being accented.** `raw` honoured the opt-out and `render` darkened it anyway, so
**the one voice documented as unaccentable had the largest timbre change per unit of velocity in the
kit** — 0.51 of its own centroid. `LESSONS.md` shape 21 inside a single file: the rule was in one of
the two places that had to honour it. `DrumSynth.unaccented` is the one list now.

After: energy ratios run 0.02–0.14 and centroid ratios 0.14–0.78, against 0.88–1.02 before.

### The tom is the exception, and it is an honest one

It measures 0.95 and no tuning fixes it: the tom is a pure pitch-swept sine with no noise, click or
wash, so a softer strike has nothing to fail to excite. Every other voice in the kit has a component
that a soft hit leaves alone. **The fix is a stick transient**, which is synthesis work rather than
tuning, and it is not done. A test asserts the tom *stays* the exception, so if it ever moves the
exception gets removed rather than accumulating company.

### The lesson, which is about the tests rather than the synthesis

**A test that a value changed cannot protect a value changing enough.** `testEveryLayeredVoiceRespondsToStrength`
asserted `XCTAssertNotEqual` on two buffers and passed on a 2% difference in the wrong direction. It
was not a weak test by accident — it was the strongest assertion available *without a measurement*,
and the measurement did not exist because nothing had needed it yet.

That is `LESSONS.md` shape 18's family — a guard on the wrong quantity — and shape 11 for the
ranges themselves, which were reasoned to rather than measured and were wrong. The thresholds now in
the suite are floors well below what the kit measures, so ordinary tuning does not trip them and a
collapse back toward one-buffer-two-gains does.

### The pin moved, which the rule usually forbids

`KitGroup.velocityLayeredFingerprint` was edited rather than appended to. That is safe **only**
because the kit it named never reached a stored take: it existed inside an open branch, was found
inaudible, and was retuned before anything was recorded over it. A row nobody's data points at is a
draft rather than history. After a kit has been played over, append.

---

## 7.65 M26 item 3 — the kit gets a room

§7.30 item 3, and its own claim: *"the kit is bone dry, and dryness is most of what reads as
electronic. Early reflections and a short tail would do more for believability than any amount of
spectral work on the voices themselves."*

### Why this can be baked into the one-shots

The render callback may not synthesise anything (R2.3), so a reverb *in the mix* has nowhere to run.
Baking the room into each voice at startup is not a workaround for that. **A room is a linear
time-invariant filter, so filtering each voice and summing is identical to summing and filtering** —
every voice goes through the same room, and the result is the signal a shared reverb would produce,
computed once instead of per sample.

That equivalence is the whole licence, and it holds only while the filter is the same for every voice
and constant in time. A per-voice room, or one reacting to what was playing, would be neither bakeable
nor a room.

**A recursive network rather than an impulse response**, because convolving a 0.32 s kick with a
0.35 s tail is 200 million multiply-adds and there are 52 buffers — minutes of startup for something
four combs and two allpasses give in milliseconds.

### What was built

Five early reflections as taps on the dry signal, then a damped Schroeder network: comb delays at
mutually incommensurate spacings so the tail builds density rather than ringing at a pitch, feedback
set per comb from its own delay so they all reach −60 dB together, and a one-pole in each feedback
path because a real tail darkens as it decays. 0.34 s reverb time — a drum room, short enough that a
sixteenth at 160 BPM is not still sounding when the next three arrive. 20% wet: the *cue* that a room
exists, not an audible effect.

**The order in the chain is not arbitrary.** Darkening is a property of the strike and belongs on the
dry voice before it reaches the walls — filtering the room's return instead would darken a hard hit's
reflections as though the room changed with velocity. The fade comes after the room, because the room
is now what ends last and a truncated tail is the same step discontinuity §7.31 removed from the
voices, one level further out.

### The room compresses the low voices' colour, and that is acoustics

`VelocityLayerTests` asserts a soft layer is substantially darker than a hard one. The room broke it
for the kick, which went from 0.78 of its own centroid dry to **0.85** in the room. Not a tuning
failure: **a room returns something brighter than a kick, so the reflections dominate a low voice's
centroid and compress the ratio.** It is why a real kick is close-miked.

Measured across the kit, the split is clean rather than a judgement call:

| | Nominal centroid | Soft ÷ hard |
|---|---|---|
| kick | 117 Hz | 0.85 |
| tom | 144 Hz | 0.90 |
| *everything else* | 478 Hz – 10 kHz | 0.24 – 0.60 |

So the exemption is defined by **where a voice sits**, not by a list of names that failed — and a
test pins the membership at exactly `{kick, tom}`, so it cannot quietly grow to cover a voice that
merely stopped working. Those two are asserted on energy instead, which they carry as strongly as
anything else.

The tom remains the weaker of the two for its own separate reason (§7.64): a pure swept sine with no
transient has nothing for a soft strike to fail to excite.

### What it cost, and the part worth watching

**`swift test` went from 145 seconds to 246.** Building a kit means 52 buffers through the comb
network in a debug build, and four suites were each building their own — 210 of those seconds were in
those four.

That is not a patience problem. `check.sh --fast` runs through the pre-commit hook on every commit,
and **a gate slow enough to be worth skipping is a gate that gets skipped** — `LESSONS.md` shape 21
arriving by way of the clock rather than by way of an unenforced rule. A shared `TestKit` and one
hoisted measurement brought it to 167 seconds, which is a 15% rise over the pre-room suite for a
feature that genuinely costs something.

Two smaller wastes surfaced on the way. `render` was rebuilding the nominal reference for *every*
layer of every voice, so the whole chain ran twice per layer; `renderLayers` builds it once. And a
`where` clause was recomputing the low-voice set once per voice.

### A duplicated heading, found while writing this

§7.64's edit left `## 8. Project layout` in the file twice: the inserted text ended with the same
anchor it was inserted before. Harmless to a reader and invisible to `check.sh`, which checks quoted
figures and shape citations and has no opinion about structure — worth noting because it is the
second documentation defect this month that a green gate had nothing to say about (§7.60's
misattached doc comment was the first).

### Unheard, and what to listen for

The kit is `0a99f6f3a74e`, which `KitGroup.known` names "room" — appended, not edited, since
"velocity layers" has now shipped. Mix peak is unchanged at 0.59 and no render clips.

**What this needs an ear for is not "is there a room"** — there is, by construction. It is whether the
transient survived. This project measures placement against the backing, and a wash that softens the
attack would make the ruler blurrier at the same time as it makes the kit more convincing. If the
groove sounds better but the beat feels harder to locate, the mix is too high and that is a one-line
change.

---

## 7.66 M26 item 4 — no two hits alike, and what the measurement changed

§7.30 item 4: *"every hit is byte-identical to the last, which no acoustic instrument is."* The last
of the three items §7.59 pulled forward, and the one where the design changed because a measurement
contradicted the plan.

### The plan was round-robin variants. The measurement killed it.

§7.30 proposed *"round-robin sample selection or small seeded parameter jitter"*. Round-robin is the
better of the two — a genuinely different waveform rather than the same one at a different level — so
that is what was scoped.

Then the render chain was timed, per voice, per stage:

| Stage | One pass over 13 voices |
|---|---|
| `raw` synthesis | 0.4 s |
| centroid, for the darkening corner | 1.2 s |
| **the room** | **4.5 s** |

A kit renders four layers per voice, so a kit build is four of those passes — 24 seconds in a debug
build, which matches what it measures. **Every extra variant is another 18 seconds**, and the suite
that runs on every commit is 167 seconds total. Three variants would have tripled the gate's cost;
and the alignment problem below means two or four are *worse than none*, so three is the floor.

So: **level variation now, timbral variants deferred with the number attached.** Not abandoned — the
render chain has to get cheaper first, and §7.65 already found that the room dominates it.

### The trap that decides the mechanism

**A cycle whose length divides the bar makes the machine quality worse.** Patterns here are 16 steps
to the bar. Four variants put the same one on every downbeat and the same one on every backbeat: a
pattern *inside* the variation, aligned to the pattern it exists to break up. Two alternate, which is
more audible still. Three shares a factor with the 24-step grid M19 re-voiced onto.

A hash of the hit's index has no period short of the mixer's, so nothing lines up with anything. It
is also **stateless**, which a generator advanced per hit is not: the same arrangement has to produce
the same audio however the hits were sorted or filtered (R1.2.2), and a running RNG cannot promise
that. A test samples the stream at every bar-aligned stride and requires it to keep varying.

### What varies, and what deliberately does not

**Level only.** Not timing — the backing is the ruler this project measures against, and a band that
moved would put its own jitter into every number. Not the layer either: jitter crossing a velocity
boundary would change the *accent* the pattern wrote, and the accents are the groove.

**Attenuation only, never boost**, so nothing is louder than the mix that already shipped and the
clipping guarantee needs no re-checking — the same reasoning as capping a layer rather than matching
it (§7.64). The cost is the band sitting about 0.8 dB lower on average, which is below noticing and
well inside the headroom. Depth is 0.17, roughly 1.6 dB at the extreme.

**The kit fingerprint does not move.** Variation happens when a piece is scheduled, not when a voice
is rendered, so it changes the performance rather than the instrument — no new `KitGroup` era, and
takes over this build group with the room takes.

### Where it lives, and why that is not where it started

The per-voice occurrence counting began inside `GroovePlayer.schedule`, which runs behind an audio
device — `LESSONS.md` shape 1, the most common shape in this project, committed while writing the
milestone that has been citing it. `Variation.gainScales(for:)` is `GrooveCore`'s now, so the ten
tests over it run on the Linux CI leg with no hardware, and what CI covers goes from 572 of 878 cases
to **582 of 888**.

Counting is per voice rather than across the schedule, so adding a cowbell does not re-roll every
hi-hat — a piece must not change because something else was added to it. That has its own test.

### A speedup that was left on the floor on purpose

Measuring the darkening corner once per voice rather than once per layer saves about 0.8 seconds of a
24-second build. It also changes what the soft layers are filtered against, which changes the kit,
which costs a new era and another listening test. **Not worth it**, and recorded here so the next
person to spot it does not spend the afternoon finding out why it was passed over.

What was kept is the room's inner loops rewritten onto unsafe buffers, which is output-identical —
the fingerprint test confirms it — and modest: 26.6 s to 24.0 s. The cost is not bounds checking; it
is four room passes per voice.

---

## 7.67 M26 item 2 — a kit is a parameter set

§7.30 item 2: *"a Motown snare is tuned high and damped; a rock snare is fatter and rings. Same
synthesis, different tuning, decay and noise balance."* Called out there as **architectural rather
than tuning**, and that is exactly how it lands: the mechanism, with every style still on the kit it
already had, and **not one sample of audio changed**.

### What a style can now say

`KitSpec` carries seven numbers — snare tuning, decay and rattle; kick tuning and decay; cymbal
decay; room amount — and `Style` carries one. Until this existed every style in the library played
the same drums, so a genre name could only ever be a claim about the *steps*. That is what §7.33
heard: four styles that came out as *"beat #3 rather than oh, a Motown beat"*, three of them renamed
because the name promised what the kit could not deliver.

**Room amount is a kit parameter, not a global.** A sixties soul record and a modern rock one differ
in the room before they differ in the snare, and putting it on the spec is what lets one style be
drier than another rather than the whole app being.

### Multipliers, and why that makes the default free

Every field multiplies, and `standard` is 1 everywhere. **The standard kit is bit-identical without a
branch**, because IEEE guarantees `x * 1.0 == x` — the synthesis applies the parameters
unconditionally and there is no default-only path to get wrong. That is a stronger guarantee than
`DrumSynth.tilt`'s, which genuinely needs its early return: `soft + (1 - soft)` is not exact, a bare
multiply is (§7.63).

It also keeps the numbers readable as intent. `snareDecay: 0.7` says *damped* to anybody;
an absolute 42 ms says it only to whoever remembers the default.

### The kit resolves where the arrangement does

`JamConfig.backing` returns the name, the arrangement **and the kit** from one place. That property's
doc comment already explained why it is one place — a style resolving differently in two would be
`Feel`/`Swing`'s failure mode, a backing that disagrees with the take stored beside it (§7.24 step 7,
which cost both swung takes on record). Adding a third thing that has to agree made the argument
concrete rather than hypothetical, and the take now records the fingerprint of the kit **it actually
heard** rather than the build's default.

### The finding: the centroid lies about tonal content

Two knob tests failed, and the failure was more interesting than the knobs. Raising the snare's
tuning by 1.35 made its measured spectral centroid **fall from 918 Hz to 278** — a threefold drop
from tuning something *up*.

`DrumSynth.centroid` probes a log-spaced ladder at 1.25× spacing with no window. A pure sine landing
between two probes reads far weaker than the same sine landing on one, so raising the partials from
180/330 Hz to 243/446 moved them nearer a probe and the tonal energy suddenly registered — pulling
the average down toward it. **The knob was right and the ruler was wrong.**

Three consequences, in descending order of how much they matter:

- **Tests about known frequencies now ask at those frequencies.** `DrumSynth.power(of:atHz:)` is a
  single-bin Goertzel, which is exact when you already know where to look. The snare test asserts the
  power at 243 Hz rose fourfold and at 180 Hz fell to a quarter.
- **`darkened` reads the same centroid and keeps it.** It needs the voice's rough register to place a
  filter corner, not its spectrum, and whatever it reads it reads consistently — the kit is stable and
  the player has approved how it sounds. Changing it would change the kit for a measurement nicety.
- **The velocity-layer centroid ratios inherit the same limitation**, and the tom is the voice most
  exposed to it: a pure swept sine is exactly the content this measure is worst at. §7.65 records the
  tom at 0.90 and reasons about it as physics; part of that number may be the ladder rather than the
  drum. The energy assertions beside it are unaffected, which is why the exemption is safe.

### What is deliberately not here

**No style has been given a kit.** Every one is still `.standard`, so the library sounds exactly as it
did and the fingerprint has not moved. Tuning four styles is a listening job, and doing it in the same
branch as the mechanism would mean an architectural change and an audible one arriving together with
no way to tell which broke what — §8.1.2's whole argument. That is the next branch, and it is the one
that needs an ear.

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
└── Tests/                   906 cases
    ├── TestSupport/         shared generators — not a test target
    ├── TimingCoreTests/     439 cases against synthetic ground truth
    ├── GrooveCoreTests/     149 cases — patterns, sequencer, styles
    └── TrainerKitTests/     318 cases — storage, config, sessions. macOS only, so
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
10. **Whether two seeds of one style pool honestly in a trend is unmeasured** (M19 step 7, §7.29). The argument that they should is structural — the generator selects among bars the style already defines and never invents or moves a hit, and `density` and `carriesBass` belong to the style rather than the seed — but no take over a generated backing exists, so the between-seed variance has never been observed. Until it has, the generated side of the trend groups by style and **says the pool mixes seeds and that the cost is unquantified**. Once a style has takes on two or more seeds it is directly estimable, and it is the same two-stage question `Bootstrap` answers for takes within a condition (R3.2, row 3): comparable to the between-take spread and seeds pool honestly, larger and the seed goes into `GroupKey`.

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
