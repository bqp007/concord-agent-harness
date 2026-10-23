# Plan: <ticket title>

Done when: <the result in a sentence or two, and the command or number that shows it>
Ship: <PR to <branch>, or no PR and why>

## Open questions
- Q1 <what the code cannot settle; the user answers before approval, or "none">

## Phase 1 - Failing tests for <behaviour>
Executor: planner
Risk: low
Files: tests/test_module.py
Baseline: skip
Steps:
1. Tests that fail now and tell the intended behaviour from the current one and from the obvious wrong fix.
Acceptance:
- `pytest tests/test_module.py -q` (fails until Phase 2)

## Phase 2 - <short name>
Executor: free-deepseek-flash
Risk: medium
Files: path/to/module.py
Steps:
1. <the change, naming functions or lines>
Interfaces:
- `def parse(raw: str) -> Result` (new): raises `ValueError` on empty input
Decisions: <choices the executor must not revisit>
Acceptance:
- `pytest tests/test_module.py -q`
- `pytest tests/test_existing.py -q` (characterization)
- `git diff --quiet HEAD -- include/` (characterization: nothing outside Files changes)
Out of scope: <tempting edits the executor must not make>

## Handoff (only when another session runs the plan)
- <settled decisions and what the investigation learned>

<!--
- Executor: planner (this session: small changes, docs) or a models.conf name (`concord.py --resolve "<name>"`), free
  models first.
- Risk picks the reviewer: low = flash, medium (the default) and high = concord:reviewer-opus55. High when the code
  parses untrusted input, sets scores or thresholds, or touches security, money, data deletion or concurrency.
- Files: every file that changes, exact paths, commas between them; OpenCode refuses edits outside them.
- Acceptance: deterministic offline commands in backticks that tell the right implementation from plausible wrong
  ones. They must fail on the untouched code (red run, exit 6) unless marked `(characterization)`; a phase that
  preserves behaviour sets `Baseline: pass` and may add `Characterize: <command>` (output diffed before and after).
  Never `test -z "$(git diff ...)"`.
- Tests assert behaviour, not wiring, and run fast; edge cases live in the tests, not in the plan.
- One phase: about 5 files and 7 steps at most. Interfaces, Decisions and Out of scope only when needed.
-->
