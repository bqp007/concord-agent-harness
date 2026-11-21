# The Concord workflow

*How a ticket runs. Setup: [SETUP.md](SETUP.md); other workflows: [COMPARISON.md](COMPARISON.md); the exact steps: [plan-then-delegate](../adapters/claude-code/commands/plan-then-delegate.md) and [delegate](../adapters/claude-code/commands/delegate.md).*

## Roles

![Who does what](figures/fig1-roles.svg)
*Frontier tokens go to judgment, cheap tokens to typing.*

| Role | Model (as shipped) | Paid from |
|---|---|---|
| Planner: plans, tests, small changes, checks, report | the strongest Claude model, high effort | Claude subscription |
| Implementer of bulky phases | DeepSeek or GLM Flash, free; DeepSeek Flash on Go; then Opus 4.8 | free tier, Go allowance, subscription; `zen-*` credits only after asking |
| Reviewer: a full review at the change's risk tier, a delta review after each fix | flash at low risk, Opus 5.5 above; Haiku or flash for deltas | free tier or subscription |
| Approver and committer | you | |

## Stages of one ticket

![One ticket end to end](figures/fig2-loop.svg)
*Two human gates, tests before code, and failures that name where the work goes back.*

1. **Worktree.** One git worktree per ticket (`wt.py new`): shared clones once caused 15 lock collisions and 22 unwanted branch switches.
2. **PLAN, early plan.** The planner reads the context once: the code, the spec, any Figma file, the `Cases:` file that repo notes name, and the skills. It writes the early plan: Design, Test plan ledger, Conflicts, Open questions, and per phase the executor, the risk, the files, the steps, `Size:` and `After:`. It writes no minutes.
3. **PLAN, grill.** The planner asks at most five blocking questions, each with a default. The grill is the first human gate: you answer it, or let the defaults stand.
4. **PLAN, verifier.** A verifier agent (`concord:plan-verifier`) reads the plan read that `concord.py --lint` wrote and checks the plan against the code: that every item serves the goal, that its claims about interfaces, callers and assumptions are true, that each acceptance command fails before the work and after a stub, that each `Risk:` fits what the phase touches, and that the Test plan follows the test rules. In one round it returns CUT, MERGE and FIX items and lists CONFLICTS and PLAN_GAPS, where CONFLICTS also names each consequential choice that no owner decision settles, as the `concord:concord-design-review` skill it preloads defines one; it writes a plan or an estimate of its own only when that changes the decision. A second round only confirms the fixes.
5. **PLAN, estimate.** `concord.py --estimate` turns the phase `Size:` values, the `After:` waits and the run ledger into phase minutes. It prints the lanes, the critical path, the session lane and the ETA, and stores the ETA for the plan. The planner pastes the lanes into `## Passes`. Code computes; the model challenges.
6. **PLAN, lint and go/no-go.** `concord.py --lint` checks each delegated phase and makes no model call: lines for six defects in acceptance commands that plan reviews kept rediscovering, and PLAN LINT lines for a missing `Size:`, `ETA:` or `Tests:` line and for an executor phase that lists the `Cases:` file. It also writes the plan read that the verifier reads. You then give one go/no-go on the lane diagram, the computed ETA and the cuts.
7. **Tests first, then EXECUTE.** For a changed behavior, failing tests are written in their own run, and the planner checks that each fails for the stated reason; a routine change under characterization checks needs no separate red run. Phases then run in parallel lanes. A lock covers a set of files, so phases with disjoint `Files:` run in one worktree at once; a fork covers phases that share a file or run beside an open planner phase. A phase waits only for its real dependencies; the planner chooses the decomposition, the executors and the order within the approved scope.
8. **QC, checks per round.** After each round the planner reads the dispatcher's blocking report lines, trusts its acceptance re-run (it re-runs a command only to settle a doubt) and reads the diff. It records PASS or FAIL with a cause; a PASS needs the expected result of every acceptance command from after the run.
9. **QC, review rounds.** A review round is a full review at the risk tier, fixes, then a cheap delta review that closes the findings it shows fixed. The stop rule and the PR gate are below.
10. **DAT.** `concord.py --report` writes the test report from recorded data once every run of the plan has a verdict, stops the drift clock and closes the plan to new runs. It opens with the overrides, then covers the phases, the Test plan, the test lines beside the `Tests:` estimate, the review rounds, the open items for the DAT and the time against the ETA.
11. **KB update.** The session replaces the repo-notes lines the ticket changed, runs an optional `KB command:` from repo notes, and merges the approved case diff into the `Cases:` file.
12. **Commit.** You commit and merge.

## Size, drift and verification

A plan names its tier, S, M or L: the planner's judgment of its size, which sets the final-revision allowance of the estimate and turns on the drift clock. Size does not decide who writes the code or whether the owner decides: a consequential behavior or architecture choice goes to the owner however small the change, and a change that costs more to specify than to write is written by the planner. Every plan the dispatcher runs needs the verifier's APPROVE, whatever its tier. The `Size:` and `ETA:` lines of a plan set the budget of the run. The plan head also carries `Tests: +A/−D lines`, an estimate that the report prints beside the actual lines and that never fails a verdict, and the Test plan lists each touched behavior as KEEP, EXTEND, MERGE, REPLACE, DELETE or ADD.

`concord.py --estimate` reads the phase sizes and waits, and the median and p75 of the run ledger, and it prints one lane diagram with the minutes of each phase. The session lane adds one check per executor phase in series. The plan stores the computed ETA.

