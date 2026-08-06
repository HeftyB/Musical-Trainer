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
| **M13** | Experiment runner | ✅ Done. Preregistered A/B experiments: arms assigned and counterbalanced before play, no verdict before the declared n. See §7.22. |
| **M14** | Subdivision ladder + tempo | ✅ Built, **never run live**. Rungs, tempo ceilings derived from the matching window, a tempo-rotating training block, and `slow-vs-fast`. See §7.23. |
| **M15** | The feels | Swing, jazz comping, ska/reggae offbeat, latin. Placement as style, not error. |
| **M16** | Form ladder v2 | Phrase length as a trained variable, after the 4-bar finding. |
| **M17** | Unified adaptive difficulty | One progression model across all drills, replacing four ad-hoc rules. |
| **M18** | Longitudinal model | Within-session vs between-session effects, separated properly. |
| **M19** | Musical depth | Enough variety that a 30-minute session stays worth doing. |
| **M20** | Drum mode | Pads and keys become the kit; the click becomes the band. |
| **M21** | Guitar input | Audio onset detection. Needs an interface. |
| **M22** | Computer-keyboard input | For anyone who doesn't own a MIDI controller. |
| **T1** | **Test infrastructure — the take factory** | A different axis from the M-sequence: what the project can verify about itself. Synthetic takes, a degenerate corpus, a macOS-only `TrainerKitTests` target, and a seam under the drill runners. Ordered **before M13's storage step**. See §7.22. |
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

**82.4% of every matched note this project has ever recorded is a beat apart from the last one.**
So 24.07, 17.37, 22.00, "his ~20 ms spread", the trend line, `review feel`, both experiments and
the ceiling are all, to within a rounding error, *quarter-note placement in free playing*. The
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
| 5 | Drills gain a feel, both surfaces |
| 6 | Offbeat drill — ska and reggae |

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

**No take on record now qualifies**, which is the correct answer and consistent with step 3b:
82.4% of every matched note sits a beat from the last. The readout becomes answerable when a
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

### What this cannot verify

The clock bridge is untouched, so `selftest` remains the arbiter of the maths. But the ladder
changes what the *backing* plays, and backings have no tests beyond pattern structure — whether
a sixteenth-note groove is playable-along-to at all is a live-run question (R5.6). The first rung
above eighths should not be promoted by the planner until one session has been played on it.

Step 3b is measured from free playing only. It cannot say what a *prescribed* rung does, and the
tempo half of the axis remains unmeasured — one tempo is well sampled, one evening covers 110,
and one take covers 120.

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
