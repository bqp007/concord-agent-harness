---
description: Run a ticket in one of two modes - execute (this session writes every phase) or delegate (each phase goes to the implementer the plan assigns) - from a task or an existing plan; plan, verify, approve, implement, check, review, report
argument-hint: <execute|delegate> [--plan PLAN_<ticket>.md] [model] [phases] [feedback|escalate] [task]
---
Mode and input: $ARGUMENTS. `execute`: this session writes every phase. `delegate`: each phase goes to the implementer the approved plan assigns; no mode named means delegate. The modes differ only in who writes each phase: §2 assigns it, §5 runs it. Rules: CLAUDE.md. Chat: lean STE (tables for numbers); plan text, commands and code: full. Flags, limits and exit codes: `python3 ~/.claude/concord/concord.py --help`.

## 1. Start
- Check the planner model (CLAUDE.md). A code ticket not in its worktree → `python3 ~/.claude/concord/wt.py new <TICKET>` from the main checkout, then `EnterWorktree`; write outputs inside it (`wt.py list` shows OVERLAP / DRIFT).
- The plan: `--plan <file>`, else, when the request names phases or no task, the only `PLAN_<ticket>.md` at the repo root (several: ask which). Continue it, passing `--plan <file>` on every dispatcher call; each step below that its recorded state already satisfies is skipped. A task and no plan: §2 plans it. No plan and no task: offer `/concord:run <mode> <task>`.
- Phases named in the request (`2`, `1,3`, `2-4`, `all` = every phase that `concord.py --phases --plan <PLAN>` lists as CHANGED, FAIL or NOT RUN once the plan's text has its APPROVE (§3; before that it exits 11): a phase a later revision changed reads CHANGED and runs again, one the revision left as it was, or changed only in its `Executor:`, `Size:`, `After:` or `Notes:`, keeps its PASS, and an OPEN or NO VERDICT phase has a run to finish first (§6)) are the owner's go for those phases (§4 says how long a go holds), and the text after them is feedback for those phases (an executor run gets it as `--extra`; the planner applies it to its own phases), never a new task. In delegate mode a model named in the request overrides `Executor:` for this request (`concord.py --resolve "<name>"`; ask when it is unknown or ambiguous), and `escalate` takes the next step of models.conf `ladder`.

## 2. Plan
- No plan yet: load `concord:plan` with the mode; a task it finds routine leaves this workflow.
- Grill: ask the owner at most 5 blocking questions in one message, each with the default you take without an answer (`concord:design-review` says which choices are the owner's). Record the answers under `## Settled` and the defaults under `## Defaults taken`.
- Implementer: before verification, check that every phase's `Executor:` follows the mode as `concord:plan` assigns it (execute: `planner` on every phase). Changing an approved phase's `Executor:` needs a new verification (§3); a model named for one request (§1) does not.
- A large ticket: when `concord:plan` returns a split plan (a `## Split` table of child tickets instead of phases), verify it (§3, as a plan file: nothing is recorded) and give the owner one go on the split. Then each child is a ticket of its own: its own worktree (`wt.py new <CHILD>`, cut once the children it waits for have merged), its own session and `/concord:run`, plan, APPROVE, go and PR. Children that share no files run at the same time; `wt.py list` shows them all and flags any overlap. A child's grill does not ask again what the split settled.

## 3. Verify
Load `concord:verify-plan` unless the plan's exact text already has a recorded APPROVE; a run without one exits 11.

## 4. Go
- `concord.py --estimate --plan <PLAN>`: fix its ESTIMATE LINT lines, then copy its PASSES, CRITICAL PATH and ETA lines into `## Passes` (outside the approved text, so an executor never reads its schedule there).
- Go/no-go: the lane diagram, the ETA (the critical path, never the sum of all phases) with the local time it lands, the verifier's cuts and the open items, in one message; stop until the owner says go. A partial go covers only those phases. A go, here or by phases named in the request (§1), holds while each phase's work stays as the owner saw it: when verification or a later fix changes anything in a phase but its `Executor:`, `Size:`, `After:`, `Notes:` or `Risk:`, show the owner that change and stop until they give that phase's go again.

## 5. Implement
Phases wait only for their `After:` phases. The run lock covers each run's `Files:` and `Follow-through:`; a run with no `Files:`, or one that shares a file with a live run, is refused, and an open `--begin` run blocks every other run in its checkout. Reviews, lints and suites take no lock. The approved plan is the ceiling for this session too: work beyond it and the check, fix and review steps (a rewrite, a new kind of check, another corpus, re-verifying rows that already pass) → stop and ask in one line: what, why, cost. At a DRIFT BLOCK (time or size past the plan's limit, or a changed file outside its `Files:` and `Follow-through:`): stop, report and ask; continue only with `--user-approved "<their words>"`, which never stands in for the verifier's APPROVE.

### execute
Each approved phase in dependency order: `concord.py --begin <phase> --label planner` (it starts the drift clock and passes the gates), write the phase, re-run its acceptance, `--end <run-id>`, then §6.

### delegate
Each approved phase on its implementer:
- `planner`: as in execute.
- Claude subagent (`implementer`, `implementer-opus48`, by the names the Concord rules in CLAUDE.md give them): `--begin <phase> --label <name>`, the agent (plan path, the `approved plan` path that `--begin` prints, phase, feedback), `--end <run-id>`.
- OpenCode or pi: `concord.py <model> <phase> --plan <F> [--extra=<feedback>]`, in the background, outside the sandbox; red-run exit 6 (acceptance already green): a phase `--phases` lists as CHANGED may already meet its revised text, so re-grade it as in execute (check the code against the phase and change what it must); otherwise TEST_DEFECT, or mark it `(characterization)`. File scope is enforced only on OpenCode; on pi the report's out-of-scope lines are the check.
- Executor phases whose `Files:` and `Follow-through:` are disjoint run in the ticket's worktree at once. A phase that runs beside a planner phase, or shares a file, gets a fork: `python3 ~/.claude/concord/wt.py fork <TICKET> <N>`, run and checked there with `--repo <fork>`; after PASS, `wt.py join <TICKET> <N>` from the checkout that made the fork applies its changes back and removes the fork. Join refuses, and keeps the fork, when the fork holds a file in two versions (staged or committed content that differs from the working file) or ignored files of its own; `--force` joins anyway and lists what it drops.

## 6. Check (each run)
- Failing report lines: REJECTED (not graded) with its causes, OUT OF SCOPE (source), DELETED, STAGED BY EXECUTOR, GIT INTERNALS CHANGED, HEAD MOVED, BRANCH CHANGED, CHARACTERIZATION CHANGED, POST-RUN COMMAND CHANGED THE TREE, OUTSIDE CHECKOUT CHANGED by the executor, STATIC NEW, ACCEPTANCE AFTER RUN: 0/N, RESOURCE LIMIT (the line names the cause). `EXECUTOR BLOCKED` → FAIL BLOCKED; `PROVIDER LIMIT` or `PROVIDER BLOCKED` → FAIL PROVIDER, then the next model; on a review (exit 9) nothing is recorded, so the next model reviews; an OpenCode refusal of an unlisted file without a BLOCKED line → PLAN_GAP.
- Trust the report's `acceptance after run` line (the dispatcher re-ran the acceptance); re-run only to settle a doubt (a flip on rerun: FLAKY). Read the run's change, the `git diff` on the report's `graded candidate` line, against the phase. No full suite and no review before §8.
- PASS when every acceptance command has its expected result after the run and the diff matches the phase: `--verdict <run> PASS`. The dispatcher refuses it (exit 7) when a result is missing or unexpected, the run was rejected, a post-run command changed the tree, or the checkout no longer holds the graded candidate or the grading files it was graded with; after a cleanup or a fix outside a run, `--grade <run>` grades the current files (a run recorded before 3.1.0 runs again). A `(fails until …)` command counts as red only on a real failure, not a timeout or a command that could not run; its phase needs `--note "<the tests that failed and why>"`, after you checked each fails for the stated reason. `--force` records `PASS (forced)`, which the report lists under Overrides with the failed commands beside your `--note` as the reason (`reason: not recorded` without one).

## 7. A failed run
`--verdict <run> FAIL --cause <CAUSE> --note "<why>"`.
- EXECUTOR: retry the same implementer with `--extra="EVIDENCE: <command + decisive lines> | SUSPECTED: <files> | CHANGE: <what must differ>"`; after three EXECUTOR failures of a phase, stop and ask the owner. Escalate (models.conf `ladder`) only when the owner asks.
- PLAN_GAP: `--restore <run>`, fix the plan (ask on the owner's calls), verify it again (§3; a changed phase needs the owner's go again, §4), retry.
- BLOCKED: answer in the phase's Decisions (ask on the owner's calls), `--restore <run>` if files changed, verify again, re-run with `--extra "ANSWERS: ..."`; a second BLOCKED is a PLAN_GAP.
- TEST_DEFECT, FLAKY: fix the tests here. Out-of-scope edits, deletions or a modified plan: stop, show them, offer `--restore`.
- `--restore <run>` works only in the checkout of the run and restores only files still as the run left them (content, type and executable bit); it lists the others and leaves them alone.

