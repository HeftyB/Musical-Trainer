# Musical Trainer

A macOS app for training an autonomous internal pulse. See [PLAN.md](PLAN.md) for the
design, the metrics, and the roadmap.

## Layout

- `Sources/TimingCore` — pure timing analysis (grid, matching, Wing–Kristofferson, drift,
  autocorrelation). No audio/MIDI dependencies; runs under `swift test`.
- `Sources/GrooveCore` — pure groove generation (patterns, sequencer, dropout ladder).
- `Sources/TimingSpike` — the console tool below: capture, calibration, the M0 rig,
  synthesized drum kit, and groove playback.
- `Tests/` — 37 cases against synthetic ground truth (25 TimingCore + 12 GrooveCore).

```sh
swift test               # TimingCore unit tests
swift build -c release   # the console tool
./.build/release/TimingSpike <command>
```

| Command | What it does |
|---|---|
| `selftest` | Verifies the analysis maths against synthetic data of known ground truth. No hardware. |
| `midimon` | Diagnoses MIDI delivery — opens the device on both CoreMIDI APIs and reports what each receives. |
| `validate` | **M0.** Two-path bridge validation with the four pass criteria. |
| `calibrate` | **M1.** Full calibration: loopback + two-path. Becomes the reference device. |
| `calibrate quick` | **M1.** Loopback only (~15 s), derives its constant from the reference. |
| `calibrate reset` | Deletes all stored calibration. |
| `groove [bpm]` | **M3.** Plays a synthesized groove: count-in, a two-section arrangement with fills, the dropout ladder, and a slam back. Default 100 BPM. |
| `jam [bpm] [bars]` | **M4.** Records a take against the groove, applies calibration, analyzes your timing, and saves the session. Default 100 BPM, 32 bars. |
| `review [n]` / `review list` | Re-analyze a take (with 95% confidence intervals), or list all. |
| `review compare [i j]` | Two takes side by side; bootstraps each difference and labels it "real change" or "within noise". Defaults to the last two. |
| `review tags` | Pooled summary of every tagged condition. |
| `review conditions <a> <b>` | Pooled comparison of two conditions — the experiment readout. |
| `review feel` | Does your sense of a good take match the measurement? |
| `show` | Prints stored calibration and the constant for each device. |

**Run `selftest` first after any change.** If it passes and a live run fails, the fault is
hardware or the clock bridge rather than the analysis — which is the entire point of having
it. It has already caught four real defects that would otherwise have surfaced as
mysterious live-run failures.

### Before any live run

- **Microphone access.** Grant it to your terminal under
  System Settings → Privacy & Security → Microphone. Command-line tools inherit the
  terminal's permission.
- **No Bluetooth.** The tool refuses to run on it; latency varies run to run and cannot be
  calibrated away.
- **Microphone roughly equidistant** from the sound source and the keyboard during
  two-path runs, so the acoustic path lengths cancel.

## Calibration

The quantity that matters is `L_midi + L_out` — MIDI transport latency plus output
latency — because asynchrony reduces to
`(midiHostTime − clickEmitHostTime) − (L_midi + L_out)`. The two-path procedure measures
that sum directly, so the two terms never need separating.

A full calibration takes ~2 minutes of playing, which is too much to repeat for every pair
of headphones. Since `L_midi` belongs to the keyboard rather than the output device, one
full run establishes a reference and any other device needs only a 15-second loopback:

```
C(dev) = C(ref) + (RT(dev) − RT(ref)) + air(ref) − air(dev)
```

So:

```sh
# Once, on internal speakers — the microphone hears both the chirp and the key strike.
./.build/release/TimingSpike calibrate

# Then for headphones: rest one earcup against the built-in microphone.
./.build/release/TimingSpike calibrate quick

./.build/release/TimingSpike show
```

Stored at `~/Library/Application Support/MusicalTrainer/calibration.json`.

A directly measured constant is always preferred over a derived one — it carries no
air-path assumption. Run the full `calibrate` on a device if you want its constant exact.

Devices are keyed by name **and data source**, because on a MacBook the internal speakers
and the headphone jack are the same CoreAudio device ("Built-in Output") with very
different latency. So "Built-in Output — Internal Speakers" and "Built-in Output —
Headphones" calibrate independently, and switching the physical output automatically
selects the right constant.

### On accuracy

Absolute accuracy matters less than it looks. A constant offset shifts measured *bias* but
leaves *variance* untouched, and variance is the skill metric this project is built around.

## Recording a take

```sh
# Calibrate once (see above), then:
./.build/release/TimingSpike jam 100 32            # 100 BPM, 32 bars (~77 s)
./.build/release/TimingSpike jam 100 64 relaxed    # tagged with the state you played in
```

Tag takes to compare conditions, and rate each one 1–5 when prompted (you're asked *before*
the numbers appear, so the rating stays honest):

```sh
./.build/release/TimingSpike review tags                   # pooled per condition
./.build/release/TimingSpike review conditions relaxed focused
./.build/release/TimingSpike review feel                   # is your instinct calibrated?
```

A 2-bar count-in, then play along to the groove — eyes closed, nothing on screen. When it
finishes it prints your timing (rush/drag bias, spread, drift, whether you're chasing the
click) and saves the session to
`~/Library/Application Support/MusicalTrainer/sessions/`. Run it again for another take;
the M5 review will chart them over time.

Calibrate first for a trustworthy bias number — uncalibrated takes still measure spread and
drift correctly but flag the bias as unreliable.
