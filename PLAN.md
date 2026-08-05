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
| **M5** | SwiftUI app + review | ✅ Done. Eyes-off take screen, rate-before-results, Swift Charts review, history. See §7.6. |
| **M6** | Dropout / continuation drill | ✅ Done. The only drill that yields a clock/motor split. See §7.7. |
| **M7** | Progress over time | ✅ Done. `review trend` fits each metric with a bootstrap interval and splits confounded groups. See §7.8. |
| **M8** | Tempo calibration drill | ✅ Done. Closed feedback loop on the tempo bias §7.8 found. See §7.10. |
| **M9** | Session builder | ✅ Done. The app proposes a 20/30/45 min session from recent data and runs it end to end. See §7.14. |
| **M10** | Cold vs warm | ✅ Done. Within-sitting warm-up separated from between-sitting learning. See §7.15. |
| **M11** | Clock stability drills | ✅ Done. The recall drill: is the period stored, or only held by keeping it running? See §7.16. |
| **M12** | What you play | ✅ Done. Content measured per window against timing, within-take. See §7.18. |
| **M13** | Experiment runner | The app schedules its own A/B comparisons and says when they have power. |
| **M14** | Subdivision ladder | Eighths, sixteenths, triplets. Everything so far is quarters. |
| **M15** | The feels | Swing, jazz comping, ska/reggae offbeat, latin. Placement as style, not error. |
| **M16** | Form ladder v2 | Phrase length as a trained variable, after the 4-bar finding. |
| **M17** | Unified adaptive difficulty | One progression model across all drills, replacing four ad-hoc rules. |
| **M18** | Longitudinal model | Within-session vs between-session effects, separated properly. |
| **M19** | Musical depth | Enough variety that a 30-minute session stays worth doing. |
| **M20** | Drum mode | Pads and keys become the kit; the click becomes the band. |
| **M21** | Guitar input | Audio onset detection. Needs an interface. |
| **M22** | Computer-keyboard input | For anyone who doesn't own a MIDI controller. |
| — | *Later* | TD-6V; GarageBand via IAC Driver; MIDI/audio export of takes. |

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

## 7.13 Roadmap M9–M22

Direction set with the player: **training depth** over new instruments or packaging;
**20–30 minute structured sessions**; **research built in as a first-class feature** rather
than run by hand. Ordered by dependency and value, not difficulty.

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

### M14 — Subdivision ladder
Every drill so far is quarter notes, straight. This adds eighths, sixteenths and triplets —
both as backing and as what the player is asked to produce. `TimingReport` already computes
subdivision-conditional spread and nothing currently exercises it. Straight time only; the
grid stays where it is.

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

### M17 — Unified adaptive difficulty
Four drills now have four ad-hoc progression rules. Replace them with one model: a per-axis
difficulty estimate updated from measured performance, so the app can say "you are ready for
8 silent bars but not 16" consistently and across drills.

### M18 — Longitudinal model
Separate the two effects properly — within-session improvement (warm-up) from
between-session improvement (learning) — instead of fitting one slope across everything.
M10 does this for one metric at a time; this generalises it into a single model over all of
them, and subsumes the current `review trend`.

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

### M21 — Guitar input
Audio onset detection through an interface, reusing the calibration and analysis already
built. A new input is additive once the drills and measurement are mature, and it is the only
item requiring hardware the player does not own.

### M22 — Computer-keyboard input
Timing capture from the Mac keyboard, for anyone who does not own a MIDI controller. Last on
purpose, and not only by priority: key-repeat suppression, rollover limits and the fact that
HID timestamps are not driver-level MIDI timestamps all mean the *measurement quality* would
have to be characterised from scratch — an M0-style validation run of its own before a single
number could be trusted. Better as an on-ramp for other players than as a way for this one to
practise.

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

### What it says today

`review cold`, on the current history:

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

## 7.20 Second codebase review — ten findings, and the order they get fixed

