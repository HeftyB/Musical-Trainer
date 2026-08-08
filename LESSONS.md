# Failure shapes

Not a style guide. A catalogue of the specific ways this project has gone wrong, each with the
real instance, its numbers, and the guard that now prevents it.

**Every one of these shipped, or nearly did, with a green gate.** None was a crash. That is the
point: the failures worth cataloguing here are the ones where the code runs, `check.sh` passes,
the numbers look plausible, and the answer is wrong. `PLAN.md` §7.20 records a review where the
gate was green throughout — 175 tests, 36 selftest checks, a warning-free release build, every
stored take decoding — and eleven findings came out of it anyway. A green gate bounds what has
been checked, not what is true.

Read this before a codebase review, and look for these shapes specifically rather than for "code
smells". **This is the file the code comments cite by number**, so the numbering is load-bearing:
shapes are appended, never inserted, and never renumbered. `check.sh` fails when a citation names a
shape that does not exist here.

A generalised version — the same shapes with this project's specifics stripped out, for starting a
new repository — is kept outside the tree with the rest of the cross-project templates.

---

## 1. The path under test is not the path that ships

**The most common shape here by a distance — six instances.** Tests are written against a helper,
an accessor, or a decision made inline somewhere no suite can reach. They pass for ever and guard
nothing.

**Instances:**

- **The feel never reached the app's grid** (§7.24 step 7). `Grid` gained a feel in M15 step 2 and
  both call sites in the running app kept their old call — `JamAnalysis.reduce` for a live take,
  `SessionStore.reconstruct` for a review. Every one of step 2's tests **built its grid inside the
  test**, so the suite proved a swung grid places notes correctly and never asked whether the app
  hands the grid a feel at all. Both swung takes ever recorded were scored straight: +22 ms drag,
  54 ms spread, and r₁ = −0.52, the only negative reading in the project's history and an
  artefact. `FeelReachesTheGridTests` closes it from both ends.
- **The offbeat drill's own accessor had no callers** (§7.24 step 8). `JamSession.offbeatReport()`
  existed, was correct, and had **zero callers in `Sources` and zero in `Tests`** — written in
  step 6 beside the storage and never wired. `review 30` called the first slipped skank *"steady,
  just early"*, `review trend` pooled its 48.4 ms spread with 21 free jams, and the planner could
  not have run it at all. One step after the instance above, and the same tell.
- **A decision inside a function that opens an audio device.** `SessionRunner` built its
  `JamConfig` with `rung:` and `feel:` only, so a planned offbeat block would have printed skank
  instructions over `jamBacking`. Nothing caught it because nothing in a suite can reach inside a
  function that waits on hardware. It is `SessionRunner.jamConfig(for:)` now.
- **`TakeAxis.mixed(in:)` was a decision inside a `print`.** A pooled readout decided what
  confounds to name while printing them, which no suite can check. Extracted so a test can reach
  it (§7.28).

**Guard:** before writing a test, ask what production code calls the thing you are about to
assert on. If the answer is "nothing", you are testing a copy. When logic sits inside something
untestable — a render callback, a drill runner, a print — **move the decision out** to a property
or a small function the suite can reach, then revert the fix and watch the test fail.

---

## 2. A guard verified by reading it

A validation rule, `check.sh` line or assertion that looks correct and matches nothing.

**Instances:**

- **The force-unwrap rule matched `!` only when followed by `.`** (§7.20 finding 5), so bare
  force-unwraps used as values — most of them — passed. **Eleven** sat in `Sources` under a green
  PASS.
- **Its replacement was broken the same way.** `[A-Za-z0-9_)\]]!` closes the bracket expression at
  the first `]`, because a backslash inside brackets is literal, so the rule meant something else
  entirely. **Two rounds of checking at the shell missed it**, because the shell and the script
  disagreed about escaping. `]!` is a separate alternative now, and the comment in `check.sh` says
  why so it is not reintroduced while being fixed.
