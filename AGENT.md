# Musical Trainer — agent guide

macOS app that trains an autonomous internal pulse. One user: Andrew, 25+ years playing,
theory-strong, timing is the weak axis.

Five documents, five jobs — putting content in the wrong one is a defect:

- **[PLAN.md](PLAN.md)** — design, rationale, findings, roadmap. **The reasoning lives here.**
- **[STANDARDS.md](STANDARDS.md)** — binding engineering rules and the procedures that enforce
  them. Read it before writing code.
- **[LESSONS.md](LESSONS.md)** — the twenty-two failure *shapes* this project has produced, each with
  its instance and its guard. **Read it before any review**, and look for these shapes rather than
  for code smells. Every one of them shipped, or nearly did, with a green gate. Code comments cite
  it by number; `check.sh` fails if a citation names a shape that does not exist.
- **AGENT.md** (this file) — the operating manual.
- **[README.md](README.md)** — what the app is and how to use it.

## Where the project is

**M0–M16 and M19 are built.** M17, M18 and M20–M22 are not started; PLAN.md §7's milestone table
carries the status of each and is the one to trust. M14 has six ladder takes across 80–140 BPM,
M15 has three swung takes and — as of 13 August — twelve offbeat ones. **The skank at 70 BPM /
level 0 now has five takes and is the first offbeat series that can be fitted**: 100% off the beat
in every one, and the drill says *"Ready for level 1"* (§7.53). **M16 has finally been played under
its finished ladders**, twice on 13 August, and what those two takes settled is in §7.53.

**The pre-M16.5 review is closed — eight findings, six branches** (§7.46–§7.51). Nothing in it is
outstanding. What it changed, and what each one is worth remembering for:

| | Found | Closed |
|---|---|---|
| The app handed a **swung** jam the *straight* instructions | §7.46 | Both surfaces build a drill's text from the config the engine will run |
| Two `check.sh` rules proved nothing — one passed a **valid, resolving** dependency | §7.47 | And a rule that cannot run now fails instead of going green |
| `review trend` fitted `onFormRate` only, so M16's own axis had no trend line | §7.48 | Both axes fitted, on both surfaces |
| The history chart pooled what the cards refuse to pool | §7.48 | One line per comparable group, and only groups big enough to fit |
| The Alone chart plotted a different quantity from its own card | §7.49 | **Found by a screenshot, not by the suite** |
| Two lists of legal phrase spans, and a ladder you could be stranded off | §7.50 | One list; `nextSpan` returns the first rung wider than where you are |
| The capture dropped notes in silence, four notes a beat from full | §7.51 | Counted and reported; the buffer is derived from the longest take |
| `onNoteEvent` crossed threads unsynchronised | §7.51 | Behind the same lock as the field beside it |

**Two things about that review are worth carrying forward.** A green gate bounded what had been
*checked*, not what was true — and until §7.47 it also covered rules that checked nothing. And
§7.49 is the one nobody predicted: two defects a **screenshot** found after §7.48 had already
shipped, neither reachable by any test this project can write.

**The review has now been played** — the 13 August setlist (§7.53), ten takes, which is what closed
the gap this paragraph used to describe. Two of the three things it was waiting on are answered:
M16 ran under its finished ladders, and a swung take was recorded from the app, verifying §7.46's
fix on the surface where the defect lived. **The incident readout still draws nothing**, and cannot
be made to: it needs an occurrence.

**A ninth finding came out of planning M16.5** (§7.52), and it is the one worth reading. The
planner built its jam input with `map` over every stored jam, and **the offbeat drill is stored as a
jam** — so a skank's spread, half again as wide as free playing, went into the estimate that decides
which rungs the interval ladder may schedule and which the app's subdivision picker offers at all.
Five of the six most recent takes were skanks; triplet eighths had already vanished from the picker
at 100 BPM with nothing saying why.

**The same confound had been found and fixed twice before, both times in a readout** (§7.24 step 8,
§7.48). Neither touched what *acts* on the corpus. That asymmetry is `LESSONS.md` shape 22, and it
is the most transferable thing this review produced: a wrong readout shows a wrong number, a wrong
decision quietly changes what you are told to practise. `SessionStore.loadAllPlayAlong()` is the one
place the distinction now lives.

**A fourth codebase review ran on 14 August and left a queue** (§7.57). Two defects are closed — a
data race on the capture's dedup window, and thirty-eight lines of `gappyLag1`'s argument bound to
the wrong declaration — and six items are recorded rather than acted on. **The gate passed before it
and passes after it**, so read §7.57's table before assuming green means reviewed. The two worth
knowing before touching anything: task identity (`GroupKey` and its siblings) is pure logic sitting
in `TrainerKit` where CI cannot reach it, and CI compiles **none** of the macOS code — the
pre-commit hook is the only thing that ever builds `TrainerKit`, the app or `TimingSpike`.

**The 13 August setlist is the first data since the review** (§7.53), and it carries three things
worth knowing before touching a drill. **Holding a position the band never plays costs this player
nothing in precision** — offbeat spread ~23 ms against ~25 for free jams — which is the number
M16.5's whole premise has to beat. **The chop sits 35 ms ahead in every take**, which may be the feel
he wants and is recorded as an open question rather than a fault. And **r₁ ran +0.44 to +0.72 across
three different tasks in one afternoon**, against a historical 0.13–0.50 — an observation, not a
finding, with fatigue as good an explanation as any, and the way to settle it written down.

**M16.5 is blocked, and on an ear rather than on code** (§7.56). The organ built for it *"sounds
like an organ"* and is *"not the right organ sound for a reggae vibe"*, and the player heard neither
candidate figure as a bubble. He named the cause: **the same tone handicap §7.33 records**, where
four styles sounded like "beat #3 rather than oh, a Motown beat". That handicap has now stopped a
*measurement* decision instead of a naming one, which moves **M26 upstream of a drill** — it is no
longer a someday item.

**Do not build organ voices from descriptions.** The player asked for several — the Wailers' sound,
Kash'd Out's — and is assembling references. `AGENT.md`'s own rules cover this: an agent cannot
listen, and a style is never named after a genre. §7.30's capture-to-measure path is what makes it
cheap once the references exist. What is missing structurally is a named `Registration` on
`OrganSynth`, chosen per arrangement; it is described in §7.56 and deliberately unbuilt, because a
seam with one implementation behind it is a guess about the second.

**Two more things came out of that verdict**, both real design gaps: **articulation belongs to the
figure** — the stab is one length for every bubble, so every bubble is staccato by construction, and
a legato triplet wants a note twice as long — and **the root-and-fifth voicing may be why the
triplet failed**, since a bubble without a third may not read as an organ part at all.

**M16.5 step 0 is built and its musical question is answered "both"** (§7.55). `BubbleFeel` carries
a triplet bubble and a sixteenth one; the player heard both as plausible and said it would depend on
the piece, so **both ship as a player-selected axis** rather than one being chosen — which is what
§7.13's "generalise one phase to a set" was for. They differ in *closest approach* to a beat — 1/3 of
a beat against 1/4, where the straight chop is 1/2 — so each is its own trend group with its own
tempo default, and the data will settle what the listening could not.

**That listening test was contaminated, and by this repository.** The hand-over stated the
conclusion — that the sixteenth bubble's first note is the chop — before the player heard the files,
and he then reported hearing it. **Do not put the answer in the question.** A listening verdict is
taken the way a take's rating is: before the numbers, before the explanation. `render` writes the
five skank-family auditions; a blind re-listen with an organ voice is what M16.5 still owes.

