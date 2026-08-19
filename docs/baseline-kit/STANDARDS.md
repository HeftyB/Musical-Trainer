# Engineering Standards — template

Binding rules for this repository. Where a rule has a cost, the cost is stated; where a rule came
from a real defect, the defect is named. Nothing here is style for its own sake.

**Enforcement:** `[./scripts/check.sh]` is the single gate. It must pass before every commit.
Install the hooks once with `[./scripts/install-hooks.sh]`.

> **Adopting this:** delete every rule that does not apply, and keep the numbering of what
> remains — numbers get cited in commits, comments and reviews. Sections 2 and 6 are only for
> projects that produce numbers somebody will act on; delete both otherwise. Everything in 4, 5
> and 7 applies almost everywhere.

---

## 0. Document map

Five documents, five jobs. Putting content in the wrong one is a defect.

| Document | Holds | Does not hold |
|---|---|---|
| `PLAN.md` | Design, rationale, findings, measured results, roadmap. **The reasoning lives here.** | Procedure, style |
| `AGENT.md` | Operating manual: how to build, run, and not break things | Rationale, roadmap |
| `STANDARDS.md` | These rules, and the procedures that enforce them | Design decisions |
| `LESSONS.md` | The catalogue of failure *shapes* — how things go wrong here, with the instance and the guard | A single defect's history, which is `PLAN.md`'s |
| `README.md` | What the thing is and how to use it | Anything internal |

**Reasoning does not go in commit messages.** A commit says *what changed*; `PLAN.md` says *why
it is right*.

**`LESSONS.md` is cited by number and never renumbered.** Code comments and the other documents
refer to a shape by its number, so the numbering is an interface. A shape that turns out to be
wrong keeps its heading and has its body corrected, the way a retracted finding does. The split
from `PLAN.md` is a recurrence test: **one defect belongs in `PLAN.md`; the second instance of the
same mistake belongs in `LESSONS.md`.**

Code comments carry a sixth job: **invariants and the defects that produced them.** A comment
explaining what a line does is noise; a comment explaining what breaks if the line changes is the
most valuable text in the file.

---

## 1. Architecture

**R1.1 — Anything analysable lives where it can be tested.** Draw the boundary so the logic
worth verifying sits in modules that run under the test runner with no I/O, no hardware and no
UI. Logic in the outermost layer cannot be tested and has repeatedly turned out to be wrong.

> Watch for this rule calcifying. "Testable" is easily allowed to mean "pure", and everything
> else falls off the edge — including code that is neither pure nor hardware-bound and could have
> been tested all along.

**R1.2 — One implementation of anything measured or decided.** Two surfaces must call the same
function, never two copies. Duplicated logic drifts, and then the same operation means different
things depending on where it was started.

**R1.3 — Core modules perform no I/O.** No printing, no file access, no reading the clock in
logic paths. Time is a parameter, never a side effect; anything that reads the clock cannot be
tested.

**R1.4 — Independence between peer modules is worth a little duplication.** A small shared helper
is not worth a dependency edge that couples two things that should be able to move separately.

**R1.5 — All randomness is seeded, and identical inputs produce identical outputs.** If a result
cannot be reproduced from stored inputs, it is not a result. Beware hashes that are salted per
process — they look deterministic and are not.

---

## 2. Integrity of derived numbers

*Delete this section if the project does not produce numbers anybody acts on. Keep all of it if
it does.*

The system exists to tell someone something true. **A confident wrong number is worse than an
honest gap**, and every rule here exists because that failed once.

**R2.1 — Raw inputs are stored; everything recomputes from them.** Cached summaries may exist for
legibility. **Nothing reads them back.** Enforce it in the gate.

> Violated three times before it was enforced, and each violation shipped. A fix to the analysis
> must reach data recorded before the fix — that is the whole point.

**R2.2 — Point estimates carry uncertainty**, and any comparison says whether the difference is
real or within noise. Using the wrong uncertainty method is a defect, not a preference: match it
to the shape of the data, and write the mapping down.

> Resampling within groups while never resampling the groups leaves each group's mean frozen in
> every iteration, so the interval is blind to between-group variation — which is usually most of
> the variation. This shipped for three milestones.

**R2.3 — A group of one gets no interval.** Say why the number is missing.