- **The decode gate could not fail** (§7.20 finding 6). `check.sh` runs `review list` and tests the
  exit status, but `SessionStore.load` wrote its "could not be read" note to stderr and returned
  whatever decoded, and the CLI exited 0. **And `review list` loaded only jams**, so a schema
  change orphaning any of the other five stored types could never have been caught.

**Guard:** R5.7 — plant a violation, watch it report FAIL, remove it, watch it report PASS, at the
time you add the rule. Reading the rule is not verification, and neither is testing it in a
different shell from the one the script runs in.

---

## 3. A filter that hides real hits

A search narrowed to reduce noise, which then conceals the thing being searched for. Especially
dangerous because the *result* of the search becomes a claim in a document.

**Instances:**

- The force-unwrap search excluded lines containing a quote, to duck string-literal false
  positives. That filter hid five real violations, and **the count went into §7.20 as six when it
  was eleven**.
- The survey of `Grid.interval`'s consumers filtered out filenames containing "Interval", to
  suppress noise. It hid `ProducedInterval`, and **"`interval` has a single consumer" went into
  §7.24 of `PLAN.md`**. It had two, so the blast radius stated in a design decision was half what
  it actually was.

**Guard:** when a filter is needed, report what it excluded. If a search result is going to become
a claim in `PLAN.md`, run it unfiltered once and read the noise.

---

## 4. A test that compares the system against itself

Asserting that output matches a value the same code produced. It passes through any mistake made
consistently.

**Instances:**

- **The benchmark test compared each plan against a reference plan built by the same planner**
  (§7.23 step 4d). Planting a benchmark at `referenceBpm + 5` did **not** fail it: the reference
  moved with the thing it was checking, so it could see variation *between* histories and was
  blind to a constant that was simply wrong — the likelier mistake once the planner has a tempo
  rotation in it at all. `testTheBenchmarkIsAlwaysTheSameLockedTakeWhateverTheLadderDoes` asserts
  against `SessionPlanner.referenceBpm`, `benchmarkBars` and `benchmarkTag` outright now, and the
  planted violation fails 27 assertions. R5.7 is written about `check.sh` rules; it applies to any
  test whose whole job is that something did not change.
- **`testTheExistingJamBackingIsUntouched` asserted the arrangement's step *resolution*** as a
  stand-in for "the music every recorded take was played over has not moved" (§7.29 step 1). The
  lift to a 24-step grid changes resolution by design, so the proxy would have passed had the lift
  been wrong. It schedules the whole arrangement and compares sample positions now, which is the
  claim its name always made.

**Guard:** assert against values stated independently — arithmetic written longhand in the test, a
figure computed by hand, or output captured *before* the change.
`ConfoundedFitTests.testTheContinuationTrendsWorseningVerdictWasTheSilenceLength` is the pattern:
every clock SD transcribed from `review dropout` rather than recomputed by the code under test.
When rewriting a computation, capture the old output first and diff it — and check what the
assertion is a proxy *for*.

---

## 5. A test that only runs the easy case

The configuration where the bug cannot appear.

**Instance:** two planner blocks that each take a slot outright are ordered by which is appended
first, so adding the interval ladder ahead of form dropped form from **every 20-minute session**
(§7.23 step 4d) — §7.16's regression exactly, arriving on a new cause a milestone later. The test
written to catch it ran only at **45 minutes**, where both fit and the ordering is unobservable.
It runs at 20, 30 and 45 across nine histories now.

**Guard:** identify the configuration where the behaviour is *observable* and test that one.
Usually the smallest, the most constrained, or the boundary — not the comfortable middle. The
shortest session is the only place block ordering exists at all.

---

## 6. A derived unit that is not comparable across its own range

A ratio, percentage or normalised score that is meaningful at one end of an axis and misleading at
the other. The numbers stay plausible throughout.

**Instances:**

- **Swing consistency as a spread of ratios** (§7.24 step 3). `dr/dφ` runs 4→16 across the useful
  range, so two planted players with *identical* physical steadiness would report the deep swinger
  as **3.5× worse** — penalising him for the thing being trained. `SwingReport` derives the ratio
  from mean offbeat phase and reports consistency in **milliseconds**, and the test computes what
  the rejected unit would have said.