## 8. Full revision
After the last phase, load `concord:lean-testing` for the consolidation pass over the tests the ticket touched; then, at once, every suite (one that checks the checkout itself, such as `tests/demo_test.sh`, alone) and `concord:review-change` on the whole diff: the PR gate, else each implementing run's review.

## 9. Hand off (context already large)
Write the plan's `## Handoff` (settled decisions, what the investigation learned, the phases the owner approved), `ExitWorktree keep`, start a fresh planner-model session in the worktree with `/concord:run <mode> --plan PLAN_<ticket>.md <approved phases>`, detach it and end this one (none can start → `EnterWorktree` back and run here).

## 10. Report, DAT and KB
- `concord.py --report --plan <PLAN>` writes `REPORT_<ticket>-<id>.md` (`<id>`: the first 8 characters of the ticket id) in the runs root (`.git/concord/reports/`) from recorded data: first the Overrides (forced PASS with its failed commands, `--user-approved` texts and their use, exclusion waivers, `--no-baseline`, unsandboxed executor runs, PASS over out-of-scope changes, each PASS whose phase a later revision changed, phases reviewed below their Risk, high-tier phases without a review from another model family), then the phases with who implemented each, the plan revision, the graded candidate and its review, the plan's Test plan, test lines beside the `Tests:` estimate, reviews, each finding's outcome with its round, head and closing review, open items for the DAT and time against the ETA. It refuses (exit 2) while a run of the plan is open or has no verdict. It stops the drift clock, and later runs of the plan are refused (exit 10). Give the owner its path for the DAT; DAT fixes take the small-fix path (scoped tests, one cheap delta review).
- Tell the owner, per phase: executor, model, billing, risk, verdict and cause, acceptance evidence, checks skipped, review verdict, findings fixed and left, files.
- KB step: replace stale lines in the repo notes and memory (never append a duplicate), run the repo notes' `KB command:` if one is set, and merge the approved case diff into the `Cases:` file (executor phases may not list it).
- After the owner committed and pushed: `ExitWorktree keep`, then `wt.py done <TICKET>` outside the sandbox.