A full pass over the tree before M13 starts, on the principle that an experiment runner
inherits every weakness of the statistics underneath it. The gate was green at the time of the
review and stayed green throughout: 175 tests then, 36 selftest checks, a warning-free release
build, every stored take decoding, the 46 takes on disk matching the counts quoted in
`AGENT.md`.

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

### 3. The last content window's density is understated

`MusicalContentAnalysis.analyze` rounds the window count up, so the final window runs past the
end of the take, but `measures(of:overBeats:)` always divides by the *full* window length.
`eventsPerBeat` in that window is scaled by however much of it was real playing.

Note density is not an incidental measure here: it is trap 2 of the three §7.18 names, the
confound the whole report is written around, and it is reported as its own row precisely so a
content effect can be separated from a note-values effect. Biasing it in one window of every
take puts a thumb on that scale. The fix is to drop a final window that covers less than most
of its span, and to normalise by the span actually measured otherwise.

### 4. `review trend` renumbers the take axis when a take is unscorable

`TrendAnalysis.fit` filters non-finite values and then builds its x-axis as `0..<clean.count`.
A take whose metric could not be computed does not leave a gap in the axis — it compresses it,
and every later take slides one place earlier. The slope is then per *usable* take while every
label, every unit string and the doc comment say per take.

Small in this dataset and not small in principle: it is the same class as the stale-cache
defect §7.12 found, where a plotted number was not the number the analysis produced. The fix
is to carry the original index alongside the value.

### 5–8. Enforcement gaps and small stuff

| # | Finding | Why it matters |
|---|---|---|
| 5 | `check.sh`'s force-unwrap rule only matches `!` followed by `.`, so bare force-unwraps pass. Six live in `Sources/`: `DropoutAnalysis.swift:163`, `WarmUpAnalysis.swift:119`, `Commands.swift:636`, `:723`, `:727`, `:1200`. | Every one is guarded by a preceding filter, so none can trap today. The defect is that the gate reports a rule as held when it is not — R4.7 is unenforced, and the next one may not be guarded. |
| 6 | The decode gate cannot fail. `check.sh` runs `review list` and tests the exit status, but `SessionStore.load` writes its "could not be read" note to stderr and returns whatever decoded; the CLI exits 0. | R6.1 says every take ever recorded must continue to decode, "verified by running `review list`". A schema change that orphaned the entire history would still print `PASS`. The check must read the note, not the exit code. |
| 7 | The M7 trend doc comment sits above `runContent` (`Commands.swift:986`); `runTrend` at `:1078` has none. | Left behind when M12's command was inserted. §0 of `STANDARDS.md` treats misplaced content as a defect; a comment describing the function above it is worse than none. |
| 8 | `MemorySession.roundWindows` indexes four parallel arrays by `roundConditions.indices`. | A length mismatch traps instead of reporting, which is the failure mode R6.4 exists to prevent — a storage inconsistency should be legible, not a crash on load. |

### 9. Neither the content nor the condition readout exists in the app

The app's History carries trends and the warm-up card. `review content`, `review tags`,
`review conditions` and `review feel` are console-only.

That was tolerable while the console was where analysis happened. M13 makes it a real problem:
the experiment readout — which arm is ahead, how many takes remain, whether the app will
conclude anything — *is* the milestone's output, and the app is where sessions actually get
run. A milestone whose result the player never sees where they practise has not shipped.

This is not the `R1.1.2` violation it might look like; no measurement moves. It is a surface
gap, and M13 step 5 closes it for the experiment readout at minimum.

### 10. `AGENT.md` pointed at the wrong live session — fixed in this pass

It called 4 August (§7.17) "the last live session". The last one is 5 August (§7.19), which
retracted a finding and forced three fixes. An operating manual that sends a reader to the
second-most-recent findings is exactly the failure the closing documentation step in §8.3 of
`STANDARDS.md` exists to catch — and it was introduced *by* a pass that updated the milestone
table and not the sentence under it.