The drift brake compares the run with that stored estimate. `concord.py --drift` warns and then blocks when the run outgrows the stored estimate (else the plan's `ETA:`) or the plan's `Size:` (the thresholds are in `concord.py --help`), and it blocks when a changed file lies outside every `Files:` list. A block makes `--begin` and the executor runs exit 10. Stop, report and ask; `--user-approved` lifts the block until the run outgrows the approved measure, and it never stands in for the verifier's APPROVE. The drift hook runs after each tool call, starts Python only in a repository where Concord keeps drift data, and prints a line only when the state changes. Once its report is written, a plan refuses new runs (exit 10) and its clock stops.

Before you see a plan, a verifier agent (`concord:plan-verifier`) challenges it, in one round and a second one only to confirm the fixes. `--lint` writes the plan's approval-relevant text, everything except the prose of the sections whose heading is exactly `## Open questions`, `## Handoff` or `## Passes` (case and spaces aside), to a plan read named by its hash; a phase counts wherever it sits, and a skip heading inside a phase hides none of the phase. The verifier reads that file and quotes its hash, and `--plan-verdict` records the approval for that hash only. Each run reads the plan once and uses that one text for the gate, the phase, the acceptance commands and the run's snapshot; `--begin` and executor runs exit 11 when that text has no approval. Delta reviews of a fix run on flash, else on the `concord:reviewer-delta` agent (Haiku), never on Opus.

## The lock

A lock covers a set of files, not a checkout. `<git-dir>/concord.lock` holds one record per live run with its run id, its files and the files it shares. A new run refuses to start when its `Files:` overlap a live run's files, or when either side lists no file, and the message names the shared file. An open `--begin` run blocks every other run in its checkout. Two runs with disjoint files use one worktree at once; the out-of-scope report leaves the other run's files out. The lock file is deleted when the last run leaves.

## Evidence, not claims

Before each executor run `concord.py` snapshots the tree, backs up in-scope files and hashes the plan and acceptance, and it keeps that start state in its own memory, where the executor cannot rewrite it. It refuses to start when acceptance already passes (the red run) and reports from snapshots, never from the executor's account. After the run it re-runs every acceptance command; a PASS is refused (exit 7) when a result is missing or differs from the expected one, and a command marked `(fails until …)` counts as red only on a real failure, not a timeout or a command that could not run. `--force` records the PASS as forced, and the report shows the failed commands beside the reason. Only EXECUTOR failures count as attempts (three, then you decide): 7 of 35 failures in the first ten days. `--restore <run>` puts back only the files still as the run left them, in the checkout of the run. Causes, refusals and exit codes: [README](../README.md#run-a-ticket).

## Review

High risk means untrusted input, scores or thresholds, security, money, data deletion or concurrency; a repository's `Risk floor <tier>: <globs>` notes line raises sensitive paths. A finding needs a reproduction to stay above NOTE, and a reproduced finding keeps its severity even outside the diff. A clause the review marks FAIL counts as a finding. At medium and high tier a CLEAN review found no BLOCKER, HIGH or MEDIUM; the low tier judges BLOCKER and HIGH only and says so in its verdict.

The PR gate reads the pull request's diff from its merge base to its current head. Each file needs the highest `Risk:` among this PR's runs that changed it, or medium when no run did. A file is covered when a review at that tier read it, or when it was covered at a delta review's base and that delta tied every one of its changed hunks to a finding that the same delta closed; an unchanged file keeps its coverage, and a file new since the delta's base needs a review at its tier. A review counts at most at its reviewer's rank, and owner words never raise it. A finding stays open until a review of a later head on the same history answers that it is fixed and cites the lines; a fix on another branch closes nothing, and a clause FAIL closes only by a review of the files of the review that raised it. Reviewers see every text file as text, whatever the repository's diff attributes say; a binary file is never covered by a review and needs the owner's words naming it. `--pr-status` prints REVIEWED, and exits 0, only when no finding is open and every file is covered or excluded by the owner's words naming it. A retarget, a base merge, a force-push or a rebase starts the coverage over; every unresolved finding is carried to the next packet with its evidence, and a review of the new head resolves it when the current code no longer has the defect. Phase reviews do not count.

The loop stops at 0 open BLOCKER and HIGH, and the dispatcher caps the full reviews of a pull request. A MEDIUM is fixed only when it occurs in a real flow; the other MEDIUMs, NOTEs and NITs go to the DAT. The test report gives each finding's outcome with its round, head and closing review. A review packet has a size cap; larger diffs go to reviewers in file groups.

![Segmented review](figures/fig3-segmented-review.svg)
*A retired segmented review; its file-group split remains for diffs over the packet cap.*

## Token economy

![Compaction sawtooth](figures/fig6-compaction.svg)
*Compacting at a 400k window keeps every turn below the curve's costliest part.*

DeepSeek Flash runs at effort `high`: in fifteen runs on one hard problem it matched `max` for less.

![Reasoning variants](figures/fig5-reasoning-variants.svg)
*Reasoning tokens and correct answers per variant, 15 runs on one problem.*

## Known limits

- File scope is enforced only on OpenCode's edit tools; shell redirection and network use are not mediated, so the in-scope backup is the safety net.
- Failure causes are assigned by the orchestrator that wrote the plans; no second rater has checked them.
- The line budgets of `/concord:rules-review` keep the rules small; [COMPARISON.md](COMPARISON.md) maps what Concord lacks.