**The procedure that came out of it: `render → look → decide`**, beside the `render → listen →
decide` this project already had for audio. Hand over a build, ask for a screenshot of the surface
that changed, and read it — an agent cannot see a screen any more than it can hear the kit, and
`MusicalTrainerApp` has no test target (R5.6). It has paid for itself once already.

M14 (§7.23) is the interval ladder — subdivision and tempo built as one axis, because both move
the inter-onset interval. M15 (§7.24) is the feels: where within the beat a note is *expected*,
plus the offbeat drill. PLAN.md §7 has the milestone table with an "as built" section for each;
§7.13 is the roadmap through M22, plus M23 (jazz timing, deferred behind the instrument
milestones for the reason given there) and M24 (voice — onsets from the microphone, no
instrument, and the only milestone that can ask whether the "clock" this project measures is
the timekeeper or partly the hands) and M25 (harmony — its own milestone because a key and a
progression are a different problem from rhythm, with the framework for it already in
`Hit.note`).

**M19 is built.** Steps 0–8 are complete (§7.29, §7.33): the pattern
format, the bass, four approved styles, the seeded generator, the planner picking a band for the
closing jam, band pickers in the app, and `render --style` reproducing any take's music from the
name it is stored under.

**M19 is proven as of 8 August** (§7.34). A full 45-minute session ran end to end: the band the
plan announced reached both closing takes, both shared one seed, the locked slots kept `jamBacking`,
and the two closing takes landed in their own trend group. Nothing has yet been recorded from the
**app's** picker.

**That session also found three things.** A **voice hung** mid-take and the keyboard went silent
with it — the app creates its CoreMIDI client with a **nil notify block**, so a source disconnecting
mid-take is invisible, and nothing can recover a stuck voice because `release(note:)` is the only
path out of one. **Block 10 of that session is compromised and deliberately kept**, not excluded;
its 33.1 ms spread is not a fact about the player. And `AppModel.feelAdvice` explains a disabled
Feel picker by talking about triplets even when the rung is quarters.

**The hang recurred on 10 August** (§7.35), from the *start* of a swung take over `jamBacking`, with
a retry over `pocket` running clean immediately after — which is also the first take ever played
over that style. **The backing is not the variable**: a generated backing sits on both sides of the
outcome and a fixed one produced a hang, and no single configuration value is common to both
failures. Reading the audio path narrows it by elimination — voices are *stolen* rather than
exhausted, the event ring is drained every callback, the drums prove the callback was running, and
player and instrument are per-take — **so the events stopped reaching `enqueue` at all**, upstream
of the synthesis.

**Three things are fixed and the cause is still not established.** A stuck voice releases itself
after 8 s (`LiveInstrument.maxSustainSeconds`, §7.35), which makes a hang survivable rather than
take-ending and cannot move a measured number, because everything analysed comes from note onsets
and nothing reads a duration. The CoreMIDI **notify block** is installed where it was `nil` for the
life of the project, and `MIDISourceRegistry` **forgets a removed source** so a device returning
under the same unique ID reconnects instead of staying dead until relaunch — the two are one fix,
since being told the device left is worth nothing while the reconnect path refuses to run (§7.36).
`JamOutcome.midiIncidents` records what happened, with host times on the same clock as the notes.

**None of the instrumentation has ever fired, and none of it can be unit tested** (R5.6) — no test
can remove a device, so only the registry's rules are covered and the wiring is live-run-only.
**An empty incident list is not evidence the connection was fine**: "delivery stopped with no
notification" is still a live candidate and would look exactly like a clean take.

**A deliberately instrumented session on 11 August produced nothing** (§7.37) — no hang, and the
`midimon` log came back empty because piped stdout is block-buffered and `^C` does not flush. Both
halves are fixed: `setvbuf` line-buffers every CLI readout, and a watch over a minute prints a
five-second heartbeat with a `— silent —` marker, because the monitor only ever printed its first
twelve packets and so could never have shown *when* delivery stopped. The app could not show an
incident at all until now — R3.4, and both hangs happened in the app.

**The quarantine is dropped and there is no debug build flag** (§7.37). A take spoiled by an
incident is handled by hand, as §7.34 handled block 10. A mode switched on when trouble is expected
cannot catch trouble that is not: the hang fired twice, unpredictably, and a flag would have been
off both times.

Steps 0 and 1 changed no audio by design: the grid a free jam is scored on is a named constant
rather than the drum programming's resolution, and every arrangement now speaks **one grid of 24
steps to the beat** so a triplet section and a straight one can share a piece of music. Patterns
are still authored at whatever reads naturally and `Arrangement` lifts them.

The band now has a **bass** — `BackingVoice.bass`, pitch on the hit, `BassSynth` — and a
**style format**: layers that enter at an intensity, plus fills, `playerVoices` for M20 and
`density` for M21/M24. **Four styles are authored and all four are approved** (8 August, §7.33) — `driving`, `pocket`,
`syncopated`, `half-time` — and `StyleArranger` turns any of them into a piece from a seed.
**Nothing frozen carries any of it**: `jamBacking` is the music every take was measured against and
stays exactly as it is, and the cold probe, benchmark and experiment arms keep it for ever (R3.5).
The **closing jam** is the one planned slot that gets a band, rotating style between sittings and
holding one seed within one. Hear all of it with `render`.

**All four styles have now been played over**, two takes each — `driving`, `half-time`,
`pocket` and `syncopated`. §7.33 records that two of them were *approved* on listening alone,
which is the weaker basis and stays on the record; what it no longer means is that they are
unplayed.

**A style that clips is heard as bad playing, not as a bad gain.** `StyleHeadroomTests` mixes the
real buffers at 100 and 160 BPM — a mix goes hot because voices stack, and a style that clears
the rails at 100 can exceed them where sixteenths overlap.

**The kit is synthesised, ships no audio assets, and that is deliberate** — `DrumSynth` builds
all thirteen voices procedurally, which is why the app is small, needs nothing installed, and
renders byte-reproducibly from source alone. It is also why the first four styles were heard as
*"beat #3 rather than oh, a Motown beat"*.

**The styles are named for what they do, not for genres.** `driving`, `pocket`, `syncopated`,
`half-time`. They were `rock`, `motown`, `funk` and `half-time`, and three of the four were
claiming something the kit cannot deliver — a name is a promise, and this project does not let a
label imply a measurement nobody made. **Do not name a new style after a genre.** The ambition is
unchanged and it has two milestones behind it: **M26** makes the kit sound convincing, **M27**
works out how to say what a genre *is* so the claim has a falsifier. Neither is part of M19.

**Four rules an ear found that a step list cannot show:**

- **No style may have two timekeepers on the same steps.** A ride and a hat playing one rhythm
  reads as a bell over a hat rather than as either. A hat on the downbeats against a shaker on
  the offbeats is *interlocking* and fine — the rule is about doubling, and the first version of
  it wrongly forbade both.
- **No layer may run at one velocity.** Eight identical hi-hat hits a bar is a metronome by
  construction. Use `Pattern.line` and lean on the beat. Velocity only, never position.
- **One hi-hat, one state.** An open hat on a step the closed hat already plays is not a louder
  hat, it is two hats — a thing no drummer can do. Fixed — `BackingVoice.articulationGroups` lists
  the voices that are one instrument in two states, and `Style.pattern` keeps one per step as it
  merges. Author the figure naturally; the open hat supersedes the closed one.
- **A one-shot must not stop mid-decay.** Fixed — `DrumSynth.fadedOut`, and there is a test.

