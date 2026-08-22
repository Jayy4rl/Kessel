# DEVELOPMENT-LOG.md — Implementation Log

Running, dated record of implementation work on Kessel. This is a log, not a spec — `docs/PRD.md` remains the source of truth for protocol behavior, `docs/DECISIONS.md` for resolved/open decisions, `docs/CONSTRAINTS.md` for requirements/invariants, and `docs/OPEN-QUESTIONS.md` for what still needs human review. Entries here should reference those files rather than restate them.

**No entries yet.** This file is currently just the template below, created ahead of implementation per the control-document setup pass on 2026-08-22.

---

## How to add an entry

Add one entry per meaningful unit of work (a session, a PR, a milestone) — not per commit. Newest entry at the top. Use this structure:

```markdown
## YYYY-MM-DD — <short title>

**Scope:** what part of the system this entry covers (e.g., "Fast Lane fee computation skeleton," "Slow-Lane intake + custody").

**Summary:** 2-5 sentences on what was done and why.

**Decisions made or updated:**
- Reference the DD-N and link to the entry updated in `docs/DECISIONS.md`, or state "none."
- Do not describe a decision here without also updating `docs/DECISIONS.md` — this log is a narrative, that file is the record of truth for status.

**Constraints discovered or clarified:**
- Anything learned about `docs/CONSTRAINTS.md` items during implementation that wasn't obvious from the PRD alone (e.g., a v4 API detail, a gas-cost finding, a test that revealed an edge case). Update `docs/CONSTRAINTS.md` if the constraint itself needed correcting or sharpening, and note that here.

**Risks / concerns identified:**
- New risks not already tracked, or updates to known risks (e.g., in `docs/OPEN-QUESTIONS.md` §3-4). Include severity and whether it blocks further work.

**Tests added / run:**
- What was tested, against which invariant(s) (I1–I12) or scenario(s) (PRD §15), and the result. Note any invariant that is *not yet* testable because its dependent DD is unresolved.

**Items requiring human review:**
- Anything that surfaced a new open question, or that depends on an existing one in `docs/OPEN-QUESTIONS.md`. Link the relevant DD-N or add a new numbered item there if it's genuinely new — don't silently resolve it here.

**Next steps:**
- What this entry's work unblocks or should be picked up next.
```

---

## Log

_(empty — first real entry goes above this line, newest first)_
