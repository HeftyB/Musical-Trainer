# Musical Trainer

A macOS app for training an autonomous internal pulse. See [PLAN.md](PLAN.md) for the
design, the metrics, and the roadmap.

## M0 — timing spike

Validates the `mach_absolute_time` ↔ audio-sample-index bridge that every measurement in
this project depends on. Design and pass criteria: [PLAN.md §4.2](PLAN.md).

```sh
swift build -c release

# Verify the analysis maths against synthetic data of known ground truth.
# No hardware, no microphone, runs in a couple of seconds.
./.build/release/TimingSpike selftest

# Run the live rig.
./.build/release/TimingSpike
```

**Run `selftest` first.** If it passes and the live run fails, the fault is in the
hardware or the clock bridge rather than the analysis — which is the entire point of
having it.

### Before the live run

- **Microphone access.** Grant it to your terminal under
  System Settings → Privacy & Security → Microphone. Command-line tools inherit the
  terminal's permission, so without this the tool exits with no usable input.
- **Internal speakers, not headphones.** Phase 2 needs the microphone to hear both the
  chirp and the key strike.
- **No Bluetooth.** The tool refuses to run on it; the latency varies run to run and
  cannot be calibrated away.
- **Microphone roughly equidistant** from the speakers and the keyboard, so the two
  acoustic path lengths cancel.

### What it does

**Phase 1** (~12 s) plays 24 chirps and finds them in the recording, giving round-trip
latency and confirming the input and output devices are clock-locked.

**Phase 2** (~105 s) plays a chirp once per second while you strike one key roughly
halfway between chirps. Your accuracy is irrelevant — the two measurement paths see the
same physical event either way, and the synthetic test proves the result holds even with
20 ms of timing jitter. Striking on the offbeat only keeps the strike acoustically clear
of the chirp.

Then four checks: residual SD, dependence on audio-buffer phase, drift over time, and the
resulting calibration constant.
