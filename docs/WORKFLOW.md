# The Concord workflow

*How a ticket runs. Setup: [SETUP.md](SETUP.md); other workflows: [COMPARISON.md](COMPARISON.md); the exact steps: the commands [plan-then-delegate](../adapters/claude-code/commands/plan-then-delegate.md) and [delegate](../adapters/claude-code/commands/delegate.md).*

## Roles

![Who does what](figures/fig1-roles.svg)
*Frontier tokens go to judgment, cheap tokens to typing.*

| Role | Model (as shipped) | Paid from |
|---|---|---|
| Planner: plans, tests, small changes, checks | the strongest Claude model, high effort | Claude subscription |
| Implementer of bulky phases | DeepSeek or GLM Flash, free; DeepSeek Flash on Go; then Opus 4.8 | free tier, Go allowance, subscription; `zen-*` credits only after asking |
| Reviewer, once | flash at low risk, Opus 5.5 above | free tier or subscription |
| Approver and committer | you | |

## One ticket, end to end

![One ticket end to end](figures/fig2-loop.svg)
*Two human gates, tests before code, and a failure that always names where the work goes back.*

1. One git worktree per ticket (`wt.py new`): shared clones once caused 15 lock collisions and 22 unwanted branch switches in one measured stretch.
2. A one-page plan: Done when, Ship, Open questions, and per phase the executor, risk, files, steps and acceptance commands. `concord.py --lint` checks each delegated phase once: zero-token lines for six defects plan reviews kept rediscovering, then a cheap model's questions.
3. You approve, once every known ambiguity is settled.
4. The planner writes the tests, which must fail on the untouched code, and the small changes; a free model runs each bulky phase.
5. The planner checks each result from the evidence and records PASS or FAIL with a cause.
6. One independent review at the risk tier, at the pull-request gate when the ticket ships by PR. Confirmed BLOCKER, HIGH and MEDIUM findings are fixed in place and re-reviewed once; after two rounds you decide.
7. You commit and merge.

## Evidence, not claims

For each executor run `concord.py` snapshots the tree, backs up the in-scope files and hashes the plan and acceptance files; refuses to start when acceptance already passes (the red run); limits edits to `Files:` on OpenCode; and reports from snapshots and hashes, never from the executor's account. Every FAIL names its cause: EXECUTOR, PLAN_GAP, TEST_DEFECT, FLAKY, PROVIDER or BLOCKED. Only EXECUTOR counts as an attempt (three, then you decide); in the first ten days only 7 of 35 failures were the executor's. Refusals and exit codes: [README](../README.md#run-a-ticket).

## Review

High risk means untrusted input, scores or thresholds, security, money, data deletion or concurrency; a `Risk floor <tier>: <globs>` line in a repository's notes raises sensitive paths. A finding needs a reproduction to stay above NOTE, and the planner reads the cited lines before acting. Clean reviews are reused on unchanged files. At the PR gate a review counts at most at its reviewer's rank, so a flash review cannot pass a high-risk pull request without your recorded go-ahead. `--mutate` optionally probes the tests.

![Segmented review](figures/fig3-segmented-review.svg)
*A retired segmented review: about 400 lines no daily diff needed. The 60,000-character cap and the file-group split remain.*

## Token economy

![Compaction sawtooth](figures/fig6-compaction.svg)
*Compacting at a 400k window keeps every turn below the most expensive part of the curve.*

After a compaction the planner re-reads the plan. Prose only agents read is terse (`CONTRACT.md` rule 12). DeepSeek Flash runs at effort `high`: in fifteen runs on one hard problem it matched `max` for less.

![Reasoning variants](figures/fig5-reasoning-variants.svg)
*Reasoning tokens and correct answers per variant, 15 runs on one problem.*

## Known limits

- File scope is enforced only on OpenCode, for its edit tools; shell redirection and shell network use are not mediated. The backup of in-scope files is the safety net.
- Failure causes are assigned by the orchestrator that wrote the plans; no second rater has checked them.
- Line budgets (`tests/package_test.sh`) and `/concord:rules-review` keep Concord small; [COMPARISON.md](COMPARISON.md) maps what it lacks.