**R2.4 — When a value cannot be trusted, withhold it at source.** Return nothing from the
analysis; do not return the number beside a boolean and expect every caller to check it.

> A value derived in three places was built as a flag. Two callers checked it, one did not, and
> the third was found only because a trend that should have moved did not.

**R2.5 — Confounds are named, never blended.** A group mixing conditions says so at the point of
display, and every surface warns identically.

**R2.6 — Parameters that feed a trend are locked.** Every confound in a dataset arrives by a
parameter changing between measurements. If exactly one thing is allowed to vary, say which.

**R2.7 — Check that a derived unit is comparable across the range you vary.** A ratio, a
percentage or a normalised score can be perfectly sensible at one end of an axis and meaningless
at the other, and the failure is invisible because the numbers stay plausible.

> A ratio whose sensitivity to its input runs from 4× to 16× across the useful range would have
> reported identical steadiness as a quadrupling error, making a player look worse for improving.

**R2.8 — A stopping rule is declared before collection starts.** Recomputing after every new
observation is optional stopping, and optional stopping plus resampling eventually manufactures a
result. Declare the target up front and compute no verdict below it.

**R2.9 — Exclusions are declared before collection, never after.** A condition marked up front is
data. The same mark applied afterwards is choosing which results to keep.

---

## 3. Real-time and hardware paths

*Delete unless the project has one.*

**R3.1 — One clock is the timing authority**, and it is the one closest to the hardware. Never a
general-purpose timer for anything that must be sample- or frame-accurate.

**R3.2 — Positions come from index arithmetic, never from accumulating an interval.** Accumulation
drifts; a test should prove index arithmetic does not.

**R3.3 — Nothing in a real-time callback may allocate, lock, log, or touch a managed runtime.**
Violating this produces artefacts that look like the input rather than like a bug, which is the
worst available failure mode.

**R3.4 — Cross-thread communication into the real-time path is lock-free.**

---

## 4. Style

**R4.1 — Pin the toolchain and say so.** Do not reach for features the pinned version lacks.

**R4.2 — Line length, indentation, trailing whitespace, newline at EOF.** Enforced, not discussed.
Prefer a formatter to prose; where there is no formatter, enforce it in the gate.

**R4.3 — Access control is explicit and minimal.** A public symbol is a commitment.

**R4.4 — Doc comments on every public symbol**, stating what it does and any constraint on its
input. Units belong in the name or the comment, always.

**R4.5 — No unchecked unwrapping or ignored errors in shipped code.** Where a value cannot be
absent, prove it. Tests may fail loudly.

**R4.6 — Errors are propagated, not printed.** The outermost layer decides how to show them.

**R4.7 — No warnings.** The build is clean and stays clean.

**R4.8 — Comment what breaks, not what happens.** Prefer "an event one bar early inverts what this
measures" over "adds an event".

**R4.9 — One name, one meaning.** If a word means two things in the codebase, rename one of them
before the ambiguity spreads.

> "How finely we divide the beat" had two legitimate meanings in one project and produced four
> separate defects across a single milestone before the names were forced apart.

**R4.10 — Make the illegal state unrepresentable before you validate against it.** A precondition
runs where it is called; a type holds everywhere. Prefer one optional value to two optional fields
that can disagree, and a closed set to a parameter that accepts anything.

> Two fields, `style` and `seed`, were specified with an initialiser refusing the half-set case.
> The type was `Codable`, so a stored file was *decoded* rather than constructed, the initialiser
> never ran, and a half-set record would have decoded into something unreplayable. One optional
> value made it unrepresentable at no cost.
>
> Separately, four entry points took any `([Double]) -> Double` and one statistic was invalid for
> them. Removing the callers fixed the instances and left the *spelling* available; a closed
> two-case enum removed it. That refactor also surfaced a fifth call site a grep had missed.

**R4.11 — A decision that cannot be reached by a test does not belong inside something untestable.**
Anything inside a function that opens a device, writes files, blocks on input or waits on a network
call is a decision nobody can check. Lift it into a property or a small function and call that.

> The commonest defect shape in the parent project, by a distance. A drill's configuration was
> assembled inside the function that opened the audio device, so a missing field could only have
> been found by playing a take through the speakers — and was not, for a milestone.

