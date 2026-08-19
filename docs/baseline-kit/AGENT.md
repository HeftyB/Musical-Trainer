# [Project] — agent guide

> **Template.** Replace everything in `[brackets]`, delete sections that do not apply, and keep
> the section order — it is roughly the order a new session needs them in. Target one screen per
> section. When this file grows past what someone would read at the start of a session, it has
> stopped being an operating manual.

[One or two sentences: what this is, who it is for, and the single most important thing about it.]

Five documents, five jobs — putting content in the wrong one is a defect:

- **[PLAN.md](PLAN.md)** — design, rationale, findings, roadmap. **The reasoning lives here.**
- **[STANDARDS.md](STANDARDS.md)** — binding rules and the procedures that enforce them. Read it
  before writing code.
- **[LESSONS.md](LESSONS.md)** — the failure *shapes* this project has produced, each with its
  instance and its guard. **Read it before any review.** Code comments cite it by number, so the
  numbering is an interface and shapes are never renumbered.
- **AGENT.md** (this file) — the operating manual.
- **[README.md](README.md)** — what the thing is and how to use it.

Working style is in `[path to PREFERENCES.md]` and is not repeated here. The gitignored working
itinerary — what is in flight, what landed, what is next, what waits on an answer — is the first
thing to read at the start of a session (`STANDARDS.md` §9.7).

## Where the project is

**[Milestones done. What is in progress, which step of how many, and where it is planned.]**

| Done | |
|---|---|
| [M0–M2] | [one line each — what capability landed, not what code was written] |

**[Any review or audit section worth reading before trusting a number here, and why.]**

**[What has never been exercised for real.]** [The specific thing to watch on the next live run.
This is the highest-value line in the file when it is accurate and actively harmful when it is
stale.]

## Surfaces

[Every way a human drives this, and which one is authoritative. Name the shared layer both go
through so nobody adds a second implementation.]

## Environment constraints — check these before proposing a solution

[The things a solution can assume, stated as prohibitions. Examples of the shape:]

- **No [container runtime] on this workstation.** [Where that work happens instead.]
- **[Self-hosted git], not [GitHub].** [Which CLI tools therefore do not exist.]
- **No [CI runner for the target platform].** [What CI therefore does *not* cover — be precise,
  because a green pipeline that covers less than the local gate is a trap.]
- **Not installed:** [list].
- **[Shell/tool version quirks that break the obvious script].**

## Build, test, run

```sh
[./scripts/check.sh]          # the gate — must pass before every commit
[./scripts/install-hooks.sh]  # once per clone
[build / test / run commands]
```

| Test target | Runs | Covers |
|---|---|---|
| [name] | [everywhere / gate only] | [what] |

[Where shared test helpers live, and the rule about adding new ones there rather than per-file.]

[Any storage-redirection helper tests must use, and the gate rule that enforces it.]

**After changing a stored property on a shared type, clean the build before trusting a failure.**
Test objects compiled against the old layout fail on code that has not changed; the tell is a
diff showing the failing file untouched.

**[The end-to-end self-check, and what it does and does not cover.]** [If it passes and a live
run fails, what that tells you.]

Toolchain is **[pinned version]**. [Why, and that it will not be upgraded.]

## Module boundaries — these matter

```
[module]    [one line: what it holds and what it must never import]
```

[The two or three rules that keep this working, each with the consequence of breaking it.]

## The codebase, in the order data moves through it

[One line of prose tracing the path end to end, then:]

| Stage | Where | What it is |
|---|---|---|
| [stage] | [files] | [what happens, plus any invariant that is easy to break here] |

Types worth knowing before changing anything:

- **`[Type]`** — [what it is, and the thing about it that is not obvious].

## What is not covered, and must be said rather than implied

- **[Paths with no automated coverage.]**
- **[What CI cannot run that the local gate can.]**
- **[Anything built but never exercised for real.]**

## Non-negotiables

[The handful of rules that are architectural rather than stylistic — each with the failure it
prevents, in one line. If a rule here does not have a consequence attached, it belongs in
STANDARDS.md instead.]

## Hard-won invariants

Each of these came from a real bug. Breaking one silently corrupts data.

| Invariant | What happened without it |
|---|---|
| [rule] | [the actual failure, with numbers where there were numbers] |

## [Domain] conventions

[Where data lives, what each record carries, and any convention a newcomer would get wrong.
Include the ones that exist because a question could not be answered retroactively.]

## What the data says [if the project produces data]

[Current as of N records. **Recompute rather than trusting any of this** — and name the commands.]

- **[Finding, with its numbers and its sample size.]** [What it means for how to work.]

[Anything about the user that changes how to talk to them or what to suggest.]

## Procedure

Full rules in [STANDARDS.md](STANDARDS.md); this is the short form.

1. **Branch.**
2. **Work.** [Where analysable logic goes, and the test shape it needs.]
3. **Write the commit message as you go**, in [the rolling scratch file].
4. **Update the documentation — always a closing step.** Walk all four and re-derive any figure
   quoted in prose.
5. **Run the gate** last, and the commit-message hook against the message file.
6. **Hand over.** [Owner] commits and pushes; leave the tree ready and give the exact command.

**Run these to the end before starting the next change** — see STANDARDS.md §8.4 for the
mechanical reason.

[Checklists for the things with more than one moving part, with pointers to STANDARDS.md.]