**Every one-shot now ends on a release fade**, so nothing steps to zero mid-decay. The fade is
50 ms — two cycles of E1, the lowest note the band can sound — clamped to a quarter of the buffer
so the 50 ms rimshot is not swallowed by it, and raised-cosine rather than linear so the start of
the fade is not itself a corner. **The number is derived from `BackingKit.bassNotes.lowerBound`
and a test fails if that widens without it.** `OneShotTailTests` asserts every drum voice and all
twenty-five bass notes end below −80 dBFS; reverting either `fadedOut` call fails it fourteen
ways. **Heard and confirmed on 7 August 2026** — the test proves the step is gone, only a listener
can say the click is. See §7.31 finding 1, including the discontinuity it puts in `jamBacking` on
that date and why the first take after it must not be read as an effect.

**Two rules, not one, and do not merge them.** `doubledTimekeepers` is about two voices keeping
the same *pulse* and deliberately ignores a voice with fewer than three hits a bar, so an occasional
ride hit is not mistaken for a second drummer — which is exactly why it could not see an open hat
landing on one step. `articulationGroups` is about one instrument in two states. Different
thresholds, different mistakes; merging them either re-forbids ordinary percussion or stops
catching what the first rule exists for.

**The §7.31 review is closed — no open kit defects.** All three findings are fixed, and each was
listened to and confirmed rather than merely asserted: the release fade on 7 August, the hat
articulation and the arc on 8 August.

**A render subject carries its own bar count.** A kit voice is four bars, a ladder backing is
whatever was asked for, and a seeded piece is `StyleArranger.barsForAFullArc()` — the length that
contains a whole intensity arc, derived from the arc table so a longer shape lengthens the audition
rather than being truncated by it. `render` rendered everything at the command's length, so a piece
generated at 32 bars was written at 8 and the arc had never been heard by anyone (§7.31 finding 3).
`Commands.renderSubjects(bars:)` is split out of `runRender` for the reason that defect survived a
milestone: a decision inside a function that writes files is a decision no suite can observe.

`render` writes `kit-<voice>` for every voice alone, which is how a sound gets *named* rather
than theorised about. Use it before guessing. **`kit-bass` is one of them now** — its absence is
what kept the loudest click in the kit out of §7.29 step 6b's table for a whole milestone.

## Audio, and how it gets accepted

Nothing here can be verified by a test, so the loop is: **render → listen → decide**.

**The app's surfaces have the same problem and the same loop: render → look → decide.**
`MusicalTrainerApp` has no test target, so nothing can assert on a rendered view. Ship a build, ask
for a screenshot of the screen that changed, and read it — §7.49 is two defects that came back that
way, one of them a chart and its own caption describing different quantities. An agent cannot see
the screen any more than it can hear the kit; both gaps close the same way.

```sh
./.build/release/TimingSpike render 100 8      # writes temp/renders/*.wav
```

It writes **51 files**: ten ladder and demo backings, the five skank-family auditions M16.5
turns on (§7.55), four styles × four intensities, one seeded
piece per style, thirteen `kit-<voice>` files, and `kit-bass` — which walks E1 to E3 in one file
rather than taking twenty-five, since the lowest note is the one that matters. Two guards run
automatically: `render` warns on any clipped sample,
and `StyleHeadroomTests` mixes real buffers at 100 and 160 BPM because a mix goes hot where voices
stack rather than where one is loud.

**`Style.auditioned` is the gate.** It is `false` for all four styles, `StyleLibrary.auditioned`
is what the planner may schedule, and it is empty. Nobody who writes a style can set it honestly —
whether a groove is worth thirty minutes is not a property of its step list. Approving one means
editing the flag *and* a test that asserts the library's state, so it lands as a decision with a
diff.

**Do not describe how something sounds.** An agent cannot listen. Render it, hand over the
filenames, and record the verdict that comes back — every real finding in this milestone arrived
that way.

## Resources for the audio work

| | |
|---|---|
| Roland TD-V6 | Many kits and sounds. MIDI out via the planned USB interface is the *measurement* path; its line out through the TS→USB adapter is audio |
| GarageBand | Virtual instruments, and full recording via microphones and inputs |
| External microphone | Owned, used for recording |
| A professional ear | The player's older brother is a working musician and producer — available for the questions that need one |

**Reference, not source.** Recording the TD-V6 or GarageBand and shipping the audio is a licence
question about somebody else's terms, and the app's whole shape depends on carrying no assets.
Capturing them to *measure* — spectra, envelopes, velocity behaviour — and tuning the synthesis
to match is a different thing entirely: a timbre is not copyrightable, and it turns an asset
problem into a measurement problem, which is what this project is good at. §7.30 has the argument.

`StyleArranger` turns a style into a piece from a **seed**, and `BackingIdentity` writes that seed
into `grooveName` as `pocket@000000005eed0001` — no schema change, and a name without an `@` is a
fixed backing, which is every take before M19. **A generated backing that could not be rebuilt
from what was stored would make every take played over it unexplainable** (R1.2.2), so the seed
is not optional bookkeeping.

**Renders are reproducible as of §7.29 step 2 and were not before.** `Pattern.make` sorted its
hits by dictionary order, which Swift seeds per process, so the same backing rendered to
different bytes run to run. Any byte-comparison of audio taken before that fix is worth less
than it looks.

**Any change to a pattern must keep `CommonGridTests` green** — it compares every hit's sample
position before and after the lift, at three tempos and four feels, and a one-step drift fails it
3,265 times. The 51 WAVs `render` writes are the other half of that gate.

**A style can be played over from either surface.** `jam --style driving --seed <hex>` from the
CLI, with the seed printed as the flags that reproduce it; a band picker on Jam and Play in the
app, offering the approved styles only. An unauditioned style still refuses from the CLI without
`--probe`, because auditioning one *is* a deliberate look at a setting nobody has earned, and the
app deliberately cannot reach one at all (§7.33). **Eight takes have been played over generated
backings**, two per style.

**Anything can be tried from the CLI without corrupting a ladder.** `--probe`, anywhere on the
line, records a take as a deliberate look at a setting that was not earned — form level 3, a rung
above the ceiling, an offbeat level. Nothing that decides what to practise next reads one, and
`review form` marks it `*`. **A bad probe is data, not a demotion.**

```sh
./.build/release/TimingSpike form 100 64 8 3 --probe
```

The planner deliberately does **not** propose probes. A testing affordance in the planner is a
testing affordance in the business logic, changing what the app recommends to a player who is not
testing anything; the first version of §7.26 did exactly that and was removed. Same reason the
GUI has no probe control: the app is for playing.

| Done | |
|---|---|
| M0–M1 | Clock bridge validated, calibration |
| M2–M4 | `TimingCore`, groove engine, jam capture |
| M5–M8 | SwiftUI app, continuation drill, trends, tempo calibration |
| M9–M12 | Session builder, cold-vs-warm, recall drill, musical content |
| M13 | Experiment runner — preregistered A/B arms, no verdict before the declared n |
| M14 | Interval ladder — rungs, tempo ceilings, a tempo-rotating block, `slow-vs-fast` (§7.23) |
| M15 | The feels — a grid that expects the offbeat late, swing measured as placement, the offbeat drill (§7.24) |
| T1 | Test infrastructure: the take factory, storage under test (§7.22) |

**§7.20 is the pre-M13 review** — eleven places where a number or a rule said more than it
could support, all closed. Read it before trusting any statistic here: four of the eleven were
the *enforcement* being fake rather than the code being wrong.

**§7.22 is M13 and T1 as built.** T1 is the test infrastructure that closed the gap finding 11
exposed — nothing had ever tested *writing* a take. It is not an M-number on purpose: it is a
different axis from product capability, and steps d–e of it are done.