**R4.12 — Inject what the code needs to be checked against.** A collection read from a global, a
clock read from the system, a library looked up by name: each makes one branch untestable. Take
them as parameters with sensible defaults, so production reads the default and a test supplies the
case that matters.

> A guard refusing unapproved items became unreachable the day every item was approved — the
> branch still existed and nothing could enter it. The next item added would have landed unguarded.
> The fix was one parameter with a default.

**R4.13 — A comment that states a number states where it came from.** "50 ms, two cycles of the
lowest note the instrument sounds" survives a reader asking why; "50 ms" invites someone to round
it. Derive the constant in code where the derivation is cheap.

**R4.14 — Reach for the standard library and the platform before writing your own.** A dependency
is code you did not read running with your privileges (§7); a hand-rolled utility is code you did
write and will maintain. Neither is free — the point is that both are a decision, and the second
one gets made by accident.

---

## 5. Testing

**R5.1 — Every analysable behaviour has a test against data of known ground truth.** Planting a
known answer and recovering it is the only acceptable proof for a derived value.

**R5.2 — Test names state the claim.** `testBetweenGroupDifferencesDoNotLeakIntoTheWithinSlope`,
not `testSlope2`. The name is the specification.

**R5.3 — Test the failure the code exists to prevent.** For every rule with a "this went wrong
once" story, there is a test that fails if the fix is reverted — and you have checked that it
does by reverting it.

**R5.4 — Tests are deterministic.** Seeded generators only. A flaky test is fixed or deleted the
day it flakes.

**R5.5 — The path under test must be the path that ships.** Before writing a test, ask what
production code calls the thing you are about to assert on. If the answer is "nothing", you are
about to test a copy.

> The single most common defect shape in practice. See `LESSONS.md`.

**R5.6 — A guard is verified by making it fail.** Add the rule, plant a violation, watch it
report failure, remove the violation, watch it pass. **Reading the rule is not verification.**

> A pattern that looked correct matched nothing at all, and two rounds of checking at the shell
> missed it because the shell and the script disagreed. Only planting a violation found it.

**R5.7 — A test that compares the system against itself proves nothing.** Assert against values
stated independently — written longhand, computed by hand, or captured before the change.

**R5.8 — Test the case where the behaviour is observable.** A test that only exercises the easy
configuration passes while the hard one is broken.

**R5.9 — Every stored type has a round-trip test**: save, reload, recompute, and require the
result not to move. Add it with the type, not after the first record is lost.

**R5.10 — Hardware and integration paths are verified by a live run**, and the result is recorded
in `PLAN.md`. Pretending otherwise is worse than admitting the gap.

**R5.11 — Tests never touch real user data.** Redirect storage to a temporary location, assert the
redirect is live before the first write, and have the gate fail if anything outside the test tree
disables it.

---

## 6. Data and schema

**R6.1 — Schema changes are additive.** New fields are optional. Everything ever recorded must
continue to load, verified by a command the gate runs.

**R6.2 — Never delete or rewrite stored records.** They are primary data.

**R6.3 — Record what a future question will need, before the analysis exists.** A record written
without a field is lost to that question for good, and the cost of the field is bytes.

> The exception worth knowing: if the absent value has a true *identity* — a default that is
> genuinely what every existing record was — then adding it later loses nothing. Be certain the
> default is the identity and not merely common.

**R6.4 — Absent is not the same as default.** Decide explicitly which optional fields mean "not
recorded" and which mean "the neutral value", and write the distinction next to the field.

**R6.5 — Load failures are reported, never swallowed.** Silently dropping unreadable records is
how a schema change quietly erases history.

**R6.6 — A type that cannot check its own consistency will trap on read.** Serialisation proves
fields decoded; it cannot prove parallel collections describe the same thing. Validate on load and
surface the file by name.

---

## 7. Security and privacy

**R7.1 — State the network posture and enforce it.** If the project is local-only, the gate fails
on network imports.

**R7.2 — Dependencies are a decision, recorded.** Every dependency is code you did not read
running with your privileges.

**R7.3 — No secrets in the repository**, including in fixtures. The gate scans for key shapes.

**R7.4 — User data lives outside the repository** and is never committed.

