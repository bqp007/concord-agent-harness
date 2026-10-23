---
description: Investigate a task, write a one-page PLAN_<ticket>.md (per phase an executor, risk, files, steps and acceptance commands), settle open questions, wait for approval, then run every phase as /concord:delegate all would
argument-hint: <task description>
---
Plan for: $ARGUMENTS. Chat: terse (tables for numbers). Plan text, commands, code: full.

1. Check: this session runs on the strongest model available at high effort, else say so and ask. A code ticket not in its worktree → `python3 ~/.claude/concord/wt.py new <TICKET>` + `EnterWorktree` (`wt.py list` shows OVERLAP / DRIFT).
2. Investigate cheaply: `~/.claude/concord/repo-notes/<repo>.md`, then targeted reads (grep, the functions, the test runner), no edits. Trivial task → offer a direct edit, no plan. Cut every item the goal does not need.
3. Write `PLAN_<ticket>.md` at the repo root from `~/.claude/concord/PLAN_TEMPLATE.md` (never `PLAN.md`; ask before overwriting). If `git check-ignore -q PLAN_<ticket>.md` fails (a worktree `wt.py new` did not make), add `/PLAN_*.md` to `$(git rev-parse --git-common-dir)/info/exclude`. One page: Done when, Ship, Open questions (every known ambiguity, for the user to settle), the phases. Usually tests by this session, then one run for the code; split only a phase too big for one run. Executors as in CLAUDE.md.
4. Lint each delegated phase once, outside the sandbox: `concord.py --lint <phase> free-deepseek-flash --plan <PLAN> --repo <dir>`. Fix what the ACCEPTANCE LINT lines (zero tokens), FILES and RISKS name; QUESTIONS go to Open questions. No free or Go model left → skip it and say so.
5. Show the phases (executor, risk, files) and the open questions; stop until the user approves. A partial approval covers those phases only.
6. Run the approved phases as `/concord:delegate all` would. When this session's context is already large, hand off: write the plan's `## Handoff` (settled decisions, what the investigation learned), `ExitWorktree keep`, start a fresh session on the planner model in the worktree with `/concord:delegate all --plan PLAN_<ticket>.md`, detach it and end this one (no way to start one → `EnterWorktree` back and run here). A ticket that ships by PR ends at the PR gate (`/concord:delegate` §6).