**What has and has not been played.** M14 ran once, on 5 August: the chain held end to end
(`rung=quarters → ladder-quarters → subdivisions=1 → tag=ladder`) and the experiment take was
stamped. **That sitting's timing data is not usable** — it was played exhausted and is recorded
as such in §7.24. M15 now has five live takes: two swung jams and one offbeat take in the small
hours of 6 August, all tagged `tired` (§7.24 steps 7 and 8), plus two further offbeat takes on
11 August at 69 and 85 BPM, both of which **held** the feel where the first slipped (§7.38). **Both
sittings found a defect no test could, and both were the same gap** — between the path a live
take runs and the path a stored take is read back on. The swung takes were scored on a straight
grid; the offbeat take's own result did not survive being saved. Nothing has yet been played
above eighths. **The offbeat has since been held** — 96% off the beat at 69 BPM on 11 August,
against 23% at 100 BPM, which is §7.38 and moved the drill's default tempo to 70.

Three things to watch on the next session, all in the gap between tested pieces where every
defect of this shape has lived:

- the **arm text** on screen matches the arm the debrief reports;
- the **rung and feel** the block preview announces match what the take is stored with;
- at offbeat level 3, a report of "slipped" on a take that *felt* fine means the phrase marker
  is not doing its job (§7.24 step 6). At level 0 it has already meant the feel genuinely went.

No backing above eighths has been played along to — only rendered and heard. The swung backings
have been heard and confirmed as a shuffle; nobody has played *along* to one.

**Four planned sessions are written up** — §7.17 (4 Aug 2026), §7.19 (5 Aug morning), §7.21
(5 Aug afternoon) and §7.34 (8 Aug, the first with a band). Read them before touching drills:
between them they produced two instruction bugs, one reporting bug, the project's only retracted
finding and the hung note — none of them maths. **Eight manifests are on disk**, so half the
planned sessions have no write-up, and takes recorded from the drill menu are in the data but not
written up either: **23 of the 49 jams carry no session placement**. That does not hide them from
`review cold`, which infers sittings from 45-minute gaps between takes and reports all 49 across
17 sittings — what it costs is the distinction between a *controlled* cold probe and whatever
happened to be played first, which is why that readout carries a warning saying so.

## Surfaces

Both front ends drive `TrainerEngine`; neither contains measurement logic.

**App** (`./build-app.sh`): Session (a planned evening), seven single-take modes — Jam, Offbeat,
Form, Alone, Tempo, Recall, Play — and History. Jam, Alone and Tempo carry a **subdivision picker**
that offers only the rungs the chosen tempo can score honestly, and a Jam on a binary rung can
also be **swung**. Jam and Play carry a **band picker** offering the approved styles only — the two
clamp each other, since a rung and a style cannot both play. **Offbeat is an app mode as of §7.39**,
with a Downbeat picker over all four levels and a default tempo of 70 rather than 100 — every drill
is reachable from both surfaces.

**"No surface gaps left" was too strong when §7.39 said it, and the gap it missed was in the
instructions.** A swung jam from the app's menu was described with the *straight* text until §7.46:
every mode existed, and one of them said the wrong thing. Both surfaces derive a drill's text from
the config the engine will run — `DrillInstructions.forJam` and its three siblings — so a surface
can no longer pass fewer settings than the take carries. What is still unproven is the app's
**offbeat** and **swung** paths: no take at either has ever been recorded from the app.

**CLI** (`./.build/release/TimingSpike <command>`): everything the app does, plus calibration
and the M0 diagnostics. `TimingSpike` with no argument prints the full command list; README.md
has the annotated table. The analysis readouts are `review trend | cold | content | feel |
tags | conditions | compare | form | dropout | tempo | experiment | interval`.
Drills: `jam | form | dropout | tempo | memory | offbeat | session`.

`render [bpm] [bars]` writes every ladder backing to `temp/renders` as a WAV. **A rung the
player has not heard is a rung the planner must not promote them onto** (§7.23), and this is how
that precondition is met without booking a live run. `render --style driving@06965a16872036af`
writes that one piece instead — paste a take's `grooveName` and hear exactly what it was played
over. An unapproved style renders, because rendering is how a style gets heard in the first place.

## Environment constraints — check these before proposing a solution

- **No Docker on this workstation.** Andrew runs containers on his Proxmox nodes. Do not start
  a local daemon; write pipeline config and hand it over.
- **Git remote is self-hosted Gitea**, not GitHub. `gh` is not installed; pull requests are a
  browser step. CI is **Woodpecker**, and it runs: pipeline #42 went green on `main` in about a
  minute (clone, verify, purity). The domain resolves only from Andrew's internal DNS, so an
  agent cannot fetch it or read the remote — take his word for what merged, and look commits up
  locally by hash.
- **No macOS CI agent exists.** `.woodpecker/test.yaml` runs the Linux-buildable half — which
  is the 550 pure-module tests, because `Package.swift` excludes the Apple-only targets off
  macOS. `TrainerKitTests` (282 tests) is macOS-only and runs in `check.sh` alone, so a
  green pipeline covers less than a green gate.
  `.woodpecker/release.yaml.disabled` is parked until a dedicated Mac exists; it must not be
  pointed at this machine (a build during a take can perturb the render thread).
- **Not installed:** `swiftlint`, `swift-format`, `gh`, `tea`, `jq`, `shellcheck`. `scripts/check.sh`
  does the linting with grep, because the rules that matter here are project-specific anyway.
- **bash is 3.2** (macOS). No `mapfile`, no associative arrays, in hooks and scripts.

## Input hardware — what a drill may assume

Only the first row is what every take on record was measured through. The rest are **owned but
never yet used for measurement**, so treat them as untested paths, not as capability.

| Input | Status | Path |
|---|---|---|
| Launchkey (keys + pads) | **In use.** Every take ever recorded | CoreMIDI — driver timestamps, validated in M0 |
| TS→USB audio adapter | Owned, cheap, works | Electric guitar, bass, amplifiers, and the TDV6 drum module's line out |
| External microphone | Owned, used for recording | Vocal capture, and the calibration test tone |
| **Acoustic piano** | **Owned.** No data output of any kind | Onset detection from a microphone — M24's path, on an instrument with a hard attack |
| USB→MIDI interface for the drums | **Planned purchase** | Would put the drum module on the MIDI path |
| Better audio interface | Planned purchase | Replaces the TS→USB adapter |

Three things follow, and they change what the roadmap costs:

- **M21's guitar hardware is no longer missing.** PLAN §7.13 said guitar was the one milestone
  needing hardware he does not own; the TS→USB adapter closes that. What it does not close is
  the measurement question — see below.
- **A cheap adapter is fine if its latency is *stable*.** Magnitude is calibrated away and only
  shifts bias; variable buffering adds jitter, and jitter is the skill metric. So the adapter has
  to be characterised for *spread*, not for offset, before any number through it is trusted.
- **The drum module on MIDI is a different milestone from drums on audio.** With the planned
  USB→MIDI interface the kit sends note-ons with driver timestamps — the path M0 already
  validated — and needs no onset detection at all. Through the TS→USB line out it is an audio
  problem. Same instrument, entirely different measurement quality.

**The piano is a microphone problem, and a favourable one.** It emits nothing electrical, so the
only route is onset detection from audio — which is M24's path exactly. A struck string has a far
sharper attack than a sung note, so if that detector works anywhere it works here, and it is the
natural thing to validate M24's onset code against *before* pointing it at a voice. It also has the
widest key span in the house, which is what §7.55's hand-span idea wants and what the Launchkey
Mini's two octaves cannot give.

**Headphones are a hard requirement for anything vocal** (M24), and the reason is feedback, not
just bleed: an open microphone and a speaker in one room is a howl, and the drill would be
unusable before it was inaccurate.

## Build, test, run

