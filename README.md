# Musical Trainer

A macOS app that trains an autonomous internal pulse — the ability to hold time without
counting, without a click, and without leaning on whatever the band is doing.

It is built for one player and makes no attempt to be general. Everything is eyes-off: nothing
worth reading appears on screen while you are playing, and you rate how a take *felt* before you
are shown a single number.

**[PLAN.md](PLAN.md)** has the design, the metrics and the roadmap.
**[docs/JOURNAL.md](docs/JOURNAL.md)** has the entry for every milestone — what was built, what
each session measured, and what each review found.

```sh
./build-app.sh
open "Musical Trainer.app"
```

---

## What it measures

Timing error is split into quantities that come apart, because they need different training:

| | |
|---|---|
| **Bias** | how far ahead or behind the beat you sit. A constant offset, not a fault. |
| **Spread** | how consistently you land. **This is the skill metric.** |
| **Drift** | whether the tempo walks away from you over a phrase. |
| **Clock vs motor** | whether the pulse in your head is unstable, or your hands scatter around a good one. |

That last split is the one no amount of playing by feel can give you, and only the continuation
drill produces it. Everything recomputes from the raw taps, so a take recorded a year ago
re-analyses under today's maths.

## The modes

Hit **Session** for a whole planned evening — 20, 30 or 45 minutes. The app picks the drills
from what your recent takes measured, tells you why it picked each one, and runs them in order.
Nothing measured appears until the debrief at the end.

Say how you are coming into it — *usual, tired, amped, distracted, stiff* — and every take of the
sitting is filed under it. You are asked **before** you play, never after: marked afterwards it
would be a way of excusing a bad evening, and the point is to compare tired evenings against
ordinary ones rather than to discount them.

Or pick a mode and run it on its own:

| Mode | What it asks of you |
|---|---|
| **Jam** | Play along and let it measure how you place the beat. |
| **Offbeat** | Ska and reggae — hold the chop between the beats while the downbeat disappears underneath you. |
| **Form** | Mark the top of each phrase without counting. Knowing *where you are* is a different skill from beat placement. |
| **Alone** | Hold a steady note value straight through the silences. The only drill that separates clock from hands. |
| **Tempo** | Produce a tempo unaccompanied, and find out what you actually played. |
| **Recall** | Hear a tempo, let go of it, then get it back — was it stored, or only running? |
| **Play** | Just the backing. Nothing measured. |

Each mode says exactly what it expects before you begin. To abandon a take mid-way — wrong
tempo, keyboard not responding — press **esc** or **⌘.**, or click *Stop and discard*. The
recording is thrown away rather than analysed.

Plug the keyboard in before or after launch; sources are re-scanned before every take.

## The ladders

No drill has a difficulty slider. Each has a ladder, and a rung is earned on the skill that rung
is about:

- **Subdivision** — quarters → eighths → triplet eighths → sixteenths, on Jam, Alone and Tempo.
  The picker offers only the rungs your chosen tempo can still measure honestly.
- **Swing** — a binary subdivision can be swung, from a shuffle to a full 2:1, with the band
  swinging with you.
- **Offbeat levels 0–3** — the kick goes, then the backbeat, then everything on a beat.
- **Form levels 0–3** — how much the music tells you when to land — and **phrase span**
  4 → 8 → 16 → 32 bars — how much music you hold your place across. Two ladders, promoted on two
  different skills, and **only one moves per session** so a take differs from the last in one way.

To look at a rung you have not earned, add `--probe`. The take is stored apart, marked `*` in
your history, and nothing that decides what to practise next reads it — so a look at the top of
the ladder cannot move the ladder.

## The band

Jam and Play can pick a **band**: a generated backing built from a style and a seed, so no two
evenings play the same piece. The seed is stored with the take, so a piece you liked can be
asked for again.

A style is **steps and a kit**, not steps alone. Four styles ship, and each carries its own
tuning of the drums rather than sharing one general-purpose set — because a genre name that only
describes the pattern is a claim the sound does not keep:

| Style | The feel | The kit |
|---|---|---|
| `driving` | Straight eighths, hat-led | Close-miked and forward. Snaps rather than rings, tight hats, the driest of the four |
| `pocket` | Sits back, clap on the backbeat, walking bass | Warm, fat and roomy. Body rather than crack |
| `syncopated` | Off-beat kick, ghost snares, sixteenths on the hat | High, tight and dry, so the ghost notes read |
| `half-time` | One snare on beat three, and a great deal of air | Deep, long and wet. Each hit fills the space it is given |

The kit follows the style; there is no separate picker. Every drum is synthesized — no samples —
with velocity layers, round-robin variation so no two hits are identical, and a room. Every take
records **which kit it heard**, and takes played over different kits are never pooled into one
trend, because changing the kit changes the task.

