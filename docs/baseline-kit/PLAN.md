# [Project] — design & build plan

> **Template.** This is the document that must stay current, because everything else points at
> it. Sections 1–5 are written before the code and revised rarely. Section 7 grows forever and
> is where the project actually lives.
>
> The habit that makes this work: **every change adds or corrects a section here before it is
> committed.** A plan updated in arrears becomes a history book, and history books do not get
> read before decisions.

[Target environment, hardware, versions — the facts that constrain everything below.]

---

## 1. What we are actually building

[The problem in the user's own words, quoted. Then what is really going on underneath it, which
is usually not what the words say.]

[The reframe — the sentence that changes what gets built. If there isn't one yet, the project is
not ready to start.]

**So the goal is [X], not [the obvious misreading of X].**

This has hard consequences for the design:

1. **[Consequence]** — [and why it follows]
2. **[Consequence]**

---

## 2. Design principles (non-negotiable)

[Five to eight. Each is a rule that will be inconvenient at some point, and the point of writing
it here is that it survives the inconvenience. Each gets its reason.]

- **[Principle.]** [Why. What breaks without it.]

---

## 3. Architecture

[The spine — the one or two technical problems everything else rests on, and how they are
solved. If there is a highest-risk piece, name it and say it gets built first.]

### 3.1 [The hard problem]

[What makes it hard, the approach, and how you will know it worked.]

---

## 4. [Calibration / setup / whatever must be right before measuring]

[Anything that must be established before the system's output means anything. Include what is
being measured versus what is being controlled for — conflating those is a classic.]

---

## 5. The metrics [if the project produces numbers]

| Metric | Meaning | Why it matters here |
|---|---|---|
| [name] | [what it is] | [what decision it informs] |

### 5.1 [The one metric that matters most]

[Why. What it distinguishes that nothing else does.]

### 5.2 Traps

[Every known way to compute these wrongly. Write them down before building — most will be
rediscovered the hard way otherwise.]

---

## 6. [First substantial capability]

[Design of the thing that will be used first, in enough detail to build.]

---

## 7. Milestones

Ordered by **risk, not visibility.** The first should de-risk whatever would invalidate the rest.

| # | Milestone | Proves / delivers |
|---|---|---|
| **M0** | [the de-risking spike] | [what it proves. Do not skip it.] |
| M1 | [next] | ✅ Done. [one line]. See §7.1. |

Non-capability work gets a separate letter — `T1`, `T2` — because "what the project can verify
about itself" is a different axis from "what it can do", and numbering it into the M-sequence
implies an ordering that is not true.

---

## 7.1 M0 — measured results

[Every milestone gets an "as built" subsection. Not a summary of the code — a record of:]

- **What was decided and why**, especially where the obvious choice was rejected.
- **What was measured**, with numbers and sample sizes.
- **What went wrong**, with the number it produced. These are the most re-read paragraphs in the
  whole document.
- **What is not verified**, stated plainly.

[Write these *as* the work lands, not at the end. The reasoning is available then and gone later.]

### [A defect worth recording]

[The shape, the instance, the number it produced, and the guard now in place. If the fix changed
no output, say so and say why — "the fix changed nothing" reads as evidence it was unnecessary
and usually is not.]

---

## 7.n Roadmap

[Each future milestone gets a paragraph now: what it delivers, what it depends on, and what it is
blocked by. Written early and revised often — a roadmap entry is where you discover that a
milestone is really two, or that it cannot be built at all yet.]

### M[n] — [name]
[What. Why now. What it depends on. **What would make this unbuildable**, if anything.]

---

## 8. Project layout

```
[tree, with one line per module saying what makes it separate]
```

[The one duplication that is deliberate, and why.]

---

## 9. Status of open questions

**Resolved:**

1. **[Question]** — [answer, and what settled it].

**Still open:**

2. **[Question]** — [what it blocks, and what would answer it].

---

## 10. What success looks like

[Not the metric target. The thing that would make the effort worth it, in the user's terms.]

- [Observable outcome]
- And the one that actually matters: [the subjective thing the whole project is for].