```sh
./scripts/check.sh                      # the gate — must pass before every commit
./scripts/install-hooks.sh              # once per clone, installs the tracked git hooks

swift test                              # 832 tests, no hardware needed
swift build -c release                  # CLI
./.build/release/TimingSpike selftest    # analysis maths vs synthetic ground truth
./build-app.sh && open "Musical Trainer.app"
```

Four test targets, and where each runs:

| Target | Runs | Covers |
|---|---|---|
| `TimingCoreTests` | everywhere, including CI | every analysis, against planted ground truth |
| `GrooveCoreTests` | everywhere, including CI | patterns, sequencer, backings |
| `TrainerKitTests` | **`check.sh` only — macOS** | storage, the clock-bridge reduction, config validation, session sequencing |
| `Tests/TestSupport` | not a test target | the shared generators every suite imports; add pathologies here, not per file |

`Tests/TrainerKitTests/TakeFactory.swift` builds stored takes of any type and
`StoreBackedTestCase` redirects storage into a temp directory — **subclass it rather than
calling `SessionStore.save` directly**, or a test will write into the real practice history.
`check.sh` fails if anything outside `Tests/` arms that redirect.

**After changing a stored property on a shared type, `swift package clean` before trusting a
failure.** Test objects compiled against the old struct layout fail on code that has not
changed — the tell is `git diff` showing the failing file untouched. It has cost two debugging
rounds in M15 alone and is recorded in PLAN §7.23 step 0 and §7.24 step 2.

**Never run a drill command to check its arguments.** `jam`, `offbeat`, `dropout`, `tempo` and
`memory` open an audio device and wait. Argument handling lives in `parseRung`, `parseFeel` and
each config's `validate()` precisely so a test can reach it — §7.22 records a test that played a
two-and-a-half-minute drill through the speakers, and §7.24 step 5 records the same mistake made
from a shell.

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
              Storage is tested by TrainerKitTests; audio and MIDI still are not.
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

## The codebase, in the order data moves through it

A take goes: **groove scheduled → MIDI captured → both clocks reduced to one timeline → notes
clustered → matched to a grid → analysed → stored → recomputed on every read.** Nothing reads a
stored summary back (R3.1); the review re-runs the analysis from raw taps, which is why a fix
reaches takes recorded before it.

| Stage | Where | What it is |
|---|---|---|
| Schedule the backing | `GrooveCore/Sequencer`, `Pattern`, `Library`, `LadderBackings` | Patterns in steps-per-bar; `Library` holds the named backings (`jamBacking`, `basicRock`), `LadderBackings` one groove per subdivision, keyed by `notesPerBeat`. **A pattern's step resolution is not the analysis grid** — three of the four ladder backings report `stepsPerBeat` 4, so the backing cannot tell the rungs apart and the grid must come from the rung |
| Play it | `TrainerKit/GroovePlayer`, `DrumSynth`, `LiveInstrument` | Render callback owns the sample clock; synthesis is in-app, no samples |
| Capture keys | `TrainerKit/MIDIInput` | One CoreMIDI client per process, never disposed |
| Bridge the clocks | `TrainerKit/HostClock` (`SampleHostMap`), `JamAnalysis.reduce` | Least-squares fit of (hostTime, sample); calibration applied here, sign and all |
| Collapse chords | `TimingCore/TapClustering` | Near-simultaneous note-ons are one rhythmic event |
| Match to the grid | `TimingCore/Grid`, `Matching` | ±40% window (`Matching.defaultWindowFraction`); outside it is an *extra*, never a late note |
| Analyse | `TimingCore/TimingReport`, `WingKristofferson`, `DropoutAnalysis`, `FormAnalysis`, `TempoCalibration`, `TempoMemory`, `MusicalContent`, `SwingAnalysis`, `OffbeatAnalysis` | One analysis per drill, all pure. Every stored type has a `report()` — **never pair `reconstruct()` with an `analyze` call of your own**, or the take's own parameters stop reaching the analysis |
| Quantify uncertainty | `TimingCore/Bootstrap`, `Statistics` | Three bootstraps, and picking the wrong one is a defect (R3.2) |
| Store | `TrainerKit/SessionStore` | One JSON per take; raw taps plus a summary nothing reads back |
| Aggregate | `TimingCore/TrendAnalysis`, `WarmUpAnalysis`, `ExperimentAnalysis`, `IntervalResponse`, `ProducedInterval` | Trends, cold-vs-warm, the A/B readout, and the interval axis. The last two are the only pair where the unit differs on purpose — takes for the first, **notes** for the second |
| Decide what to practise | `TimingCore/SessionPlan` (`SessionPlanner`), `Experiment` | Builds the evening; `ExperimentSchedule` assigns arms. The **ladder block is the only one whose tempo may vary** — cold probe, benchmark and experiment are locked (R3.5) |
| Run the evening | `TrainerKit/SessionRunner` | State machine over blocks; stamps placement and arm. Sequences, never measures |
| Drive it all | `TrainerKit/TrainerEngine` | `runJam` / `runForm` / `runDropout` / `runTempo` / `runMemory` — the **only** implementations of anything measured |
| Show it | `TrainerKit/Commands` (console), `Sources/MusicalTrainerApp` (SwiftUI) | Presentation only |

Types worth knowing before changing anything:

- **`Grid`** — index arithmetic, never accumulation. `subdivisions` is grid points per beat.
  Indices stay uniform under a feel; only their *times* move, which is what stops a feel
  reaching past `Matching`. There is deliberately **no `interval`** — under a feel there is no
  single spacing, so ask `gap(around:)` about a particular point.
- **`IntervalRung`** — a rung of M14's ladder, and the tempo ceiling its matching window implies.
  The ceiling assumes absolute spread does not move with the interval, which §7.23 step 3b
  measured rather than assumed.
- **`JamConfig.rung` / `JamSession.rung`** — the subdivision the player was **asked to produce**.
  Also on `DropoutConfig`/`TempoConfig`, where it stops the period estimate guessing the note
  value: rounding an observed 1.45 notes-per-beat to 1 reports 45% fast as a fact when the same
  playing also reads 27% slow. Every stored take is near a whole subdivision, so nothing moved.
  `nil` means no rung was prescribed, **never quarters**: the benchmark and both experiment
  blocks must stay rung-less (R3.5). A rung-less take is scored at
  `JamConfig.freePlayingSubdivisions` — sixteenths, fixed, and deliberately not the backing's
  step resolution (§7.29 step 0). Distinct from `subdivisions`, which is the grid the take
  was *analysed* on; `taskSubdivisions` is the one the interval readout wants.
- **`SwingReport`** — the ratio is **derived from mean offbeat phase and never measured per
  pair**, and consistency is the swung note's spread in *milliseconds*. Reporting a spread of
  ratios is not a stylistic choice: `dr/dφ` runs 4→16 across the useful range, so identical
  steadiness would report four times worse the harder he swings (§7.24 step 3).
- **`OffbeatLevel` / `OffbeatReport`** — the offbeat drill. **Slipping onto the beat is scored
  apart from placement**, because a slipped player is dead on a grid point — the wrong one — and
  a placement figure alone would call a lost feel an excellent take.
- **`ProducedNote`** — one matched note keyed by the gap **in grid steps** to the note before it.
  Never key this on a *measured* inter-onset interval: a note's own error is inside its measured
  gap, and binning on it fabricates a placement slope out of a player who has none. There is a
  test that plants exactly that.
- **`TimingReport`** — what a jam produced. `subdivisionStats` is **phase-conditional** (where in
  the beat a note landed), not a measure of note values played.