- **Normalising spread by the inter-onset interval** (§7.23 step 3b). The premise that spread
  scales with the interval was stated as fact in `PLAN.md` for three steps before anyone measured
  it. **It is false for this player**: absolute spread is flat at −0.11 ms per 100 ms
  [−1.85, +0.63] over 30 jams and a 200–1200 ms range, while the percentage form moves for real at
  −1.07 points [−2.54, −0.69]. The normalisation would have introduced the dependence it was meant
  to remove.

**Guard:** before normalising, ask what the invariant actually is — and *measure* it rather than
assuming. Where two candidate units exist, report both and let the data say which is flat. Prefer
the unit that is linear in what the player physically does. Milliseconds, here.

---

## 7. A cached summary nobody reads back — until someone does

A denormalised value kept "for legibility" that a caller eventually trusts.

**Instance:** the trend, the app's history chart and `review list` all plotted stored summaries
that predated chord clustering — a stored SD of 16.7 ms against 18.3 ms recomputed — and fitted
slopes through the difference. **Three separate violations, all shipped.**

**Guard:** R3.1 — store raw taps and recompute everything. The cache exists to keep the JSON
legible and nothing reads it back; `check.sh` fails on any read of a summary field outside
`SessionStore`.

---

## 8. Rounding without checking how far you moved

Snapping an observation to the nearest legal value, with no check that it was near one.

**Instance:** the continuation drill's period estimate divided the produced interval by the target
and rounded to the nearest whole number to identify the note value (§7.23 step 4e). At an observed
**1.45 notes per beat it rounded to 1 and reported 45% fast as a fact**, when the same playing
equally supports 27% slow — two readings that disagree about the *sign*, and the code picked one
and printed it. Every stored take turned out to be near a whole subdivision, so no published
number moved; the defect was latent, not harmless.

**Guard:** after snapping, check the distance. If the observation is not near a legal value, say
it cannot be read rather than choosing. Better still, take the note value from the configuration
— `DropoutConfig.rung` — rather than inferring it from what was played.

---

## 9. A constant that happens to match

Two places holding the same value for different reasons, agreeing only by coincidence.

**Instances:**

- **The free-playing grid was a property of the drums** (§7.29 step 0).
  `rung?.subdivisions ?? backing.arrangement.stepsPerBeat` — `jamBacking` happens to be programmed
  at four steps per beat, so twenty-six of the thirty takes on record are scored on a sixteenth
  grid for that reason and no other. **Both quantities were 4, so no test could tell them apart**:
  reverting the fix left every assertion in `FreePlayingGridTests` passing, and the first
  revert-check came back green and looked like success. The real guard was a `check.sh` rule —
  nothing in `TrainerKit` may read a pattern's `stepsPerBeat` — until step 1 made the two numbers
  differ (4 against 24) and the tests started proving the decoupling by themselves.
- **`Grid`'s feel parameter defaults to straight**, so both call sites that forgot to pass one
  compiled unchanged and were correct for every take recorded before M15. Shape 1's instance and
  this one are the same defect seen from two sides.

**Guard:** derive from one source structurally rather than keeping copies in sync. When two
quantities are equal today for different reasons, **write the guard that survives them diverging**
— and know that a test cannot be that guard while the numbers still match.

---

## 10. One word, two meanings

A term that means two different things in one codebase. Every use is a coin flip.

**Instance:** "how finely we divide the beat" legitimately meant both *what the content is authored
at* and *what the player is scored against*. They coincided at 4 for the life of the project.
Once they diverged, the ambiguity produced **four separate defects in a single milestone**
(§7.23) — and then a **fifth** (§7.29 step 0), sitting in the default branch of the same
expression, beneath a doc comment explaining the distinction.

The names now carry it: `subdivisions` is the analysis grid, `rung` is what was asked for,
`taskSubdivisions` is what the interval readout wants, `Pattern.stepsPerBeat` is authoring
resolution, and `JamConfig.freePlayingSubdivisions` is the fallback.