**Whether a style sounds like its own name is decided by ear, not by a test.** `render` writes
WAVs you can listen to, and a style nobody has approved is kept out of the rotation until
somebody has. That is a real gate, not a formality: three of the original four styles were
renamed after a listening pass, because the name promised what the kit could not deliver.

**All four are currently unapproved** — the kit changed under them when the cymbals were rebuilt,
which withdraws every standing verdict. Until they are heard again, a jam over a generated band
needs `--probe`, and the planner will not schedule one.

## Calibration

Do this once before your first take.

The quantity that matters is `L_midi + L_out` — MIDI transport latency plus output latency —
because asynchrony reduces to `(midiHostTime − clickEmitHostTime) − (L_midi + L_out)`. The
two-path procedure measures that sum directly, so the two terms never need separating.

A full run takes ~2 minutes of playing, which is too much to repeat for every pair of
headphones. Since `L_midi` belongs to the keyboard rather than the output device, one full run
establishes a reference and any other device needs only a 15-second loopback:

```
C(dev) = C(ref) + (RT(dev) − RT(ref)) + air(ref) − air(dev)
```

```sh
# Once, on internal speakers — the microphone hears both the chirp and the key strike.
./.build/release/TimingSpike calibrate

# Then for headphones: rest one earcup against the built-in microphone.
./.build/release/TimingSpike calibrate quick

./.build/release/TimingSpike show
```

Stored at `~/Library/Application Support/MusicalTrainer/calibration.json`. Devices are keyed by
name **and data source**, because on a MacBook the internal speakers and the headphone jack are
the same CoreAudio device with very different latency — so switching the physical output selects
the right constant automatically.

**Absolute accuracy matters less than it looks.** A constant offset shifts measured *bias* and
leaves *spread* untouched, and spread is the skill metric. An uncalibrated take still measures
spread and drift correctly; it flags the bias as unreliable.

### Before any live run

- **Microphone access** — grant it to your terminal under System Settings → Privacy & Security →
  Microphone. Command-line tools inherit the terminal's permission.
- **No Bluetooth.** The tool refuses to run on it; latency varies run to run and cannot be
  calibrated away.
- **Microphone roughly equidistant** from the sound source and the keyboard during two-path runs,
  so the acoustic path lengths cancel.

## The command line

The CLI does everything the app does, plus calibration, diagnostics and every review. Both
front ends drive the same engine (`TrainerKit`), so they can never measure differently.

```sh
swift build -c release
./.build/release/TimingSpike selftest
```

**[docs/cli.md](docs/cli.md) is the full command reference** — every drill, every review, and
what each one is for.

**Run `selftest` first after any change.** If it passes and a live run fails, the fault is
hardware or the clock bridge rather than the analysis, which is the entire point of having it.
It has already caught six real defects that would otherwise have surfaced as mysterious
live-run failures.

## Contributing

[STANDARDS.md](STANDARDS.md) holds the engineering rules — architecture, real-time safety,
measurement integrity, security, and the commit format. [LESSONS.md](LESSONS.md) is the
catalogue of ways this project has gone wrong, each with its instance and its guard; **read it
before a review** and look for those shapes rather than for code smells.

`./scripts/check.sh` is the single gate and must pass before every commit. Run
`./scripts/install-hooks.sh` once so it runs automatically.

## Layout

| | |
|---|---|
| `Sources/TimingCore` | Pure timing analysis — grid, matching, Wing–Kristofferson, drift, bootstrap CIs, form, feel and swing, the offbeat drill, the interval ladder, task identity, experiments, the session planner. No audio or MIDI. |
| `Sources/GrooveCore` | Pure pattern generation — patterns, sequencer, arrangements, the dropout ladder, form and offbeat backings, kit specs, styles and the seeded arranger. Depends on nothing, not even `TimingCore`. |
| `Sources/TrainerKit` | Audio, MIDI, synthesis (drums, cymbals, bass, organ, room), calibration, storage, sessions and the drill runners. Shared by both front ends. |
| `Sources/MusicalTrainerApp` | The SwiftUI app. |
| `Sources/TimingSpike` | The console tool. |
| `Tests/` | 926 cases against synthetic ground truth. `Tests/TestSupport` holds the shared generators; storage tests are macOS-only. |

```sh
swift test               # pure modules, plus TrainerKit storage on macOS
swift build -c release   # the console tool
```

Only the two pure modules run in CI — they build on Linux, which is the strictest available check
of the purity rule. `TrainerKit`, the app and the CLI are macOS-only and are built by the
pre-commit hook rather than by the pipeline.