- **`SessionPlacement`** — where a take sat in a planned evening, and the state the player
  declared before it started. Optional; 23 of 49 jams have none, and what that costs is the
  controlled cold probe rather than the sitting, which `WarmUpAnalysis.inferSessions` recovers
  from timestamps.
- **`Feel`** — the long-to-short ratio of the divided beat, and **a ratio of 1 is straight**.
  The identity falls out of the arithmetic, so nothing needs an `if straight` and `nil` in
  storage genuinely means straight — unlike `nil` rung. Swing applies to the finest *binary*
  division only: a triplet rung never swings. Ska and reggae are **not** feels; their grid is
  straight and only the drill changes.
- **`SessionState`** — usual / tired / amped / distracted / stiff, declared **before** the first
  block and never after. After the fact it would be post-hoc exclusion. `nil` means not
  declared, which is not the same as `usual`.
- **`ExperimentAssignment`** — which experiment and arm a take belongs to. Optional.
- **`ExperimentDesign.bpmByArm`** — set only when **tempo is the condition** (`slow-vs-fast`).
  For the other two designs the instruction text *is* the independent variable, so wrong text
  swaps the arms silently; with a tempo map the tempo differs whatever the text says. Check
  `variesTempo` before assuming which kind a design is.
- **`DrillInstructions.forBlock(_:)`** — the one mapping from a planned block to its instructions,
  arm included. Both surfaces call it; do not add a second.
- **`Stats.finite(_:)`** — every stored summary goes through it. `JSONEncoder` refuses a
  non-finite `Double` and a take was destroyed live because of it.

## What is not covered, and must be said rather than implied

- **Audio, MIDI and the drill runners have no tests.** `TrainerEngine.run*` past its config
  validation, `GroovePlayer`, `MIDIInput`, `AudioIO`, calibration — all verified only by a live
  run (R5.6), and the result recorded in PLAN.md.
- **`TrainerKitTests` cannot run in CI.** `TrainerKit` is macOS-only, so a green Woodpecker
  pipeline covers *less* than a green `check.sh`.
- **M15's two swung takes were played around 4 a.m., tagged `tired`, at a first attempt**: they
  establish that the machinery works and nothing about the player, and the swing readout's
  thresholds have fired correctly on real playing once. **The offbeat drill now has three takes
  and a tempo story**: 100 BPM slipped (26 of 112 notes off the beat), 69 BPM held (248 of 258)
  and 85 BPM held (213 of 247) — so the boundary between holding and inverting the feel sits
  somewhere above 85 (§7.38). The swing block's misfire on a held skank (§7.24 step 8) is still
  closed by test rather than by observation.
- **The offbeat drill now has an app mode** (§7.39), but nothing has been recorded from it — both
  offbeat takes on record came from the console.
- **`selftest` covers the analysis pipeline against synthetic ground truth**, not storage — that
  moved to `TrainerKitTests` with T1.
- **Backings are tested for pattern structure only.** Whether a groove is playable-along-to is a
  live-run question.

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
  **A presence indicator is not a number** — the app's breathing circle says a take is live and
  nothing else, and the console has no equivalent, which is why a take in progress reads as one
  not yet started (§7.34). **A progress indicator is different again**: it locates you in time, so
  it may never appear in the form drill, where knowing where you are *is* the skill, nor in the
  continuation drill, where a steadily advancing bar is an external clock during the silence that
  exists to remove one.
- **Rate before results.** The player rates a take 1–5 *before* seeing any number. A rating
  shown after the measurement is a rationalisation of it.
- **Bias is not failure.** Playing 20–40 ms ahead of a click is normal. Variance is the skill.
  Never conflate them in copy or scoring.

## Hard-won invariants

Each of these came from a real bug. Breaking one silently corrupts data.

| Invariant | What happened without it |
|---|---|
| One CoreMIDI client per process, never disposed | `MIDIServer` is on-demand; disposing the last client lets it exit, and the next create fails with −50. First take worked, second didn't. |
| Every field CoreMIDI's delivery thread touches is under `storageLock` | The dedup window was not. The delivery thread updated it before taking the lock and `reset()` cleared it after releasing, so a keyboard played between takes had both at once — one note swallowed as a duplicate or one double delivery admitted, with no incident raised either way. The field that broke it is declared immediately above the comment making the argument (§7.57). |
| Take length comes from the config, not the last scheduled sound | Drills ending in silence were truncated — the tempo drill lost its entire final round (9.6 s). |
| Collapse near-simultaneous onsets before measuring | One accidental double-hit turned a true 11 ms clock SD into 55 ms, and another into 92 ms. |
| Match against a *window*, never nearest-grid-point alone | A note 60% of a beat late snaps forward and reports as early — sign inverted. |
| Wing–Kristofferson needs isochronous, stationary input | Mixed note values produced a confident 143 ms "clock SD". Motor SD at 0 means the model hit its floor, not that the player is perfect. |
| A guard on a *count* cannot protect a *variance* | The isochrony gate admits a trial with a quarter of its intervals out of band, and the decomposition squares them. Nine intervals in 232 — 4%, well inside the gate — carried up to 99% of a trial's squared error and reported a 193.5 ms clock SD at a 600 ms beat, flagged reliable. Splitting the trial at each gap put it back to 24.1 ms. |
| Nothing louder than the groove except on the beat being marked | A crash one bar early made the form drill measure reaction to a decoy. Two takes wasted. |
| Confounds get named, not blended | A changed backing produced a "real" 8 ms spread change that was partly just different music. |
| A swung take never reaches Wing–Kristofferson | Swing alternates the intervals by design and the isochrony gate passes them. On a planted 12 ms clock and 8 ms motor, a swung series reported motor 99.7 ms and a negative clock variance. `DropoutConfig.validate` refuses it. |
| The band's swing and the grid's come from one conversion | `Feel` and `Swing` cannot share a type across the module boundary. A groove swinging at 2:1 while the grid scored 1.5:1 would look exactly like a player who drags. `JamConfig.swing` is the only conversion; `SwingAgreementTests` pins them to the sample. |
| A drill's identity survives being stored | The offbeat drill was wired into the live console path alone. `review` called the first slipped skank "steady, just early", the trend pooled its 48.4 ms spread with the free jams and turned that group's bias "worsening", and a planned block would have shown skank instructions over `jamBacking`. The take's own accessor had no callers at all. |
| The swing block and the offbeat block are mutually exclusive | A skank puts every note "off the division", so the swing readout gets *more* confident the better the feel is held: three stray notes on the beat are enough to report "you swing the beat 1.1:1" about a player dividing nothing. |
| The feel reaches the grid the *app* builds, not only the one a test builds | Both swung takes ever recorded were scored straight, because `JamAnalysis.reduce` and `SessionStore.reconstruct` kept their old calls. Reported +22 ms drag, 54 ms spread and r₁ = −0.52 — the first negative in the project's history, and an artefact. |
| A feel needs a groove, not just warped timing | The first swung backings were timed perfectly and sounded straight: every loud event stayed on an even grid and the feel was carried by a hat 8 dB down. |

## Data and analysis conventions

- Sessions live in `~/Library/Application Support/MusicalTrainer/sessions/`, one JSON per
  take, prefixed `jam-` / `form-` / `dropout-` / `tempo-` / `memory-`, plus a `session-`
  manifest per planned session (what the planner chose, why, and what was skipped).
- **Every take carries an optional `ExperimentAssignment`** — experiment id, name, arm, run
  index — written since M13 step 1 and read by nothing yet. Same reasoning as the two below: a
  take recorded without its arm is lost to the comparison for good.