**Related, by choice rather than accident:** `DrumVoice` was renamed to `BackingVoice` before a
`bass` case went into it, and `DrumKit` to `BackingKit` — sixteen compiler-checked references
while it was still cheap (§7.29 step 2).

**Guard:** rename one of them the moment you notice, even if nothing is broken yet. Put the
distinction in the parameter name, not only in a doc comment — comments do not get read at the
call site. Do the rename *before* the thing that makes the name wrong, not after.

---

## 11. The threshold you reasoned to is wrong

A limit chosen by argument that is obviously wrong the first time real data goes through it.

**Instance:** `SwingAnalysis`'s minimum of 8 off-division notes was chosen because that is what the
bootstrap requires. On real data a free jam with **12 notes off the division against 117 on it**
reported *"you swing each eighth 1.4:1"*, with an interval excluding even — a confident statement
about a feel, computed from twelve incidental grace notes (§7.24 step 3). The count rose to 24
**and gained a companion of a different kind**: off-division notes must be at least half as many
as on-division ones. A player genuinely dividing produces roughly one of each; an ornamenting one
produces a tenth. The count alone passed the take that prompted the fix.

**Guard:** wire the readout to real data before believing the thresholds. Unit tests will not
catch this, because they use data you designed. When a guard fails on real data, ask whether it is
the *threshold* or the *shape* of the guard that is wrong — see shape 14 and §7.25.

---

## 12. Unchanged code failing

Tests fail on files a diff shows untouched.

**Instance:** twice in M15 alone, after adding a stored property to a shared type (§7.23 step 0,
§7.24 step 2). Test objects were still compiled against the old struct layout, and both times the
failures pointed at unrelated logic and looked like real bugs.

**Guard:** `swift package clean` before debugging a failure in code you did not change. The tell is
`git diff` showing the failing file untouched. Cheaper than the wrong investigation, every time.

---

## 13. A default that is not the identity

Treating "absent" as "the common value". Sometimes right, sometimes it erases a real distinction.
**This project holds both directions on purpose, in adjacent fields of one struct.**

- **`JamSession.rung` — absent means *no rung was prescribed*, and emphatically not quarters.**
  "Play what you like" and "play one note per beat" are different tasks, and the benchmark and both
  experiment blocks must stay rung-less (R3.5). A default here would silently convert the trend's
  own locked slot into a drill.
- **`JamSession.swingRatio` — absent genuinely does mean straight.** A ratio of 1 **is** the
  identity of the arithmetic rather than a separate case, so nothing needs an `if straight`, and
  every take recorded before M15 truly was straight.
- `SessionState` is the first kind again: `nil` means not declared, which is not `usual`.

**Guard:** for each optional field, decide explicitly which it is and **write the reason beside the
field**. If the default is an identity — an operation that provably changes nothing — absent may
mean it. If it is merely common, it may not.

---

## 14. A flag every caller must remember

Returning a value alongside a boolean saying whether to trust it.

**Instance:** the recall drill's interference cost was computed with a `reliable` flag, and it is
derived in **three** independent places — the report, the history chart, and the planner's input.
Two checked the flag. The third was found only by noticing that `review cold` had not moved
(§7.20 finding 2). A value that is safe only when every caller remembers a precondition is shape
7's cached-summary defect in a new costume.

**Guard:** R3.3.1 — withhold at source. Return `nil` when the value cannot be trusted, and report
the components that *are* honest separately. Here the per-condition means are still reported,
because each describes its own condition honestly; only their difference is not a measurement.

---

## 15. Optional stopping

Recomputing a comparison after every new observation and reacting when it looks decisive.

**Instance:** an experiment runner that re-ran its analysis after every sitting would have been
running the same comparison dozens of times and keeping whichever answer it liked. `Experiment`
declares `takesPerArm` before any data exists and computes **no verdict at all** below it —
withholding a number that has already been computed is still optional stopping, because it is
sitting there to be looked at. §9.5.1 forbids revising `takesPerArm` once collection has started.

**Guard:** declare the target and the stopping rule before collection, with a fixed UUID so the arm
schedule does not reshuffle an experiment already half collected.

