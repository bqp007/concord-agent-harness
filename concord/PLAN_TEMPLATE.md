# Plan: <ticket title>

Tier: <S|M|L>
Size: ~<N> lines
Tests: +<A>/−<D> lines
Done when: <the result and the command or number showing it>
Ship: <PR to <branch>, or no PR and why>

## Open questions
- Q1 <what the code cannot settle, or "none">

## Design
- <the change by workflow stage, one line each>

## Test plan
| Behavior | Existing tests | Action | Home |
|---|---|---|---|
| <one touched behavior> | <test names, or none> | <KEEP, EXTEND, MERGE, REPLACE, DELETE or ADD> | <test file> |

## Conflicts between sources
- <spec, code, Figma or cases that disagree, or "none">

## Phase 1 - Failing tests for <behaviour>
Executor: planner
Risk: low
Size: ~<N> lines
Files: tests/test_module.py
Baseline: skip
Steps:
1. Failing tests that tell the intended behaviour from the current one and the obvious wrong fix.
Acceptance:
- `pytest tests/test_module.py -q` (fails until Phase 2)

## Phase 2 - <short name>
Executor: free-deepseek-flash
Risk: medium
Size: ~<N> lines
After: 1 (<the reason it waits>)
Files: path/to/module.py
Follow-through: docs/module.md
Steps:
1. <the change, naming functions>
Notes:
- path/to/caller.py:main - the only caller
- path/to/module.py:40-60 - the old parser
Interfaces:
- `def parse(raw: str) -> Result` (new): raises `ValueError` on empty input
Decisions: <choices not to revisit>
Acceptance:
- `pytest tests/test_module.py -q`
- `pytest tests/test_existing.py -q` (characterization)
- `git diff --quiet HEAD -- include/` (characterization: only Files change)
Out of scope: <tempting edits>

## Passes
<copied from `concord.py --estimate --plan PLAN_<ticket>.md` after the verifier's APPROVE>
```text
Phase 1 planner 4 min ──> Phase 2 free-deepseek-flash 20 min
CRITICAL PATH: 1 → 2 = 24 min; session lane 7 min; final revision 20 min
```
ETA: <N> min, lands at <hh:mm> local

## Handoff
(if another session runs it)
- <settled decisions, what the investigation learned>

<!--
- The schedule (`## Passes`) and its diagram: `/concord:run` §4. The planner writes `Size:` and `After:`, never
  minutes; `--estimate` turns them and the run ledger into minutes. `After:` names only a real wait, with its reason.
- Tier: the planner's judgment of the plan's size, which sets the estimate's final revision and turns on the drift clock;
  no line count decides it.
- Risk (default medium) picks the review: low = approve-only flash, medium = the reviewer-opus55 agent, high = the
  reviewer-opus55 agent and a flash review from another model family, both of the same change. High: untrusted
  input, scores or thresholds, security, money, data deletion or concurrency.
- Files: every changed file with behavior, exact paths, comma-separated; scope is enforced during the run only on
  OpenCode, and every run's report checks it (OUT OF SCOPE); the run lock lets phases whose Files and Follow-through
  are disjoint run in one checkout at once. Only planner phases list the repo's `Cases:` file.
- Follow-through: patterns for the files that change only because the phase's change requires it and carry no
  behavior of their own: docs that describe the changed code, build source lists, generated notes. They join the
  write scope, the lock and the drift check, and the run's report lists the ones changed (`follow-through:`). Never
  tests, fixtures, grading files or the `Cases:` file: a Test plan Home file stays a grading file whatever a pattern
  covers.
- Split: a ticket whose parts can land and be reviewed apart gets a `## Split` table instead of phases,
  `| Child | Done when | Files | Interface it gives the others | After |`, one row per child ticket. It is verified
  and approved once; each child then gets its own plan and run (`/concord:run`, "A large ticket").
- Notes: the dispatcher inlines each pointer's current code into the executor's task, resolving functions by name, as
  line numbers drift between runs.
- Acceptance: fast, deterministic offline commands in backticks that check behaviour, not wiring, tell right from
  plausible wrong code, and fail on the untouched code (red run) unless marked `(characterization)`. A
  behaviour-preserving phase sets `Baseline: pass`, optionally `Characterize: <command>` (output diffed before and
  after). Acceptance leaves the checkout as it found it (exit 7 otherwise): output goes to ignored paths or to
  cache output (built-in names and the `generated` setting).
- Test plan: the rows and actions follow the `concord:lean-testing` skill. `Tests:` is a planning estimate: the report
  prints it beside the actual test lines and it decides nothing. Home names the test file: an executor phase that changes a Home file its Files: does
  not list is rejected and cannot pass (exit 7).
- One phase: about 5 files and 7 steps at most; Notes, Interfaces, Decisions, Out of scope only when needed.
-->