- **Jam takes may carry a `rung`, a `swingRatio` and an `offbeatLevel`**, all optional. Absent
  `rung` means *no rung was prescribed* and is **not** quarters; absent `swingRatio` really does
  mean straight, because a ratio of 1 is the identity. That asymmetry is deliberate — see
  §7.23 step 4b and §7.24 step 1 before assuming either.
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
  (`Bootstrap`), and comparisons say "real change" or "within noise". Within one take the
  bootstrap is **moving-block**, because asynchronies are serially correlated — that
  correlation is the r₁ the app reports. **Anything pooled across takes is two-stage**: takes
  resampled with replacement, then blocks within each. Picking the wrong one is a defect
  (STANDARDS R3.2); the pooled path had it wrong for three milestones (§7.20).
- When a measurement can't be trusted, say so and say why. `splitIsReliable`,
  `discardedTrials`, `unusableReason`, and the comparability notes all exist because a
  confident wrong number is worse than an honest gap.

## What the data says about this player

Current as of **104 takes across 17 sittings — 49 jams, 16 form, 15 continuation, 13 tempo,
11 recall**, plus 8 planned-session manifests. **Recompute rather than trusting any of this:**
`review trend`, `review dropout`, `review feel`, `review cold`, `review content`, `review
interval`.

- **r₁ is positive in 47 of 48 jams (−0.06 … +0.62)**, recomputed rather than read off the
  stored summaries, which still hold pre-§7.32 values including a −0.52 that was an artefact. The
  single negative is −0.06, a small number either side of zero rather than a finding. He
  *under-corrects* — placement floats and wanders. He does not chase the click. Do not suggest
  counting harder; that is the documented way to make this worse, and he already reports it feels
  worse.
- **The benchmark jam is bouncing, not trending**: 24.1 → 17.4 → 22.0 → 21.7 → 24.9 → 23.6 →
  20.1 → 26.4 ms across **eight** takes at locked settings, ending wider than it started. §7.19
  recorded the first step as a real tightening and it did not hold (§7.21). Each pairwise
  comparison was measured correctly; none of them is a trend. The free-jam trend at 100 BPM is
  flat on every metric over 27 takes.
- **A large placement shift held for one long sitting and then eased.** Bias went −5.9 ms on
  4 Aug to −22.6, −16.1, −20.8, −22.4 through the 5 Aug 01:00–04:30 sittings, then −15.1 and
  −13.5 that morning, and has sat between −7.6 and −24.8 since. Unexplained either way. Bias is
  not failure (§2) and spread did not move with it.
- **Clock is the looser half in every trustworthy split.** Do not pool across silence lengths:
  4-bar runs ~11–22 / 4–12 ms across five takes, 8-bar 29.6 / 9.6 and 24.1 / 15.4, 16-bar
  22.1 / 6.8. Longer is a harder task. The newest 4-bar take has the lowest motor figure
  recorded (4.2 ms). **The drill has largely stopped producing a usable split**: five of fifteen
  takes yield none at all, and that includes every 16-bar attempt since 5 August — the planner
  says so out loud ("only 2 of the last 6 gave a trustworthy split"). The figures above are
  therefore a picture of early August, not of now. **The 8-bar figures moved in §7.25** — one of them was 40.7 / 20.9 and the
  other read 193.5 / 71.3, both inflated by a handful of hesitations feeding a variance. Anything
  quoting the old numbers is quoting the defect.
- **The form drill measures two skills and they come apart.** §7.40 split them: `onFormRate` is
  knowing which bar the phrase turns on, `cleanRate` is landing on a bar line at all. The corpus
  holds a double dissociation — 5 Aug was 36% on form against 71% clean, 10 Aug was 100% against
  32% — so a take can be strong on either axis and weak on the other. **The levels are promoted on
  `cleanRate` as of §7.41**, because every rung removes a cue about *when* to land and none about
  which bar; on the real corpus the old rule promoted him to level 3, the top, off a take he
  landed 32% of. Phrase span is the other ladder and still reads `onFormRate` — that is step 2.
  `SessionPlanner.ladderPromotionRate` is the one bar both clear. **The phrase span is the other
  ladder** (§7.43), 4→8→16→32 promoted on `onFormRate`, with the felt-period rule as its only
  demotion. Only one axis moves in any plan and there is a test across every combination; *which*
  one is decided by `SessionPlanner.formAxis(for:)` (§7.44), which prefers the **temporal** ladder
  when both are earned: advancing a level costs no data, while a longer span halves the marks per
  take and so thins the sample the temporal axis is measured on. An ordering, not a veto — the span
  still moves when the level is topped. **M16 is built — steps 0–4** (§7.45 is the last). The
  readouts now show `markedEveryBars`, the phrase the player *actually* marked, which the analysis
  has computed since M7 and no surface has ever displayed: a 12 August take held six gaps of
  7.88–8.12 bars against a 16-bar setting and was scored 3/7 on form, because every figure is
  measured against the setting rather than what was held. Showing it immediately exposed that the
  regularity gate admitted a band wider than a doubling (shape 11), now tightened with no change
  to any plan. **Nothing has been played under the finished milestone.**
- **The form drill's instructions state the phrase length** (§7.42). They were hardcoded to "8 bars
  each by default" whatever ran, and 8 and 16 bars of the same groove are audibly identical — at
  level 2 there are no fills, accent or silence, so the words are the *only* place the number
  exists. A player mis-told the span marks the span he was told, and `markedEveryBars` would have
  read that as a felt period. **The form backing stays uniform on purpose**: a varying one would
  hand the player timing landmarks the ladder exists to remove.
- **Nothing in the drill trends is moving, and two "worsening" verdicts were retracted to get
  there** (§7.27). `review trend` now fits one line per task instead of one line and a caveat:
  the continuation clock SD was +1.32/take [+0.64, +3.05] *worsening* across pooled 2-, 4-, 8-
  and 16-bar silences and is +2.05 [−1.03, +4.85] **flat** on the seven 4-bar takes; the form
  on-form rate was −0.04/take [−0.07, −0.01] *worsening* across levels 0–2 and is −0.01
  [−0.15, +0.10] **flat** at level 2 over 8-bar phrases. Both verdicts were the ladder, not the
  player. Only three groups now have the three points a fit needs, which is the honest cost.
- **"Runs slow unaccompanied" is dead, and it has now overshot the other way.** The three most
  recent 16-bar continuation takes produced 114 BPM (+14%), 103 (+3%) and 103 (+3%), against a
  run of −5% to −0% through early August. Whatever this is, "he runs slow" is not it.
- **The one learning signal has gone flat, and this is a retraction.** `review cold` fitted the
  tempo drill's cold error **improving** at −0.48%/sitting [−1.27, −0.13] and it was the only
  learning signal anywhere in the dataset. Over 13 takes across 10 sittings it now reads
  **−0.263/sitting [−0.600, +0.051] — flat**, and the readout says so in its own words. The
  earlier interval excluded zero; this one does not. Nothing in this dataset is currently
  improving.
- **Feel tracks the measurement, but less well than it did**: r = −0.38 over the rated takes,
  against −0.48 a milestone ago and −0.66 before the 5 Aug evening session. That sitting was played exhausted (§7.24) and
  is the likeliest cause; §7.17 already recorded fatigue breaking the link once, with two jams of
  identical spread rated 4 and 1. Treat the correlation as soft until a rested sitting restores it.
- **Most of what he plays is a beat apart from the last note**, so every headline figure this
  project quotes — including "his ~20 ms spread" — is *quarter-note placement*, and the
  sixteenth-note grid free takes are scored on is doing almost no work. `review interval` is the
  live figure: 44.7% of 15,800 matched notes sit at 600 ms, the beat at 100 BPM, with the rest
  spread thin across sixteen other intervals. **The precise free-jam split quoted here before
  (78.4% / 15.0% / 0.5%) was measured over 26 free takes and is not re-derivable from any current
  readout** — the note table bins by interval in milliseconds across every take, not by grid step
  within free ones. Treat the qualitative claim as standing and the old percentages as of that
  sample.
