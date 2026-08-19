# Musical Trainer — command reference

Everything the app does, plus calibration, diagnostics and every review. Both front ends drive
the same engine (`TrainerKit`), so they can never measure differently.

```sh
swift build -c release
./.build/release/TimingSpike <command>
```

The milestone tag on a command says which entry in [the journal](JOURNAL.md) introduced it.

---

## Commands

| Command | What it does |
|---|---|
| `selftest` | Verifies the analysis maths against synthetic data of known ground truth. No hardware. |
| `midimon [seconds]` | Diagnoses MIDI delivery — opens the device on both CoreMIDI APIs and reports what each receives. Default 20 s. Pass a length over a minute and it prints a five-second heartbeat — packets since the last beat, running totals, and `— silent —` when none arrived — so a session-long watch says *when* the keyboard stopped sending rather than only whether it did. Safe to pipe into a file. |
| `validate` | **M0.** Two-path bridge validation with the four pass criteria. |
| `calibrate` | **M1.** Full calibration: loopback + two-path. Becomes the reference device. |
| `calibrate quick` | **M1.** Loopback only (~15 s), derives its constant from the reference. |
| `calibrate reset` | Deletes all stored calibration. |
| `groove [bpm]` | **M3.** Plays a synthesized groove: count-in, a two-section arrangement with fills, the dropout ladder, and a slam back. Default 100 BPM. |
| `jam [bpm] [bars] [tag] [rung]` | **M4.** Records a take against the groove, applies calibration, analyzes your timing, and saves the session. Default 100 BPM, 32 bars. **M14:** add a rung — `quarters`, `eighths`, `tripletEighths`, `sixteenths` — to be asked for that subdivision and scored against it, over a groove whose hi-hat marks it. Omit it and you play free, as every take before M14 did. **M15:** add a swing ratio (1–4) after the rung and the offbeat is expected late, with the band swinging too. **M19:** `--style <name>` plays over a generated backing instead of the fixed one — `driving`, `pocket`, `syncopated`, `half-time` — and `--seed <hex>` rebuilds an exact piece, which the take prints and stores so you can ask for it again. A style nobody has played over yet needs `--probe` too. |
| `form [bpm] [bars] [phraseBars] [level]` | Phrase-mark drill: hit a pad at each phrase top, no counting. Levels 0–3 progressively remove the landmarks. Default 100, 64, 8, 0. |
| `tempo [bpm ...]` | **M8.** Produce a tempo unaccompanied and be told what you actually played, round after round. Pass several tempos to rotate the target. |
| `memory [bpm] [waitBars] [rounds]` | **M11.** Recall drill: hear a tempo, stop playing through the wait, then reproduce it. Half the waits are silent and half are filled with unrelated percussion — the gap between them says whether the period is stored or just being held. If you play through one condition's waits more than the other's, the comparison is withheld rather than reported: the two are no longer scored on the same task. Default 100, 4, 8. |
| `session [minutes]` | **M9.** Run a whole planned session end to end — cold probe, warm-up, benchmark jam, drills chosen from your recent data, then playing. Default 30. **M14** adds one interval-ladder take per session, at a tempo that rotates between sittings and the finest subdivision that tempo can still score honestly; everything else stays locked at 100 BPM. |
| `session plan [minutes]` | **M9.** Print what it would do, and why, without running it. |
| `dropout [bpm] [pacedBars] [silentBars] [cycles] [rung]` | Continuation drill: a steady note value straight through the silences. The only drill that separates clock from motor noise. Default 100, 4, 4, 6, quarters. **M14:** a rung asks for that note value and scores against it, instead of the analysis inferring it from what you played. |
| `offbeat [bpm] [bars] [level]` | **M15.** Ska and reggae: play on every offbeat while the downbeat disappears underneath you. Levels 0–3 remove the kick, then the backbeat, then everything on a beat. Reports how much of your playing stayed off the beat and — separately — how tightly you placed it, because drifting onto the beat is a different failure from being loose. Default 70, 32, 0 — **the tempo matters more here than in any other drill**, and 100 inverted the feel where 69 held it (§7.38). Ask for a faster one when you want it. |
| `review [n]` / `review list` | Re-analyze a take (with 95% confidence intervals), or list all. **M15:** when enough notes land off the division, it also reports how you divide it — the swing ratio, and how tightly you place the swung note against how tightly you place the beat. An offbeat take instead gets its own readout back — where the notes went, and whether the feel slipped — recomputed from the raw taps like everything else. |
| `review compare [i j]` | Two takes side by side; bootstraps each difference and labels it "real change" or "within noise". Defaults to the last two. |
| `review tags` | Pooled summary of every tagged condition, and what each pool blends — a tag that mixes tempos, backings, styles, subdivisions, feels or offbeat levels says so, and says which number that ruins. |
| `review conditions <a> <b>` | Pooled comparison of two conditions — the experiment readout. |
| `review feel` | Does your sense of a good take match the measurement? |
| `review form` | Form-drill history — progress up the landmark ladder. A level marked `*` was a **probe**: a deliberate look at a rung you had not earned, which the ladder ignores. |
| `review dropout` | Continuation-drill history: the clock/motor split over time. |
| `review tempo` | Tempo-calibration history. |
| `review trend` | Is anything actually improving? Fits each metric with a confidence interval, one line per task — takes that differ in tempo, subdivision, feel, backing, silence length, difficulty level or phrase length are never fitted together, because a line across the change measures the change. |
| `review content` | **M12.** Does what you play change how you time it? Correlates musical content against timing spread within each take. |
| `review cold` | **M10.** Is it warming up, or getting better? Separates improvement inside a sitting from improvement in the cold take across sittings. |
| `review experiment` | **M13.** What the A/B experiments have collected. Arms are assigned before you play and balanced against what has already run; nothing is compared until every arm reaches the number of takes declared up front. Three are queued: two where the arms differ in what you are *told*, and **M14's** `slow-vs-fast` where they differ in tempo. |
| `render [bpm] [bars]` | Add `--style <name>` to render one generated piece instead of the whole set, and `--seed <hex>` to pin it — or paste a take's own name, `--style driving@06965a16872036af`, to hear exactly what that take was played over. **M19** adds `bass-demo`, every style at every intensity, a seeded piece per style, and `kit-<voice>` for each of the thirteen kit voices alone — so a groove, an intensity arc or a single sound can be judged by ear. Warns on any clipped sample. **M14.** Renders every ladder backing — quarters, eighths, triplet eighths, sixteenths — plus the jam backing to WAV files in `temp/renders`, so a groove can be judged by ear without a live run. **M15** adds swung eighths and sixteenths. Flags anything above its tempo ceiling, which a swing lowers. Default 100, 8. |
| `review interval` | **M14.** Does the gap between notes change how you play? Two readouts. Across takes, buckets them by the interval each was asked for and refuses to fit until tempo has actually been varied. Then, on the notes themselves, bins every note by how far it sat from the one before it and reports whether your spread is a fixed number of milliseconds or a fixed fraction of the gap — which decides what may be compared with what. |
| `show` | Prints stored calibration and the constant for each device. |

