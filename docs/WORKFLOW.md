# The Concord workflow

*How a ticket runs. Setup: [SETUP.md](SETUP.md); other workflows: [COMPARISON.md](COMPARISON.md); the exact steps: [plan-then-delegate](../adapters/claude-code/commands/plan-then-delegate.md) and [delegate](../adapters/claude-code/commands/delegate.md).*

## Roles

![Who does what](figures/fig1-roles.svg)
*Frontier tokens go to judgment, cheap tokens to typing.*

| Role | Model (as shipped) | Paid from |
|---|---|---|
| Planner: plans, tests, small changes, checks, report | the strongest Claude model, high effort | Claude subscription |
| Implementer of bulky phases | DeepSeek or GLM Flash, free; DeepSeek Flash on Go; then Opus 4.8 | free tier, Go allowance, subscription; `zen-*` credits only after asking |
| Reviewer: full reviews at the start and the end, a delta review after each fix | flash at low risk, Opus 5.5 above | free tier or subscription |
| Approver and committer | you | |

## Stages of one ticket

![One ticket end to end](figures/fig2-loop.svg)
*Two human gates, tests before code, and failures that name where the work goes back.*

1. **Worktree.** One git worktree per ticket (`wt.py new`): shared clones once caused 15 lock collisions and 22 unwanted branch switches.
2. **PLAN, early plan.** The planner reads the context once: the code, the spec, any Figma file, the `Cases:` file that repo notes name, and the skills. It writes the early plan: Design, Test plan ledger, Conflicts, Open questions, and per phase the executor, the risk, the files, the steps, `Size:` and `After:`. It writes no minutes.
3. **PLAN, grill.** The planner asks at most five blocking questions, each with a default. The grill is the first human gate: you answer it, or let the defaults stand.
4. **PLAN, verifier.** A verifier agent (`concord:plan-verifier`) reads the code itself and writes its own smallest plan and estimate first. In one round it returns CUT, MERGE, PARALLELIZE, DIRECT and FIX items with the minutes each saves, checks the Test plan, and lists CONFLICTS and PLAN_GAPS. A second round only confirms the fixes.
5. **PLAN, estimate.** `concord.py --estimate` turns the phase `Size:` values, the `After:` waits and the run ledger into phase minutes. It prints the lanes, the critical path, the session lane and the ETA, and stores the ETA for the plan. The planner pastes the lanes into `## Passes`. Code computes; the model challenges.
6. **PLAN, lint and go/no-go.** `concord.py --lint` checks each delegated phase once and makes no model call: lines for six defects in acceptance commands that plan reviews kept rediscovering, and PLAN LINT lines for a missing `Size:`, `ETA:` or `Tests:` line and for an executor phase that lists the `Cases:` file. You then give one go/no-go on the lane diagram, the computed ETA and the cuts.
7. **Tests first, then EXECUTE.** The planner writes failing tests for the main behaviour. Phases then run in parallel lanes. A lock covers a set of files, so phases with disjoint `Files:` run in one worktree at once; a fork covers phases that share a file or run beside an open planner phase. A phase waits only for its real dependencies.
8. **QC, checks per round.** After each round the planner reads the dispatcher's blocking report lines, trusts its acceptance re-run (it re-runs a command only to settle a doubt) and reads the diff. It records PASS or FAIL with a cause.
9. **QC, review rounds.** A review round is a strong full review, fixes, a cheap delta review, then a strong full review on the new head. The stop rule and the cap are below.
10. **DAT.** `concord.py --report` writes the test report from recorded data and stops the drift clock. It covers the phases, the Test plan, the test lines, the review rounds, the open items for the DAT and the time against the ETA.
11. **KB update.** The session replaces the repo-notes lines the ticket changed, runs an optional `KB command:` from repo notes, and merges the approved case diff into the `Cases:` file.
12. **Commit.** You commit and merge.

## Size, drift and verification