Corrected here rather than queued: a wrong pointer in the operating manual misleads every
reader who arrives before the queue drains, and the fix is one sentence.

### Fix order

Findings 1 and 2 are M13 prerequisites: the first because every conclusion the experiment
runner draws goes through it, the second because the recall comparison is one of the first
three experiments and would re-inherit the bias. Everything else is sequenced after them
because none of it is load-bearing for the milestone.

| Step | Fixes | Where |
|---|---|---|
| 0 ✅ | 1 — cluster bootstrap; `review tags` / `review conditions` moved onto it | `TimingCore/Bootstrap.swift` |
| 1 | 2 — per-condition attrition, reported and caveated | `TimingCore/TempoMemory.swift` |
| 2 | 3, 4 — partial content window; trend take axis | `TimingCore` |
| 3 | 5, 6 — close both enforcement holes, then fix what they surface | `scripts/check.sh` |
| 4 | 7, 8 — comment placement, parallel-array decode | mixed |
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
| 1 | `ExperimentAssignment` storage, written and unread |
| 2 | `Experiment.swift` — design, arms, seeded balanced assignment, stopping rule |
| 3 | `ExperimentAnalysis.swift` — pooled arm comparison, minimum detectable effect, takes-needed, confound and attrition checks. Settles the pooled-estimand question from finding 1. |
| 4 | Planner blocks at locked parameters (R3.5), arm-specific instructions (R3.6), engine wiring |
| 5 | Console `experiment` + `review experiment`, and the app card (finding 9) |
| 6 | `PLAN.md` as-built, `README.md` command table, `AGENT.md` state |

The first three experiments, chosen by what they unblock: **steady vs melodic** (the
mode-of-playing hypothesis §7.19 says M12 cannot test), **silent vs filled retention pooled
across takes** (n = 2 per direction with no interval, and finding 2 must land first), and
**relaxed vs focused** (§5.1's founding prediction — that focusing drives r₁ sharply negative
— has never once been tested).

Steps 4 and 5 touch the runner and the instruction path, which have no unit tests and will not
get them. Per R5.6 they need a live session and the result goes here. Two of the three defects
the first live session found were instruction and reporting bugs; expect the same class again.

---

## 8. Project layout

Swift Package Manager, five targets. The split is not cosmetic: the two pure modules are what
make the numbers testable, and the rule that keeps them honest is that **anything analysable
goes in `TimingCore` or `GrooveCore`**, because only those run under `swift test` against data
whose answer is known by construction.

```
Musical Trainer/
├── Sources/
│   ├── TimingCore/          pure analysis. Grid, matching, W-K split, autocorrelation,
│   │                        bootstrap, form, tempo calibration, tempo memory, trends,
│   │                        warm-up decomposition, the session planner.
│   │                        No AVFoundation, no CoreMIDI, no CoreAudio, no UI.
│   ├── GrooveCore/          pure groove generation. Patterns, sequencer, arrangements,
│   │                        dropout ladder, form backings, the aperiodic distractor.
│   │                        Same purity rule; depends on nothing, not even TimingCore.
│   ├── TrainerKit/          audio, MIDI, synthesis, calibration, storage, the drill
│   │                        runners (`TrainerEngine`), `SessionRunner`, console layer.
│   ├── TimingSpike/         console front end (main.swift only).
│   └── MusicalTrainerApp/   SwiftUI front end.
└── Tests/
    ├── TimingCoreTests/     synthetic ground truth
    └── GrooveCoreTests/
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

---

## 10. What success looks like

Not "SD under 10 ms," though that will happen. Success is:

- `r₁` near zero **while playing something musically demanding** — the oscillator holds under load.
- Drift under a few ms/bar through 8 bars of silence.
- Clock variance low enough that remaining error is motor noise — at which point the training target changes entirely.
- And the one that actually matters: an hour goes by and it felt like flow, not work.