---

## 16. A broken probe reporting a defect that is not there

The diagnostic is wrong, not the code. **Three instances, and each one nearly produced a wrong
fix.**

**Instances:**

- **An audio hash said two backings changed under the 24-step lift** (§7.29 step 1). They had not:
  **the probe changed between the baseline and the comparison** — an expression in its frame count
  — so the two runs were not measuring the same thing. Acting on it made things worse.
  Restructuring `Sequencer` to compute beat-plus-fraction instead of step-times-duration moved a
  *third* backing and was reverted. The hash was replaced by comparing scheduled sample positions
  directly, which needs no baseline capture and is exact rather than incidental.
- **A headroom test that summed velocities per step** failed two styles that measurably do not clip
  (§7.29 step 3). A hat's buffer peaks far below a kick's and their peaks do not align in time, so
  coincident velocity is not a proxy for level — the rendered peaks said 0.89 while the test said
  278. It mixes the real buffers now.
- **An onset detector that fired on energy *tripling*** found nothing after the first event of a
  bar, which looked exactly like a feature never reaching the output. The feature was fine.

**Guard:** validate the probe against a case whose answer you already know, before trusting it
about a case you do not. When a probe says "nothing happened", suspect the probe first. And do not
change the probe between the baseline and the comparison — capture the old output first (shape 4).

---

## 17. The document that says more than the code supports

Prose drifting from the system it describes — the failure mode of a project that documents well,
and this project documents well.

**Instances:**

- **`AGENT.md` called 4 August "the last live session"** when the last one was 5 August — the
  sitting that retracted a finding and forced three fixes (§7.20 finding 10). Introduced *by* a
  pass that updated the milestone table and not the sentence under it.
- **"Faster is tighter" was stated as fact in `PLAN.md` for three steps of §7.23 before anyone
  measured it.** It is false for this player (shape 6).
- **"`interval` has a single consumer" went into §7.24** off a grep that filtered out the second
  one (shape 3).
- **Test and take counts copied forward unchecked across four separate documentation passes** —
  and a fifth found `TrainerKitTests` quoted at **157** when it is **161**, `render` quoted at
  **nineteen** WAVs when it writes **43**, `AGENT.md` saying M19 steps 0 and 1 were done when
  steps 0–6 were, and the same file naming two styles `rock` and `motown` thirteen lines above the
  paragraph explaining that they had been renamed.

**Guard:** documentation is a closing step of **every** change (§8.3 item 4), and figures quoted in
prose are claims like any other — re-derive them from the system rather than trusting the previous
value. Where a document makes a checkable claim, **prefer one a script can check**: `check.sh`
verifies the quoted test counts and every `LESSONS.md` shape citation, because a rule enforced only
by discipline is a rule a hurried afternoon ignores.

---

## 18. A guard on a count cannot protect a variance

A gate that admits a *proportion* of bad observations, protecting a statistic that squares them.
The gate is not too loose; it is measuring the wrong thing.

**Instance:** `maxOddFraction` admits a continuation trial with up to 25% of its intervals outside
the isochrony band, which is the right question for *"was this a continuation attempt at all"* and
the wrong guard for Wing–Kristofferson, which is **quadratic in the residuals** (§7.25). Nine
intervals out of 232 — **4%, comfortably inside the gate** — carried up to **99% of a trial's
squared error** and produced a **193.5 ms clock SD at a 600 ms beat**, displayed with
`splitIsReliable` **true**. A player whose period wandered by 200 ms could not have produced the
97 BPM the same take reported.

Tightening the fraction would not have fixed it and would have thrown away good trials. **The
exclusion belongs where the violation is**: a hesitation is not a noisy beat, it is the sequence
stopping and starting again, so `DropoutAnalysis.continuationRuns` splits at every out-of-band
interval and the take reads 24.1 / 15.4. A second take dropped from 40.7 / 20.9 to 29.6 / 9.6 —
and the first figure had been quoted in `AGENT.md` as this player's 8-bar result.

