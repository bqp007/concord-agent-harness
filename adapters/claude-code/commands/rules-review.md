---
description: Weekly rules review (about 10 minutes) — keep CLAUDE.md, the delegate docs, REVIEW.md and memory within budget; retire closed tickets and dead rules
---
Weekly rules review. Chat: terse. Propose ONE diff; the owner approves before anything changes.

1. Budgets (`wc -l`): ~/.claude/CLAUDE.md ≤ 25 lines; the concord plugin's `commands/delegate.md` ≤ 60 and `commands/plan-then-delegate.md` ≤ 25; ~/.claude/concord/REVIEW.md ≤ 100; each project memory MEMORY.md ≤ 60; feedback memory files ≤ 20 per project. Over budget → merge or retire before anything is added.
2. Closed tickets: every memory note of a ticket that is merged / Done / cancelled → Trash (`~/.Trash/memory-trim-<date>/`), its index line removed; at most 3 lasting lines kept in repo-notes, the code index or a topic file.
3. One fresh read-only agent (Claude subscription) reads CLAUDE.md, the delegate docs, REVIEW.md and the feedback memory, and lists: duplicates (same rule in two homes), contradictions, superseded rules, rules a hook or concord.py already enforces (delete the prose), rules for one repo only (→ repo-notes).
4. Evidence: `python3 ~/.claude/concord/concord.py --stats` — rounds per phase, adopted %, fail causes. A rule that produced no change in a month is a retirement candidate. Skills: `claude -p "/skill-doctor" < /dev/null` (outside the sandbox); a plugin unused for a month → propose disabling it. Ledgers: in each repo's main checkout read `.git/concord/ledger/*.json` (worktrees share it); the same kind of defect adopted in two or more tickets (judged from the `problem` text, for example an unbounded input or a missing timeout) → propose a test, lint or hookify rule for it; report how many entries have status `adopted` and severity BLOCKER, HIGH or MEDIUM (the evidence for choosing reviewers per tier).
5. Output: a table (rule → keep / merge into X / move to Y / retire, with the reason) and the one diff. Nothing is hard-deleted; never touch another session's files.