A plan names its tier: S is 60 lines or fewer in 3 files or fewer and needs no plan; M is a short plan; L is the full plan. The `Size:` and `ETA:` lines of a plan set the budget of the run. The plan head also carries `Tests: +A/−D lines, net ≤ N`, and the Test plan lists each touched behavior as KEEP, EXTEND, MERGE, REPLACE, DELETE or ADD.

`concord.py --estimate` reads the phase sizes and waits, and the median and p75 of the run ledger, and it prints one lane diagram with the minutes of each phase. The session lane adds one check per executor phase in series. The plan stores the computed ETA.

The drift brake compares the run with that stored estimate. `concord.py --drift` warns at 1.2× and blocks at 1.5× of the stored estimate (else the plan's `ETA:`) or the plan's `Size:`, and it blocks when a changed file lies outside every `Files:` list. A block makes `--begin` and the executor runs exit 10. Stop, report and ask; `--user-approved` lifts the block until the measure grows 50% more. The `--drift-hook` PostToolUse hook prints a line only when the state changes. A checkout with a written report is not gated, and its clock stops.

Before you see a plan, a verifier agent (`concord:plan-verifier`) prunes it, in one round and a second one only to confirm the fixes. The planner records the answer with `--plan-verdict`; `--begin` and executor runs exit 11 for a plan with no approval, and the `## Passes` lines join the sections an approval survives. Delta reviews of a fix run on flash, else on the `concord:reviewer-delta` agent (Haiku), never on Opus.

## The lock

A lock covers a set of files, not a checkout. `<git-dir>/concord.lock` holds one record per live run with its run id, its files and the files it shares. A new run refuses to start when its `Files:` overlap a live run's files, or when either side lists no file, and the message names the shared file. An open `--begin` run blocks every other run in its checkout. Two runs with disjoint files use one worktree at once; the out-of-scope report leaves the other run's files out. The lock file is deleted when the last run leaves.

## Evidence, not claims

Before each executor run `concord.py` snapshots the tree, backs up in-scope files and hashes the plan and acceptance; it refuses to start when acceptance already passes (the red run) and reports from snapshots, never from the executor's account. Only EXECUTOR failures count as attempts (three, then you decide): 7 of 35 failures in the first ten days. Causes, refusals and exit codes: [README](../README.md#run-a-ticket).

## Review

High risk means untrusted input, scores or thresholds, security, money, data deletion or concurrency; a repository's `Risk floor <tier>: <globs>` notes line raises sensitive paths. A finding needs a reproduction to stay above NOTE. Clean reviews are reused on unchanged files. At the PR gate a review counts at most at its reviewer's rank, so a flash review cannot pass a high-risk pull request without your recorded go-ahead.

One PR gets at most three full review rounds, one per head; a full review of a fourth head is refused without `--user-approved`. The loop stops at 0 BLOCKER and 0 HIGH. A MEDIUM is fixed only when it occurs in a real flow; the other MEDIUMs, NOTEs and NITs go to the DAT. A review packet caps at 300,000 characters.

![Segmented review](figures/fig3-segmented-review.svg)
*A retired segmented review; its file-group split remains, and the packet cap is 300,000 characters.*

## Token economy

![Compaction sawtooth](figures/fig6-compaction.svg)
*Compacting at a 400k window keeps every turn below the curve's costliest part.*

DeepSeek Flash runs at effort `high`: in fifteen runs on one hard problem it matched `max` for less.

![Reasoning variants](figures/fig5-reasoning-variants.svg)
*Reasoning tokens and correct answers per variant, 15 runs on one problem.*

## Known limits

- File scope is enforced only on OpenCode's edit tools; shell redirection and network use are not mediated, so the in-scope backup is the safety net.
- Failure causes are assigned by the orchestrator that wrote the plans; no second rater has checked them.
- Line budgets (`tests/package_test.sh`) and `/concord:rules-review` keep Concord small; [COMPARISON.md](COMPARISON.md) maps what it lacks.
