# Plan: <ticket title>

Tier: <S|M|L>
Size: ~<N> lines
Done when: <the result and the command or number showing it>
Ship: <PR to <branch>, or no PR and why>

## Open questions
- Q1 <what the code cannot settle, or "none">

## Phase 1 - Failing tests for <behaviour>
Executor: planner
Risk: low
Files: tests/test_module.py
Baseline: skip
Steps:
1. Failing tests that tell the intended behaviour from the current one and the obvious wrong fix.
Acceptance:
- `pytest tests/test_module.py -q` (fails until Phase 2)

## Phase 2 - <short name>
Executor: free-deepseek-flash
Risk: medium
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
```text
Phase 1  planner  10 min ──> Phase 2  free-deepseek-flash  20 min
```
ETA: <N> min (critical path), lands at <hh:mm> local

## Handoff (if another session runs it)
- <settled decisions, what the investigation learned>

<!--
- Passes and their diagram: `/concord:plan-then-delegate` steps 3 and 5.
- Risk (default medium) picks the reviewer: low = approve-only flash, else concord:reviewer-opus55. High: untrusted
  input, scores or thresholds, security, money, data deletion or concurrency.
- Files: every changed file, exact paths, comma-separated; OpenCode refuses edits outside them.
- Notes: the dispatcher inlines each pointer's current code into the executor's task, resolving functions by name, as
  line numbers drift between passes.
- Acceptance: fast, deterministic offline commands in backticks that check behaviour, not wiring, tell right from
  plausible wrong code, and fail on the untouched code (red run) unless marked `(characterization)`. A
  behaviour-preserving phase sets `Baseline: pass`, optionally `Characterize: <command>` (output diffed before and
  after).
- One phase: about 5 files and 7 steps at most; Notes, Interfaces, Decisions, Out of scope only when needed.
-->
