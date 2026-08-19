# Guidelines & Standards — a reusable baseline

A working setup for solo projects with an AI collaborator, extracted from a project where it
has been load-bearing for fourteen milestones. Nothing here is theory: every rule exists because
something went wrong once, and the story is usually attached.

## The six files

| File | Job | Copy into a project? |
|---|---|---|
| `README.md` | This. How to adopt the kit. | No |
| `PREFERENCES.md` | How **I** want to be worked with. Stable across projects. | No — keep one copy, point at it |
| `STANDARDS.md` | Binding engineering rules and the procedures that enforce them. | **Yes**, then delete what does not apply |
| `AGENT.md` | The operating manual template — how to build, run, and not break things. | **Yes**, fill the placeholders |
| `PLAN.md` | The reasoning document template — design, rationale, findings, roadmap. | **Yes**, start it before the code |
| `LESSONS.md` | A catalogue of recurring failure *shapes*, each with a real instance. | **Yes** — copy it, then replace the anonymised instances with the project's own as they happen |

## The five-document model

Every project gets exactly five documents, and **putting content in the wrong one is a defect**:

| Document | Holds | Does not hold |
|---|---|---|
| `PLAN.md` | Design, rationale, findings, measured results, roadmap. **The reasoning lives here.** | Procedure, style |
| `AGENT.md` | Operating manual: how to build, run, and not break things | Rationale, roadmap |
| `STANDARDS.md` | The rules, and the procedures that enforce them | Design decisions |
| `LESSONS.md` | The catalogue of failure *shapes* — how things go wrong here, with the instance and the guard | A single defect's history, which is `PLAN.md`'s |
| `README.md` | What the thing is and how to use it | Anything internal |

Why five and not one: each has a different reader and a different decay rate. `README.md` is
read once by a stranger. `AGENT.md` is read at the start of every working session. `STANDARDS.md`
is read before writing code and rarely changes. `PLAN.md` is where an argument goes so it can be
found later instead of being re-litigated — and it is the one that must stay current, because
everything else points at it.

A fifth document is a smell. If something does not fit, it is usually a `PLAN.md` section.

**Reasoning does not go in commit messages.** A commit says *what changed*; `PLAN.md` says *why
it is right*. A reader wanting the argument should find it in one place that stays current, not
scattered across a log nobody re-reads.

Code comments carry a fifth job the documents cannot: **invariants, and the defects that produced
them.** A comment explaining what a line does is noise. A comment explaining what breaks if the
line changes is the most valuable text in the file.

## Adopting it on a new project

Order matters. Steps 1–3 happen before the first line of code.

1. **Copy `STANDARDS.md`.** Delete every rule that does not apply. Keep the numbering of what
   remains — the numbers get cited in commits, comments and reviews, and renumbering breaks that.
2. **Write `PLAN.md` §1–3**: what you are actually building, the principles that are
   non-negotiable, and the architecture. Do not write milestones yet.
3. **Copy `AGENT.md`** and fill the environment constraints. Even a nearly empty one is worth
   having, because "what can this machine not do" is the thing most often assumed wrong.
4. **Build the gate before the second commit.** A single script that must pass before every
   commit, wired to a pre-commit hook. It starts small — build, tests, formatting — and grows a
   rule every time something slips through. **A standard without a gate is a wish**, and this is
   the single highest-leverage item in the kit.
5. **Add milestones to `PLAN.md`**, ordered by *risk*, not visibility. The first should de-risk
   the thing that would invalidate everything else if it turned out to be wrong.
6. Point the agent at `PREFERENCES.md` once, from `AGENT.md`.

## What to strip

The templates carry examples from a measurement-heavy Swift project. Strip aggressively:

- **Real-time and audio rules** unless you have a hard-real-time path.
- **Measurement-integrity rules** (uncertainty, confounds, bootstraps) unless the project
  produces numbers somebody will act on. If it does, keep all of them — they are the most
  expensive section to learn the hard way.
- **Language-specific style rules.** Replace with whatever your formatter enforces, and prefer
  the formatter to the prose.

What to keep in almost every case: the document model, the testing rules, version control,
definition of done, and the whole of `LESSONS.md`.

## The one-line version of each

- Write down why, once, where it stays current.
- Enforce what you can, and say plainly what you cannot.
- A confident wrong answer is worse than an honest gap.
- Verify a guard by making it fail, not by reading it.
- The path under test must be the path that ships.
- Finish one change before starting the next.