**R7.5 — Untrusted input is validated at the boundary**, before anything acts on it.

**R7.6 — Commits are signed.**

---

## 8. Version control

### 8.1 Branching

`main` is always green — the gate passes at every commit.

**The branch is the unit of work.** It is what gets planned, reviewed, rolled out and documented;
commits are the steps inside it. Getting this backwards — treating the commit as the unit and the
branch as a wrapper — produces a review queue nobody can hold in their head and a history that
reads as though nothing was ever planned.

> Worth stating because it is the rule most likely to be ignored while being agreed with. In the
> parent project it was written down from the start and broken **nine times running** before
> anything enforced it. It read as advice, and advice is what a productive afternoon ignores.

#### 8.1.1 Planning a branch

Before the first commit, decide three things and write them in the request body as you go:

1. **What whole thing this branch delivers.** Not "the next change" — a capability, a defect and
   the guard that closes it, a format and the two things that prove it, one milestone step. If it
   cannot be said in a sentence without "and also", it is two branches.
2. **The commits it will take, in order.** Two to six is the usual shape. Each is one logical
   change, each leaves the gate green, and each is separately revertible.
3. **How it lands without breaking anything** — 8.1.2.

**Too small**: the branch subject and the request title are the same sentence; the only thing in
"what this does not cover" is the rest of the same idea; the next branch has to start by explaining
this one.

**Too large**: a reviewer cannot hold the argument in one sitting; the commits stop being
separately revertible; the branch has been open long enough that `main` has moved underneath it.

Name it `<type>/<short-description>` using the same types as 8.2, and name it for the *work* rather
than for the first commit.

**One commit is a declared exception, not a default.** A retraction, a one-file fix, a lone
dependency bump. Make declaring it an explicit act — a flag on the tool that opens the request is
enough, and it is what turns "I meant this" into a decision rather than an accident.

#### 8.1.2 Rollout

**Every merge is a state the repository could sit in indefinitely.** Not merely green: a branch may
not leave a half-built capability reachable from a surface a user touches, and it may not leave
stored data in a shape nothing can read back.

Work that cannot land in one safe piece lands in several, in this order:

| Order | Lands | Why first |
|---|---|---|
| 1 | **Storage and identity** — new fields, optional, written by nothing | A record written without a field is lost to that question for good; an unused optional breaks nothing |
| 2 | **Analysis and grouping** — how the new data will be read | It has to be right *before* data exists, or the first records are interpreted by a rule that then changes |
| 3 | **The mechanism** — the thing that produces the data | Everything downstream of it already handles it |
| 4 | **The surfaces** — the least public first | Last, because a surface is what makes it reachable |

Three rules for the parts that cannot be finished:

- **Gate rather than hide.** An unfinished capability is reachable only behind an explicit flag
  whose default is the safe answer. A capability that is merely undocumented is not gated.
- **State the gate in the request.** "What this does not cover" is a required section: what is
  unreachable, and what turns it on.
- **Never leave a measurement half-wired.** A path that records data under a description it did not
  perform is worse than one that does not exist. Either the whole path is honest, or none of it
  ships.

**Rolling back is part of planning it.** Each commit is separately revertible; state in the request
what reverting the branch would cost — usually nothing, sometimes stored records that would no
longer load, which is the case the schema rules exist to prevent arising.

#### 8.1.3 Review and merge

The verification pipeline runs on the request and must be green before merge.

Self-review is still review: read the diff in the request view before merging — it catches things
the editor does not. Merge with a merge commit, not a squash; the commits are already one logical
change each and squashing destroys that.

**Delete the branch once it is merged.** A merged branch that still exists reads as work still in
flight, and a few dozen of them make the branch list unusable. Prefer a script that lists what is
fully merged and deletes only on an explicit flag, using the safe delete that refuses anything
unmerged.

**Use the tool that opens the request, every time — never a bare push.** Whether a request is
already open is a fact about the server, and a remote-tracking ref is a cache, not the remote. A
merged request is closed, so a push after it lands leaves nothing pending and the next one has to
be opened by hand.

### 8.2 Commit format

```
<type>(<scope>): <subject>

<body — what changed, imperative, wrapped at 72>

Refs: PLAN.md §<n>
```

