---
description: Run plan phases in passes on their executor or a named model, check each result, review once, fix confirmed findings
argument-hint: [model] <phase | 1,3 | 2-4 | all> [feedback | escalate]
---
Rules: CLAUDE.md. Arguments: $ARGUMENTS. Chat: terse (tables); commands, plan text, code: full. Flags: `python3 ~/.claude/concord/concord.py --help`.

## 1. Resolve
- Plan: the `PLAN_<ticket>.md` the request names, else the only one at the repo root, as `--plan <file>` on every call; none → offer `/concord:plan-then-delegate`.
- Model: the request, else `Executor:`, else models.conf `default`, checked with `concord.py --resolve "<name>"`; ask when unknown or ambiguous.

## 2. Run in passes, not as a chain
- A pass (CLAUDE.md) runs its phases at once; only real dependencies wait (`/concord:plan-then-delegate` step 3).
- An executor phase gets its own fork: `python3 ~/.claude/concord/wt.py fork <TICKET> <N>`, run and checked there with `--repo <fork>`; after PASS, `wt.py join <TICKET> <N>` applies its changes back and removes the fork. Planner phases run in the ticket's worktree meanwhile; reviews, lints and suites take no lock.
- `planner` phase: write it, re-run its acceptance; `--begin`/`--end` only when a review needs its run id (no PR).
- Claude subagent: `--begin <phase> --label <name>`, the subagent (plan path, phase, feedback), `--end <run-id>`.
- OpenCode: `concord.py <model> <phase> --plan <F> [--extra=<feedback>]`, background, outside the sandbox; red-run exit 6 (acceptance already green): TEST_DEFECT, or mark it `(characterization)`.

## 3. Check (per pass, only the phases it changed)
- Failing report lines: OUT OF SCOPE (source), DELETED, STAGED BY EXECUTOR, GIT INTERNALS CHANGED, PLAN FILE MODIFIED, HEAD MOVED, BRANCH CHANGED, DEPENDENCIES CHANGED, CHARACTERIZATION CHANGED, ACCEPTANCE FILES CHANGED, OUTSIDE CHECKOUT CHANGED by the executor, STATIC NEW, ACCEPTANCE AFTER RUN: 0/N. `EXECUTOR BLOCKED` → FAIL BLOCKED; `PROVIDER LIMIT` or `PROVIDER BLOCKED` → FAIL PROVIDER, then the next model; on a review (exit 9) nothing is recorded, so the next model reviews; an OpenCode refusal of an unlisted file without a BLOCKED line → PLAN_GAP.
- Re-run the report's acceptance (a flip on rerun: FLAKY), read `git diff HEAD -- <the phase's files>`: out-of-scope source, or tests an implementing phase touched, fail it. No full suite and no review before §5.
- PASS when acceptance passes and the diff matches the phase: `--verdict <run> PASS`.

## 4. FAIL
`--verdict <run> FAIL --cause <CAUSE> --note "<why>"`.
- EXECUTOR: retry the same model with `--extra="EVIDENCE: <command + decisive lines> | SUSPECTED: <files> | CHANGE: <what must differ>"`; a fourth attempt is refused (exit 8) without `--user-approved "<their words>"`. Escalate (models.conf `ladder`) only when the user asks.
- PLAN_GAP: `--restore <run>`, fix the plan (ask on the user's calls), retry.
- BLOCKED: answer in the phase's Decisions (ask on the user's calls), `--restore <run>` if files changed, re-run with `--extra "ANSWERS: ..."`; a second BLOCKED is a PLAN_GAP.
- TEST_DEFECT, FLAKY: fix the tests here. Out-of-scope edits, deletions or a modified plan: stop, show them, offer `--restore`.
- A defect found after the gate (a later review, a PR comment, production) is fixed with a test or lint that fails on the old code, never a REVIEW.md line.

## 5. Full revision
- After the last pass, at once: every suite (one checking the checkout itself, such as `tests/demo_test.sh`, alone) and one review of the whole diff: the PR gate (§6), else each implementing run's review.
- Tier = the phase's Risk (default medium), raised for matching non-test files by a repo-notes `Risk floor <tier>: <globs>` line. low: `concord.py --review <run>` (flash), approve-only: only BLOCKER and HIGH are kept. medium, high: `--review <run> --packet`, a fresh `concord:reviewer-opus55` Agent per round given your acceptance results, `--review-record` its answer with `--tokens <the Agent's total_tokens>`. Over the 60,000-character cap: `--files <globs>` per group.
- Unchanged files cleared at that tier or higher print `COVERED` (`--force-review` overrides).
- Review a fork (`wt.py fork <TICKET> r`); Monitor `<packet>.stream`, fix each streamed finding in the ticket worktree as it lands (small: here, else its executor, `--extra`); one delta review after the final verdict.

## 6. PR gate
- Review the full diff (`base...head`; stacked: against the parent branch) on its current head at the PR's tier, the riskiest content's: high for shipped product code, verdict, score, threshold or licence paths, exporters, untrusted input, security, release config; medium for reference, data and eval pipelines, behaviour-pinning fixtures; low for tooling, scripts, docs.
- `--review-pr <PR> --tier <T>` runs flash; `--packet` for `concord:reviewer-opus55`. Over the cap: one reviewer per file group (`--files`), in parallel, together covering every PR file.
- After a fix commit: `--review-pr <PR> --delta`; a fix rewriting over half of an existing file (refused) or changing the design needs a full review, one of only tests, docs or comments runs at low.
- `--pr-status <PR>` must print `CURRENT HEAD <sha>: REVIEWED`; it names the files no review covered and the missing reviewer, and lists `--exclude`d files. A review counts at most at its reviewer's rank (flash low, `concord:reviewer-opus55` high and below); a lesser one needs `--user-approved "<their words>"`.
- Others' PR: findings go to the author; another engineer approves; never merge.

## 7. Report
Per phase: executor, model, billing, risk, verdict and cause, acceptance evidence, checks skipped, review verdict, findings fixed and left, files.

Lessons: the moment you learn something every session or executor should apply, record it: `concord.py --lesson "<rule>" --tag plan|exec` (plan: open sessions see it on their next prompt through the `--lessons-hook` UserPromptSubmit hook; exec: every executor task carries it). The weekly rules review folds lessons into the docs or a lint and removes them.
