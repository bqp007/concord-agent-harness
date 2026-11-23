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
- The schedule (`## Passes`) and its diagram: `/concord:plan-then-delegate` steps 3 and 7. The planner writes `Size:` and `After:`, never
  minutes; `--estimate` turns them and the run ledger into minutes. `After:` names only a real wait, with its reason.
- Tier: the planner's judgment of the plan's size, which sets the estimate's final revision and turns on the drift clock;
  no line count decides it.
- Risk (default medium) picks the reviewer: low = approve-only flash, else concord:reviewer-opus55. High: untrusted
  input, scores or thresholds, security, money, data deletion or concurrency.
- Files: every changed file, exact paths, comma-separated; scope is enforced during the run only on OpenCode, and every
  run's report checks it (OUT OF SCOPE); the run lock lets phases with disjoint Files run in one checkout at once. Only planner phases list the repo's `Cases:` file.
- Notes: the dispatcher inlines each pointer's current code into the executor's task, resolving functions by name, as
  line numbers drift between runs.
- Acceptance: fast, deterministic offline commands in backticks that check behaviour, not wiring, tell right from
  plausible wrong code, and fail on the untouched code (red run) unless marked `(characterization)`. A
  behaviour-preserving phase sets `Baseline: pass`, optionally `Characterize: <command>` (output diffed before and
  after). Acceptance leaves tracked files and the phase's Files as it found them (exit 7 otherwise): output goes to
  ignored or untracked paths.
- Test plan: one row per touched behavior; ADD only when no test covers it. `Tests:` is a planning estimate: the report
  prints it beside the actual test lines and it decides nothing. Home names the test file: an executor phase that changes a Home file its Files: does
  not list cannot pass (ACCEPTANCE FILES CHANGED, exit 7).
- One phase: about 5 files and 7 steps at most; Notes, Interfaces, Decisions, Out of scope only when needed.
-->