**Types:** `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `chore`.

- Subject: imperative, no trailing period, within the limit the hook enforces.
- Body: what changed and any consequence a reader needs. **No rationale essays** — the argument
  belongs in `PLAN.md`, and `Refs:` points at it.
- One logical change per commit.
- A `fix:` body states the observable symptom in one line.
- Never mention tooling or how the change was produced.

Enforced by a `commit-msg` hook. **Run the hook against the message file before handing over** —
it takes a path and exits non-zero, so checking costs nothing and eyeballing line lengths does
not work. Note whether the hook measures characters or bytes: an em-dash or an arrow costs three
against a byte limit, so wrap short rather than counting.

#### The shape of a body

Pick one commit as the house reference and read it before writing one. The shape that works:

- **Prose paragraphs, never bullet lists.** One paragraph per distinct part of the change.
- **Open with the symptom, in the past tense, as something that happened** — not with the
  mechanism, and not with "this commit". *"The message file kept its contents after the commit that
  used it, so the next change inherited a message describing the previous one."*
- **Back it with the instance and its evidence, immediately.** A body that could have been written
  before the work was done is too abstract.
- **Then the mechanism, plainly**, including the one implementation detail a reader would otherwise
  wonder about, and why it is that way.
- **Every later paragraph names its part and carries its own justification**, so a reader can stop
  at any paragraph boundary and have a whole thought.
- **Close on the cost that motivated it**, measured.

The rule against rationale essays still binds. The argument for *why the design is right* lives in
the reasoning document; what belongs here is the symptom, the mechanism, and what it cost — the
things a reader needs when the log is the only thing in front of them.

#### More than one commit, which is the normal case

A `-F` commit reads the whole file, so several messages cannot share one. A branch landing as three
commits has three numbered message files, in the order they will be committed. Each holds one
message and nothing else — no staging commands, no separators, nothing that would end up in the log
if the file were used as-is.

Write each one **when its commit is ready**, not all up front: a message you cannot write yet is a
commit whose boundary you have not found. If two of them say nearly the same thing, the split is
not real. If one needs "and also", it is two.

A handful of message files is the shape of a well-planned branch. A single file on a branch that
took a week is the warning sign.

#### Request bodies

Different job, different form. A commit message is read in a terminal beside forty others; a request
body is read once, in a browser, by someone deciding whether the change is safe. So a request body
**is** rich markup — headings, tables, bold — where a commit message is plain prose.

- **Title**: what the *branch* delivers, which on a multi-commit branch is not any one commit's
  subject.
- **What this is** — one paragraph, then a stat line: commits, files, lines, tests before and after.
- **How this lands** on anything arriving in stages — the commits in order, what each leaves
  reachable, what stays gated (8.1.2).
- **The defect, then what it reported, then why the tests did not catch it.** Before-and-after in a
  table with the wrong numbers in bold. Quote the readout's own words where they are the tell.
- **The fix and its guard**, naming what fails if the fix is reverted.
- **What the data says now**, with the limits stated at least as loudly as the result.
- **Review notes** last: the gate's output, what is unchanged against what changed and why that is
  correct, what reverting would cost, and what the change still does not cover.

Write it in the same gitignored scratch area as the commit messages, for the same reason.

### 8.3 The rolling commit message

A gitignored scratch file always holds the message for whatever is uncommitted.

- Write it as soon as there is something to commit. A message you cannot write yet is a change you
  cannot describe, which usually means it is two changes.
- Update it whenever the tree changes. A stale message is worse than none, because it will be used.
- A `post-commit` hook empties it once that message lands.
- Commit with `-F` so the file that was reviewed is the message that lands.

### 8.4 One branch at a time, and where the documentation goes

**Take a branch all the way to merge-ready before starting the next.** Merge-ready means 8.5.

**Within a branch, the documentation lands with the commit that completes it, not with each
commit.** That is what makes a multi-commit branch practical: the reasoning and operating documents
are touched by nearly every change, so documenting each commit separately puts several changes'
edits in one file and no staging command can separate them. Documenting the *branch* once, at the
end, is one coherent set of edits describing one coherent piece of work.

The code commits before it stay green and separately revertible; what they do not carry is prose
about something unfinished.

The mechanical reason is not obvious until it bites. Do two *branches* before merging either and
both sets of documentation edits sit in the same files, at which point neither can be staged
without the other, and splitting them means hunk surgery or writing documentation out and back in.

**Plan the commits so they do not share files.** A branch whose commits touch disjoint paths stages
with one `add` per commit and no surgery at all. Where two pieces genuinely cannot be separated by
file — a fix and the readout that would otherwise contradict it — they are one commit, and the
message says why.

### 8.5 Definition of done

1. The gate passes.
2. New behaviour has tests that would fail without it — verified by reverting.
3. Any hardware or integration path is exercised by a live run, or the gap is stated explicitly.
4. **Documentation is level with the code — a closing step, every time.** Walk all five documents
   and correct anything the change made untrue — `LESSONS.md` only when the change was the second
   instance of a failure shape, or a new one. Counts and figures quoted in prose are claims like
   any other: re-derive them rather than trusting the previous value, and prefer writing claims
   the gate can check over claims only discipline can.
5. The rolling commit message describes exactly what is about to be committed.
6. The request body makes the argument for the branch as a whole, including how it rolls out and
   what it deliberately leaves unreachable (8.1.2).
7. The branch is a coherent piece of work rather than one change with a branch around it (8.1.1).
   If it is genuinely one commit, that judgement is recorded rather than assumed.

---

## 9. Procedures

### 9.1 Before every commit
Run the gate. Run the commit-message hook against the message file.

### 9.2 After changing analysis or core logic
Run whatever end-to-end self-check exists against known ground truth. If it passes and a live run
fails, the fault is the environment rather than the logic — that separation is why it exists.

### 9.3 After changing storage
Load every historical record. The command must exit non-zero on failure, and the gate must read
that status.

### 9.4 Adding a capability
1. Analysable logic → a testable module, with tests against planted ground truth.
2. One implementation of anything measured or decided.
3. User-facing text generated from the configuration that will actually run.
4. Every surface, or a stated gap.
5. `PLAN.md` section; `README.md` if user-facing; `AGENT.md` if procedure changed.

### 9.5 Recording a finding
Findings go in `PLAN.md` with the numbers that support them, the sample size, and what would
falsify them. **A finding without a sample size is an anecdote.**

### 9.6 Reviewing the codebase
Worth doing before any milestone that builds on everything underneath it. Look for the shapes in
`LESSONS.md` specifically, not for "code smells". Record the findings with a fix order, and mark
them off as they land — a review whose findings are not tracked is a document nobody acts on.

> One such pass found eleven issues, none of them a crash or a broken build. Four were the
> *enforcement* being fake rather than the code being wrong.

### 9.7 The working itinerary

`temp/WORKING.md` — or wherever the project keeps it — is the scratch pad: **gitignored on purpose,
and blunt on purpose.** It holds what is in flight, what just landed, what comes next, and the
questions waiting on an answer, so a session can start without asking for direction and someone
arriving cold can see the state of play in one read.

Being outside the repository is what lets it be useful. It can name a half-formed idea, an
unattractive option, or a doubt about work already merged. **Nothing in the tracked documents may
depend on it**, and anything that turns out to matter is moved into the reasoning document in the
form that belongs there. The public record stays professional; the scratch pad is where the thinking
is allowed to be untidy.

**Rolled forward, not archived.** As a milestone closes, its finished items come out and the work
between milestones goes in, so that by the time a milestone is done the next one already has a plan.
A file still listing last milestone's steps is stale, and stale is worse than empty — the next
reader acts on it.

### 9.8 Keeping the templates current

These templates are where a repository's rules become reusable somewhere else. They drift the moment
a rule changes in the project and nobody carries it across.

**When the standards, the failure-shape catalogue or the operating manual changes materially, update
the template in the same branch.** Materially means a rule added, removed or reversed; a new failure
shape; a change to the document map or the procedures. Not a corrected figure, not a reworded
sentence.

Generalise rather than copy: the rule travels, the project's own instances stay behind. The
failure-shape catalogue is the model — the same shapes, with the specifics stripped out.

> This is the one procedure with no gate behind it, since the templates live outside the tree a gate
> can see. Until they have a repository of their own it is enforced by whoever is reading it, and
> saying so is better than implying a guard that does not exist.

