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
| **M0** | **Timing spike + ground-truth rig (console)** | Click, Launchkey capture, host-time ↔ sample-index bridge, and the §4.2 two-path validation with its four automated pass criteria. **The whole project rests on this.** Also yields the Launchkey's key-scan latency as a by-product. |
| **M1** | Calibration | Chirp loopback cross-correlation via built-in mic; Bluetooth detection + refusal; per-device storage with reference-derived constants for devices that skip the full run. See §7.2. |
| **M2** | `TimingCore` + tests | ✅ Done. Pure analysis module, 25 XCTest cases against synthetic ground truth. See §7.3. |
| **M3** | Groove engine | ✅ Done. `GrooveCore` (patterns, sequencer, dropout ladder) + synthesized kit + `GroovePlayer`. See §7.4. |
| **M4** | Jam capture loop | ✅ Done (console). `jam` records a take against the groove, applies calibration, runs the report, saves the session. SwiftUI shell deferred — see §7.5. **First version you actually practice with.** |
| **M5** | Review screen | Swift Charts, the full metric set, plain-English headline. |
| **M6** | Adaptive dropout ladder | The training mechanic, difficulty driven by measured drift. |
| **M7** | Progress over time | Longitudinal trends. Is SD falling? Is `r₁` moving toward zero? |
| — | *Later* | Guitar onset detection; TD-6V; GarageBand via IAC Driver; MIDI/audio export of takes. |

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

**Reported failure modes to design against** (the player's own account): losing count or
over-stressing bar count; overthinking what to play next; attention wandering until "brain
jumps out of sync with body," then trying to consciously jump back in. All three are
*conscious-monitoring* failures, and the last one is the most telling — the recovery attempt
is itself the disruption. Drills should reward re-entry by feel and never require a running
count.

---

## 8. Project layout

Swift Package Manager modules, consumed by a thin Xcode app target:

```
Target layout (SPM library + thin app), grown incrementally rather than up front:

```
Musical Trainer/
├── Sources/
│   ├── TimingCore/      # ✅ pure Swift. Grid, matching, asynchrony analysis,
│   │                    # W-K decomposition, autocorrelation. No UI, no AVFoundation.
│   ├── TimingSpike/     # ✅ console tool: audio/MIDI capture, calibration, the M0 rig.
│   │                    # Will split into AudioEngine + MIDIIO as the app grows.
│   └── (App/)           # SwiftUI take/review/settings — M4+.
└── Tests/
    └── TimingCoreTests/ # ✅ 25 cases, synthetic ground truth.
```

The current `TimingSpike` target still holds the audio (`AudioIO`), MIDI (`MIDIInput`),
calibration, and DSP code together; §8's `AudioEngine` / `MIDIIO` / `Persistence` split
happens when the SwiftUI app needs them as libraries. `TimingCore` is already carved out,
because its boundary is what makes the numbers trustworthy. Keep it clean.

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

---

## 10. What success looks like

Not "SD under 10 ms," though that will happen. Success is:

- `r₁` near zero **while playing something musically demanding** — the oscillator holds under load.
- Drift under a few ms/bar through 8 bars of silence.
- Clock variance low enough that remaining error is motor noise — at which point the training target changes entirely.
- And the one that actually matters: an hour goes by and it felt like flow, not work.
