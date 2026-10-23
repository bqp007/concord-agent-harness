---
description: Run plan phases on their executor or a model the user names ("deepseek flash", "sonnet"), check each result yourself, review once and fix confirmed findings
argument-hint: [model] <phase | 1,3 | 2-4 | all> [feedback | escalate]
---
Delegate phases and check every result (rules: CLAUDE.md). Arguments: $ARGUMENTS. Chat: terse (tables). Commands, plan text, code: full. Flags: `python3 ~/.claude/concord/concord.py --help`.

## 1. Resolve
- Plan: the `PLAN_<ticket>.md` the request names, else the only plan at the repo root, passed as `--plan <file>` on every call; none → offer `/concord:plan-then-delegate`.
- Phases: a number, list (1,3), range (2-4) or `all`, in order. Model: the request, else the phase's `Executor:`, else models.conf `default`; check it with `concord.py --resolve "<name>"`, ask when unknown or ambiguous.

## 2. Run (one writer per checkout; independent work in parallel)
- `planner` phase: write it here and re-run its acceptance; `--begin`/`--end` only when a review needs its run id (no PR).
- Claude subagent: `--begin <phase> --label <name>`, the subagent (plan path, phase, feedback), `--end <run-id>`.
- OpenCode: `concord.py <model> <phase> --plan <F> [--extra=<feedback>]` in the background, outside the sandbox. Its red run exits 6 when an acceptance command already passes: TEST_DEFECT, or mark the command `(characterization)`.

## 3. Check
- These report lines fail the phase: OUT OF SCOPE (source), DELETED, STAGED BY EXECUTOR, GIT INTERNALS CHANGED, PLAN FILE MODIFIED, HEAD MOVED, BRANCH CHANGED, DEPENDENCIES CHANGED, CHARACTERIZATION CHANGED, ACCEPTANCE FILES CHANGED (PASS refused, exit 7), OUTSIDE CHECKOUT CHANGED by the executor, STATIC NEW, ACCEPTANCE AFTER RUN: 0/N. `EXECUTOR BLOCKED` → FAIL BLOCKED; `PROVIDER LIMIT` or `PROVIDER BLOCKED` → FAIL PROVIDER, then the next model; an OpenCode refusal of an unlisted file without a BLOCKED line → PLAN_GAP.
- Re-run the acceptance commands from the report (a result that flips on a second run is FLAKY) and read `git diff HEAD -- <the phase's files>`; out-of-scope source, or tests an implementing phase touched, fail it.
- PASS when acceptance passes and the diff matches the phase: `--verdict <run> PASS`.

## 4. FAIL
`--verdict <run> FAIL --cause <CAUSE> --note "<why>"`.
- EXECUTOR: retry the same model with `--extra="EVIDENCE: <command + decisive lines> | SUSPECTED: <files> | CHANGE: <what must differ>"`. The fourth attempt is refused (exit 8) until the user's go-ahead is recorded with `--user-approved "<their words>"`. Escalate (models.conf `ladder`) only when the user asks.
- PLAN_GAP: `--restore <run>`, fix the plan (ask when the decision is the user's), retry.
- BLOCKED: answer in the phase's Decisions (ask when it is the user's call), `--restore <run>` if files changed, re-run with `--extra "ANSWERS: ..."`. A second BLOCKED on the phase is refused: a PLAN_GAP.
- TEST_DEFECT, FLAKY: fix the tests here. Out-of-scope edits, deletions or a modified plan: stop, show them, offer `--restore`.

## 5. Review
- A ticket that ships by PR skips this step: its one review is the PR gate (§6).
- Tier = the phase's Risk (none = medium), raised for matching non-test files by a repo-notes `Risk floor <tier>: <globs>` line. low: `concord.py --review <run>` (flash). medium and high: `--review <run> --packet`, then the `concord:reviewer-opus55` Agent it names, fresh each round, with your acceptance results in the prompt; `--review-record` its answer. Over the 60,000-character cap: `--files <globs>` per file group.
- The dispatcher demotes unreproduced or out-of-diff findings to NOTE, computes the verdict and keeps the ledger (F<n>). Unchanged files a review cleared at that tier or higher print `COVERED` (`--force-review` overrides).
- Fix a confirmed finding in place (here when small, else the same executor with the finding as `--extra`), then one delta review.
- Optional: `concord.py --mutate <run>` grades mutants of the run's own lines in an isolated copy with the non-characterization acceptance (`--max` 10; `--build "<cmd>"` for compiled code).

## 6. PR gate
- Review the full diff (`base...head`; stacked: against the parent branch) at the PR's tier on its current head. Tier = the riskiest content. high: shipped product code, verdict, score, threshold or licence paths, exporters, untrusted input, security, release config. medium: reference, data, label and eval pipelines, behaviour-pinning fixtures. low: tooling, scripts, docs.
- `--review-pr <PR> --tier <T>` runs flash; add `--packet` for `concord:reviewer-opus55`. Over the cap: one reviewer per file group (`--files`), in parallel.
- After a fix commit: `--review-pr <PR> --delta`. A fix that rewrites over half of an existing file (refused, file named) or changes the design needs a full review; a fix of only tests, docs or comments runs at low.
- `--pr-status <PR>` must print `CURRENT HEAD <sha>: REVIEWED`. A review counts at most at its reviewer's rank (flash low, `concord:reviewer-opus55` high and below); `--pr-status` names the missing reviewer. A lesser review with the user's go-ahead: `--review-pr <PR> --tier <T> --user-approved "<their words>"`, shown as `(owner override: "...")`.
- Others' PR: hand the findings to the author. Approval comes from another engineer; never merge.

## 7. Report
Per phase: executor and model, billing, risk, PASS/FAIL and cause, acceptance evidence, checks not run, review verdict, findings fixed and left, files changed.