- **His spread is a fixed number of milliseconds, not a fixed fraction of the interval — and
  which fit says so has changed.** On **notes**, where there are ~15,800 of them across 136–1800 ms,
  it holds and holds strongly: absolute **+0.03 ms per 100 ms [−0.48, +0.51]**, within noise,
  against **−0.83 points [−1.43, −0.51]** for the percentage, which is real. On **takes** it no
  longer does: with seven distinct tempos now on record both units read within noise (+0.77
  [−3.56, +5.34] and −1.30 [−3.13, +0.16]), and the readout says outright that it cannot yet
  say which unit compares. **The note-level fit is the one carrying this finding**, and the
  across-takes fit — which used to support it — has gone quiet as more tempos arrived rather
  than contradicting it. Milliseconds are still what compare across tempos and rungs, so **do not
  normalise spread by the interval**, and do not assume "faster is tighter" is arithmetic. That
  premise was stated as fact in §7.23 for three steps before it was checked.
- **Tempo is not analysed anywhere.** It is only ever *controlled for* — trends split mixed-tempo
  groups and `review tags` warns about them. His stated hypothesis is that faster is easier to a
  point and that slow tempos make him rush, and no readout can currently ask it. The data cannot
  either: 25 jams at 100 BPM, 4 at 110 (all one evening, six minutes apart), 1 at 120. And 61%
  of every matched note sits at one interval, 600 ms, which `review interval` now says out loud. M14 is
  where this gets built — see §7.23, including why raw spread cannot be compared across tempos.
- **The recall drill's interference cost is not established.** §7.19 read it as the distractor
  *helping*; since the attrition rule landed (§7.20 finding 2), three of the four takes are
  withheld as non-comparable and one remains. Treat it as unmeasured, not as a direction.
- **M12's first data contradicts his hunch**: busier playing went with *looser* timing within a
  take, and the censoring bias runs against that result rather than producing it. His hunch is
  about the mode of playing across a take, which M12 cannot test and M13's `steady-vs-melodic`
  experiment is now collecting for.
- **Three tags pool across a confound** — `focused` and `relaxed` across tempos, and `tired`
  across two swing ratios. All three are flagged at the point of display with what the mix
  ruins (§7.28); `tired` was silent until that list was consolidated.
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
- **Say what you could not verify.** Hardware paths (audio, MIDI, the drill runners) have no
  unit tests. The verification pipeline *has* run — #42 green on `main` — but the release
  pipeline never has, and neither covers `TrainerKit`. Naming the gap is part of the work;
  implying coverage that does not exist is worse than the gap itself.

## Procedure

Full rules in [STANDARDS.md](STANDARDS.md); this is the short form.

1. **Plan the branch before the first commit.** `<type>/<short-description>`, same types as the
   commit format. Decide what whole thing it delivers, the two-to-six commits it will take, and
   how it lands without breaking anything — STANDARDS.md §8.1.1 and §8.1.2. **The branch is the
   unit of work**: it is what gets reviewed, rolled out and documented, and the commits are steps
   inside it. `open-pr.sh` refuses a one-commit branch unless `--single-commit` declares that one
   really was the whole thing; hand that flag over only when it is true, not to get past the
   refusal. This rule was broken nine times running before it was enforced (`LESSONS.md` shape 21).
2. **Work.** Anything analysable goes in `TimingCore` or `GrooveCore` with a test that plants
   a known answer and recovers it.
3. **Write the message as you go.** `temp/current-git-commit-message.txt` (gitignored) holds
   the message for whatever is currently uncommitted, and is updated whenever the tree changes.
   A change you cannot describe yet is usually two changes. The `post-commit` hook empties it
   once that message lands, so a stale one never gets committed unread. If a change genuinely
   needs two commits, add `-2.txt` alongside it — STANDARDS.md §8.2.1, and rarely.
4. **Update the documentation — a closing step of the *branch*, in the commit that finishes it,
   not once per commit.** Walk PLAN.md, AGENT.md, STANDARDS.md and README.md and correct anything
   the branch made untrue. Documenting each commit separately puts several changes' edits in one
   file and no `git add` can separate them (STANDARDS.md §8.2.2). **LESSONS.md only when the change
   was the second instance of a failure shape**, or a new one — one defect is a PLAN.md entry, a
   pattern is a LESSONS.md one (STANDARDS.md §9.8). Re-derive any count or figure quoted in prose
   rather than trusting it; five separate accuracy passes have each found numbers copied forward
   unchecked, which is LESSONS.md shape 17. `check.sh`'s Documentation section catches the test
   counts and the shape citations and nothing else — the rest is yours.
5. **`./scripts/check.sh`** last, and `.githooks/commit-msg temp/current-git-commit-message.txt`
   — it takes a path and exits non-zero, so checking the message costs nothing and counting
   characters by eye does not work. The pre-commit hook runs only the fast half of the gate.
6. **Write `temp/pr-message.md`** — the PR body, in the shape STANDARDS.md §8.2.3 sets out.
   Part of the change like the commit message is, not an afterthought at merge time.
7. **Hand over when the branch is finished, not when the first commit lands.** A PR is a request
   to merge something whole, and every merge into `main` must be a state the repository could sit
   in indefinitely. Andrew commits, pushes and opens the PR with one line:

   ```sh
   git add -A && git commit -F temp/current-git-commit-message.txt && ./scripts/open-pr.sh
   ```

   On a branch of several commits, each has its own message file — `-2.txt`, `-3.txt` — written
   when its commit is ready rather than all up front, and the hand-over is one `git add`/`commit`
   per file before the single `open-pr.sh` at the end. **Delete the branch once it is merged**:
   `./scripts/prune-branches.sh` lists what is fully merged and removes it with `--delete`.

   Give him that line, with `--base <parent-branch>` when the work is stacked so the PR shows
   this change alone. Do not run it — pushing and opening a PR are his, and this machine has no
   credentials for the remote in any case.

   **Always that line, never a bare `git push`, including for a second commit on a branch that
   already has a pull request.** Whether one is open is a fact about the server, and nothing here
   can answer it: `git fetch` fails on this machine with `Permission denied (publickey)`, so
   `origin/main` and every other `origin/*` ref is only as fresh as Andrew's last pull. A branch
   that looks unmerged here may have been merged twenty minutes ago — that has happened, and the
   `git push` handed over on the strength of it updated a branch whose PR was already closed, so
   nothing was pending and the PR had to be opened by hand. `open-pr.sh` is right either way: it
   opens one if none exists and says so if one does. See `LESSONS.md` shape 16.

**Run these to the end before starting the next change.** Every change updates PLAN.md and
usually AGENT.md, so two uncommitted changes put both sets of edits in the same files — and
`git add PLAN.md` cannot then stage one without the other. Splitting them afterwards means
editing one change's documentation back out, committing, and putting it back. That has already
cost two rounds of it in a single sitting (STANDARDS.md §8.2.2). Finish, hand over, then start.

Checklists for the things with more than one moving part: **a drill** is STANDARDS.md §9.5,
**an experiment** is §9.5.1, **a finding** is §9.6. After a storage change, §9.3. After analysis
or audio, §9.2.

Inspecting the data is what `review` is for — `review list`, `review <n>`, and the readouts in
Surfaces above. Prefer it to reading the JSON: every readout recomputes from raw taps, so it
shows what the current analysis says rather than what was true when the take was recorded.

`./scripts/install-hooks.sh` once per clone, or none of the above is enforced.
