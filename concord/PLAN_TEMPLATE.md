# Plan: <task title>

## Map
<!-- concord.py --map PLAN renders this (status per work item); --lint checks it. IDs: I intent, S structure, P work. -->
### Intent
- I1 <why this ticket; metric it moves; invariants it must not break; non-goals>   (at most 6)
### Structure
- S1 <- I1 <a part that changes and how it connects to the rest>                   (at most 8)
### Work
- P1 <- S1 <phase; executor; risk; after P..>                                      (at most 8)
- P2 <- S1 <phase; executor; risk; after P1>
- P3 <- S1 <phase; executor; risk; after P2>

## Executors (review before approving)
| Phase | Executor | Risk | Runs as | Billed to | Review | Why this executor |
|---|---|---|---|---|---|---|
| 1 | planner | - | this session | Claude subscription | flash (tests checklist) | writes the failing tests (never the implementer) |
| 2 | deepseek-flash | medium | OpenCode, opencode-go/deepseek-v4.1-flash | OpenCode Go allowance | flash loop + Opus 4.8 (subscription) | well-specified change, discriminating tests exist |
| 3 | deepseek-flash | high | OpenCode, opencode-go/deepseek-v4.1-flash | OpenCode Go allowance | flash loop + Opus 5.5 (subscription) | multi-file change, split small with strong tests (always flash) |

## Open questions
- <anything the planner could not settle from the code; answered by the user before approval, or "none">
- Qn -> Sn <when a question blocks a map node, name it so --map shows the node as blocked>

## Outcome (settled before approval)
- Metric: <the overall metric this ticket moves, or a proxy shown to correlate with it>
- Baseline: <value now, and the command or report it comes from>
- Expected move: <direction and rough size; no expected move = cut the item>
- Guardrails: <what must not get worse; each guardrail is also an acceptance command>
- Validation: <benchmark or test that measures the move, run before and after>
- Minimal case: <the smallest version that moves the metric; generality goes under Out of scope with a safe fallback>

## Context
- Problem: <what is wrong or missing, with evidence>
- Decisions already made: <constraints the executor must not revisit>
- Repo facts: <test runner, entry points, conventions; see ~/.claude/concord/repo-notes/<repo>.md>

## Phase 1 - Failing tests for <behaviour> (P1 <- S1)
Executor: planner
Purpose: pin the intended behaviour before anyone implements it.
Files: tests/test_module.py
Baseline: skip
Steps:
1. Add tests that FAIL now and distinguish the intended behaviour from the current one and from the obvious wrong fix.
2. Keep only tests that pass the three-question filter (see rules below).
Acceptance:
- `pytest tests/test_module.py -q` (must fail now, for the intended reason, until Phase 2)
Out of scope: implementation files.

## Phase 2 - <short name> (P2 <- S1)
Executor: deepseek-flash
Risk: medium
Purpose: <one sentence: what this phase achieves and why>
Files: path/to/module.py
Context: path/to/caller.py, path/to/config.yaml, tests/test_module.py   (read-only: the callers, callees, configs and tests the executor must consult; never edit)
Interfaces:
- `def parse(raw: str) -> Result` (new) - raises `ValueError` on empty input
Inputs:   (goal posts, fixed here; `--lint` checks it; missing on an implementing phase = a report note)
- raw: `key=value` text from the config file (untrusted). Classes: well-formed; empty; whitespace-only;
  missing `=`; non-UTF-8 bytes. Expected: Result / ValueError / ValueError / ValueError / UnicodeDecodeError.
- documented failure classes of the platform the code calls (e.g. read fails with OSError) and the behaviour.
  Tests = seeded generators per class (property-based) and randomized fault injection over the failure classes,
  one acceptance command per new test where the runner allows it (pytest node id, ctest -R name).
Steps:
1. <concrete change, naming functions/lines where possible>
2. <...>
Example: `parse("a=1")` -> `Result(key="a", value=1)`
Edge cases: empty string -> ValueError; whitespace-only -> ValueError
Decisions: <binding structure: which layer/module owns this, dependency direction; "none" if no new modules>
Budget: 60 lines
Acceptance:
- `pytest tests/test_module.py -q`
- `python3 -c "import module; assert not hasattr(module, 'requests')"`  (structural check, when Decisions is not "none")
- `pytest tests/test_existing.py -q` (characterization)   <- a command that already passes before the change MUST
  carry this marker, or the dispatcher refuses to start (exit 6); never put prose with backticks under Acceptance