---

## Recording a take

```sh
./.build/release/TimingSpike jam 100 32            # 100 BPM, 32 bars (~77 s)
./.build/release/TimingSpike jam 100 64 relaxed    # tagged with the state you played in
```

Tag takes to compare conditions, and rate each one 1–5 when prompted — you are asked *before*
the numbers appear, so the rating stays honest:

```sh
./.build/release/TimingSpike review tags                   # pooled per condition
./.build/release/TimingSpike review conditions relaxed focused
./.build/release/TimingSpike review feel                   # is your instinct calibrated?
```

## Form drill

Trains knowing *where you are* in the music — a different skill from beat placement.

```sh
./.build/release/TimingSpike form 100 64 8 0    # 8 phrases of 8 bars, fill at every turn
```

Hit **any pad** once per phrase, on the **downbeat where the groove settles back in after the
fill** — not during the fill. The fill is the warning; the downbeat right after it is the
target. Play whatever you like on the keys in between; no counting.

Each mark is scored on **two separate skills, which come apart** — knowing which bar the phrase
turns on (*on form*), and landing on a bar line at all (*clean*). A take can be strong on either
and weak on the other, and the history holds both: one take was 36% on form and 71% clean, another
100% and 32%.

So there are two ladders, and each is promoted on its own skill:

| Ladder | What it changes | What earns the next rung |
|---|---|---|
| **Levels 0–3** | how much the music tells you *when* to land | landing cleanly |
| **Phrase span** 4 → 8 → 16 → 32 bars | how much music you hold your place across | knowing the bar |

| | |
|---|---|
| `0` | fill before the turn + crash **on** the downbeat — the crash confirms the arrival |
| `1` | fill only; nothing confirms it, so you have to commit |
| `2` | no fills — your own clock |
| `3` | silence across the boundary — the turn happens with no band at all |

**Only one ladder moves per session**, so a take differs from the last one in one way and the
result says which change did it.

`review form` shows the history with both columns and a **felt** column — the phrase length you
actually marked, whether or not it is the one that was asked for. Where those two disagree, every
other number in the row is scored against a phrase you were not holding, which is worth knowing
before reading them.

To try a level before you have earned it, add `--probe` from the command line:

```sh
./.build/release/TimingSpike form 100 64 8 3 --probe
```

The take is stored apart and marked `*` in your history, and nothing that decides what to
practise next reads it — so a look at the top of the ladder cannot move the ladder. It works on
`jam` and `offbeat` too, for a subdivision or an offbeat level you have not reached.

## Continuation drill — clock or hands?

```sh
./.build/release/TimingSpike dropout 100 4 4 6            # 4 bars with the band, 4 alone, ×6
./.build/release/TimingSpike dropout 100 4 4 6 eighths    # two notes per beat instead
```

Play **one note per beat, steadily, the whole way through** — especially when the band drops
out. Pass a rung and it asks for that note value instead, and scores against it; without one it
is quarter notes, as it always has been. The silences are the measurement, and they're the only thing in the app that can separate
two faults which feel identical from the inside:

- **Clock** — the pulse in your head is unstable
- **Motor** — the pulse is fine, your hands scatter around it

They need completely different training, and no amount of playing by feel can tell them apart.
The report also gives drift while unaccompanied and how far off you were when the band came
back, and suggests a longer or shorter silence for next time. `review dropout` shows the split
over time.


---

A 2-bar count-in, then play along — eyes closed, nothing on screen. When it finishes it prints
your timing (bias, spread, drift, whether you are chasing the click) and saves the take to
`~/Library/Application Support/MusicalTrainer/sessions/`.

Calibrate first for a trustworthy bias number. Uncalibrated takes still measure spread and drift
correctly, but flag the bias as unreliable.
