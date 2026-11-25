---
name: concord:plan
description: Draft an editable PLAN_<ticket>.md for a code change - scope, design, Test plan, phases with their dependencies, file scope, and acceptance checks that tell the intended change from broken code - and return the draft. Use it when someone asks for a plan or wants a task scoped before code is written, and as the planning step of /concord:run; the draft can be edited, verified with /concord:verify-plan, or passed to /concord:run execute or /concord:run delegate.
argument-hint: <task> [execute|delegate]
---

# Plan

A plan is ready when an implementer who never saw this conversation can deliver each phase, and when each phase's acceptance tells the intended change from plausible wrong work. It is written to be edited: the owner reads it, changes it and passes it on.

Read only until you can name the files, the callers and the acceptance commands: the repository notes (`~/.claude/concord/repo-notes/<repo>.md`), the code, the spec or design the task names, the `Cases:` file the notes name, and the skills that fit; no edits. Leave what you read as `Notes:` pointers, so an executor does not search again. Load `concord:design-review`: each consequential choice it finds goes under `## Open questions` with the default you would take. Load `concord:lean-testing` for the Test plan. Cut every item the goal does not need. A routine or trivial task needs no plan: say so.

Write `PLAN_<ticket>.md` early, on one page, at the repository root in the format of `~/.claude/concord/PLAN_TEMPLATE.md`, whose notes give the rules for each field (never `PLAN.md`; ask before overwriting). Keep it out of git: if `git check-ignore -q PLAN_<ticket>.md` fails, add `/PLAN_*.md` to `$(git rev-parse --git-common-dir)/info/exclude`.

- Phases: each one coherent change with its `Files:`, steps, `Risk:`, `Size:` and acceptance; `After: <phase> (<reason>)` only for a real wait (a phase waits for the tests it runs; phases that share a file wait or take forks). No minutes: `concord.py --estimate` computes them.
- Implementer: the mode decides `Executor:` before the plan is verified, so the approved plan names who writes each phase. Execute: `planner` on every phase. Delegate: `planner` for what costs less to write than to specify, code it already wrote while testing, the failing tests and docs; the cheapest capable executor in models.conf for bulky, well-specified work, cheapest tier first; all out → the fallback `implementer-opus48`, said in one line; paid executors only after asking. No mode given: ask.
- Acceptance: commands that fail on the current code and pass only on the intended change; one that must stay red until a later phase is marked `(fails until Phase <N>)`.

## Result

The draft's path, or that the task needs no plan; the open questions, each with its default; one line per phase (executor, risk, waits); what you cut. Return the draft to the caller: verification, approval and implementation belong to `/concord:verify-plan` and `/concord:run`.