Out of scope: <tempting changes the executor must not make>

## Phase 3 - <refactor name> (no behaviour change) (P3 <- S1)
Executor: deepseek-flash
Risk: low
Purpose: <why the structure changes; behaviour must not>
Files: path/to/module.py, path/to/new_helper.py
Context: tests/
Baseline: pass
Characterize: `python3 scripts/dump_outputs.py tests/fixtures/inputs/`
Budget: 80 lines
Acceptance:
- `pytest -q`
Out of scope: any change in output; renames outside Files.

## Handoff (updated after every phase; the next session reads it first)
- Changed: <file - why, one line each>
- Checks ran: <command - result>
- Checks NOT run: <command - reason>
- Risks and open points: <what remains uncertain>
- Next reads: <files and documents the next session needs first>

<!--
Rules for the planner (evidence: docs/WORKFLOW.md in the Concord repository):
- Map first: I<n> intents (why, metric, invariants, non-goals), S<n> structure (parts that change, `<- I..`),
  P<n> work (phases, `<- S..`, executor, risk, `after P..`). Each phase heading carries its ID `(P<n> <- S<n>)`
  and an open question that blocks a node names it (`Q<n> -> S<n>`). `concord.py --map PLAN` renders the tree with
  per-phase status; `concord.py --lint` prints MAP LINT warnings (orphan node, cap exceeded, phase without an ID).
- Executor = a name from ~/.claude/concord/models.conf (check: concord.py --resolve "<name>").
  sonnet / haiku / opus always mean the concord:implementer subagent on the Claude subscription; planner = this session.
- Tests before implementation, by a different executor than the one implementing.
- Three-question filter for every test: (1) would it stop a defect reaching users? (2) does it fail only when
  behaviour breaks, not when internals are restructured? (3) is it fast enough to run on every attempt?
  Tests that pin wiring, call order or private structure are waste; assert behaviour.
- Red run: acceptance must FAIL on the untouched code before an implementing phase (Baseline: fail, the
  default); the dispatcher checks this and refuses to spend credits when it does not. Behaviour-preserving
  phases set `Baseline: pass`; test-writing phases set `Baseline: skip`.
- Risk sets how hard the verifier checks: low = acceptance + diff + flash review loop; medium = + the wider test
  suite, a short input probe (empty, very long, special characters, combinations) and one Opus 4.8 review round
  (concord:reviewer-opus48, Claude subscription); high = + property tests written in the test phase (seeded, bounded), a
  mutation probe and one Opus 5.5 review round (concord:reviewer-opus55). High whenever the code parses untrusted input
  (message text, URLs, files), sets scores or thresholds, touches security, money, data deletion or concurrency. Show the
  reviewer per phase in the Executors table ("Review" column) so the user sees the subscription spend.
- Budget = rough upper bound on changed lines (about 2x your estimate); the report flags overruns.
- Behaviour-preserving phases get a Characterize command: deterministic output over a fixed input corpus,
  captured before and after the run and diffed. Goldens never come from the implementer's output.
- Structural checks (Decisions) stay one-off acceptance commands; never commit tests that pin structure.
- Purpose / Interfaces / Example / Edge cases are the vocabulary that raises cheap-model pass rates;
  exact signatures and one worked example matter more than prose. The report checks Interfaces verbatim.
- Executors cannot ask questions. Every ambiguity goes under "Open questions" and is settled before approval.
- One phase = one independently verifiable change; roughly 5 files and 7 steps or fewer.
- List exact file paths (no annotations in parentheses; commas between paths). The dispatcher flags any change
  outside Files:, and on OpenCode the harness refuses such edits outright, so an incomplete list makes the
  executor report BLOCKED (a plan gap, not an executor failure).
- Files: must be complete (every file that changes) and Context: must name the dependencies the
  executor needs to read (callers, callees, configs, tests). `concord.py --lint <phase>` checks both.
- Acceptance commands must be deterministic, runnable offline, written before execution, and able to
  distinguish the right implementation from plausible wrong ones.
- Decisions + a structural acceptance check whenever a phase adds a module or crosses a layer.
- Say what is out of scope; weaker executors drift toward "helpful" extra edits.
-->