Found by reading a readout while re-deriving figures for a documentation pass. **Nothing was
looking for it and no test could have been.**

**Guard:** match the guard to the *algebra* of what it protects. A count or a fraction protects a
count; a variance, a least-squares slope or anything else quadratic needs the outlier removed, not
tolerated. And report what was excluded — `brokenIntervals` is on the trial, on the report and in
the readout, because an exclusion nobody can see is indistinguishable from quietly dropping the
data that spoiled the answer.

---

## 19. A confound named rather than separated

Printing a warning beside a verdict, and printing the verdict anyway.

**Instance:** `review trend` fitted one line per drill with a caveat under it. The continuation
clock SD read **+1.32/take [+0.64, +3.05] worsening** across pooled 2-, 4-, 8- and 16-bar silences,
with a warning saying a longer silence is a harder task; fitted on the seven 4-bar takes alone it
is **+2.05 [−1.03, +4.85] flat**. The form on-form rate read **−0.04/take [−0.07, −0.01]
worsening** across levels 0–2 and is **−0.01 [−0.15, +0.10] flat** at level 2 over 8-bar phrases.
**Both verdicts were retracted** (§7.27): they were the ladder, not the player.

The same shape put a single offbeat take — 48.4 ms spread, the widest in the project's history —
inside *"Jams at 100 BPM"* with 21 free jams and turned that group's bias **"worsening"**. Splitting
it out returns the group to flat (§7.24 step 8). The mixed-backings warning fired correctly
throughout. R3.4 was doing its job and it was not enough.

**Guard:** R3.4 is the floor; R3.5 is the fix. A reader who sees a verdict and a caveat has still
been shown a verdict. When an axis makes two takes a different task, give it its own **group** —
`TakeAxis.all` is the one list of what those axes are, and `GroupKey` is where a trend acts on
them. The honest cost is that most groups then have too few points to say anything; they could
not say anything before either.

---

## 20. The error path discards the most diagnostic data

A failure mode that fires exactly when the observation went badly — so the data being lost is the
data worth having.

**Instance:** `JSONEncoder` refuses a non-finite `Double`, and `FormAnalysis` writes `.nan` for
`phaseErrorMeanMs` when no mark landed. A form take **failed to save** in a live session on 5
August and is gone (§7.20 finding 11). Three of the five drills were exposed: a form take with no
mark placed, a continuation take with too few usable trials, a jam where nothing matched the grid.

**The inversion is what makes it the worst defect in that review.** A take is destroyed precisely
when it went badly, which is when it is most diagnostic — and the drill it hit is the one whose
whole design is removing landmarks until the player is guessing. It also breaks R6.2 in the one
way the rule does not literally say: nothing deleted a stored take, but a take that never reaches
storage is lost just as completely, and the manifest recorded it as *"skipped"*, so nothing
downstream could tell a destroyed measurement from a declined one.

**Guard:** every stored summary goes through `Stats.finite`, and the seven affected fields are
`Optional`. Nothing reads a cached summary back (R3.1), so writing `null` costs nothing.
Structurally: R5.8 — every stored type gets a round-trip test *with the type*, not after the first
take is lost — and when writing an error path, ask what the *worst* input looks like and whether
that is the input you most wanted to keep.

---

## Adding to this file

When something goes wrong, ask whether it is an instance of a shape above or a new one. If new,
add it with: the shape in one line, the real instance with its numbers, and the guard. If it is an
instance of an existing shape, **add it there** — a shape with four instances is a much louder
warning than four separate entries, and shapes 1, 2, 9 and 16 earned their place by recurring.

Shapes 1–17 are shared with the generalised template. **18, 19 and 20 are this project's own**,
and they are here because a milestone found each one and no existing shape described it: a guard
whose algebra does not match what it protects, a confound named instead of separated, and an error
path that throws away the failure it was meant to record.

**Never renumber.** Code comments and `PLAN.md` cite these by number, and `check.sh` checks that
every citation resolves to a heading here. A shape that turns out to be wrong gets its heading
kept and its body corrected, the way a retracted finding does.
