# Concord reference

*The commands, exit codes, failure causes, records and components in one place. How a ticket runs: [WORKFLOW.md](WORKFLOW.md); installation and executors: [SETUP.md](SETUP.md).*

## Commands

In a shell:

```bash
python3 ~/.claude/concord/wt.py new <TICKET>            # one git worktree per ticket, on its own branch
python3 ~/.claude/concord/concord.py --pr-status <PR>   # exits 0 only when the PR's current diff is REVIEWED
python3 ~/.claude/concord/concord.py --help             # every dispatcher command
```

Concord never commits, pushes or changes branches in your checkout; `wt.py` creates and removes worktrees only when you ask.

In Claude Code, inside the ticket's worktree:

| Command | What it does |
|---|---|
| `/concord:run execute <task>` | Plan, open questions, verifier, your go; then this session writes every phase |
| `/concord:run delegate <task>` | The same, with each phase on the executor the plan assigns |
| `/concord:run delegate --plan PLAN_<ticket>.md <phase>` | Continues an approved plan from where its records stand; `all` instead of a phase number runs every phase that needs a run |
| `/concord:plan-then-delegate <task>`, `/concord:delegate <phases>` | The former entry points; both call `/concord:run delegate` |
| `/concord:rules-review` | The weekly rules review |

The five skills also work on their own, without a ticket: `/concord:design-review` (the callers a change affects and the choices that are the owner's), `/concord:plan` (a plan draft), `/concord:verify-plan` (a fresh verifier), `/concord:lean-testing` (the smallest check that catches the regression) and `/concord:review-change` (findings on any diff, branch or pull request). [SETUP.md](SETUP.md#names) lists the exact names in each install mode.

The dispatcher commands that `/concord:run` calls, and that you can run by hand in any harness:

| Command | What it does |
|---|---|
| `concord.py [MODEL] PHASE --plan PLAN` | Runs one phase on an executor; without MODEL, the phase's `Executor:` line decides, then `default` in `models.conf` |
| `concord.py --lint PHASE --plan PLAN` | Checks a phase without a model call and writes the plan read that the verifier reads (`PLAN-READ: <path>`) |
| `concord.py --plan-verdict FILE --plan PLAN` | Records the verifier's answer; an APPROVE binds to the hash of the plan read it quotes |
| `concord.py --estimate --plan PLAN` | Phase minutes from the run ledger, the lanes, the critical path and the ETA |
| `concord.py --begin PHASE` and `--end RUN` | Open and close a session run, for a phase the planner or a Claude implementer writes |
| `concord.py --verdict RUN PASS\|FAIL [--cause CAUSE] [--note TEXT]` | Records the phase's outcome |
| `concord.py --grade RUN` | After a cleanup or a fix outside a run, grades the checkout as the run's new candidate |
| `concord.py --review RUN [--packet]` | A read-only review of a run's graded change by a low-cost model or, with `--packet`, a prompt for a Claude reviewer agent |
| `concord.py --review-record RUN --reviewer NAME --file FILE` | Stores a Claude reviewer's answer on the run |
| `concord.py --review-pr PR [--delta] [--tier TIER]` | A read-only review of an open pull request at its head |
| `concord.py --phases`, `--report`, `--drift` | The state of each approved phase, the test report, the drift against the plan |
| `concord.py --restore RUN`, `--abort RUN` | Put back the in-scope files a run changed, where they are still as it left them; release a session run without a report |
| `concord.py --resolve NAME`, `--models [--verify]` | How a model name resolves; the model registry, checked against the public catalogs with `--verify` |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success; for `--pr-status`, the current head is REVIEWED |
| 1 | `--pr-status`: the head is short of REVIEWED; `--plan-verdict`: a REVISE verdict, nothing recorded |
| 2 | Usage, plan or lock; a review answer that quotes no packet of its run; a PASS given from a checkout other than the run's; `--report` while a run of the plan is open or has no verdict; a `--tier` below a file's needed tier |
| 3 | A Claude model on the run path, or a tool (git, gh) missing or failing |
| 4 | Unknown model; `--fork-graded` on a fork, or toward a destination, with an open run |
| 5 | Billing guard: a Claude model sent to another harness, or a harness started without an explicit non-Claude model |
| 6 | Red run: an acceptance command already passes before the change, so the executor never started |
| 7 | PASS refused: an acceptance result missing or not the expected one, a rejected run, a post-run command that changed the tree or a grading file, or a checkout that no longer holds the graded candidate or the grading files it was graded with (content and executable bit); also `--grade` refused because the checkout differs from the run's start outside its write scope |
| 8 | A full review of a pull request past the cap of three reviewed heads; your words through `--user-approved` lift it |
| 9 | A provider refused a review; nothing was recorded |
| 10 | Drift block, or a plan whose report is written |
| 11 | No plan-verifier APPROVE for this plan text, or a stored plan read changed after its APPROVE |
| 75 | The pull request's head is unsettled or unverified: gh reports one head and the fetched pull ref another, or one of the two cannot be read; nothing is judged or written, so run again |
| 124 | Timeout |
| 125 | Resource limit: the run watchdog stopped the run, or free disk was below the floor |

## Failure causes

Every FAIL verdict takes a cause with `--cause`. A FAIL recorded without one is kept, with a reminder to add it.

| Cause | Meaning | What follows |
|---|---|---|
| EXECUTOR | The executor's own mistake | The only cause that counts as an attempt: the same implementer retries with the evidence, and after three EXECUTOR failures of a phase the planner stops and asks you |
| PLAN_GAP | The plan lacked a decision, a file or a fact | The planner restores the files, fixes the plan, has it verified again and retries |
| TEST_DEFECT | The test, not the code, was wrong, for example an acceptance command that passed although the requirement was not met | The tests are fixed |
| FLAKY | A result that changes on a rerun | The tests are fixed |
| PROVIDER | The model provider refused the call or hit a limit | The next model runs |
| BLOCKED | The executor stopped on a question the plan did not settle | The answer goes into the plan and the phase runs again; not an attempt. The dispatcher refuses a second BLOCKED on the same phase and asks for PLAN_GAP |

## Records

- **Run folders:** `<git-common-dir>/concord/<run-id>/`, outside the working tree: the run's start state, its report, its verdict and its review packets.
- **Plan reads:** `<git-common-dir>/concord/plan-reads/<hash>.md`, the text a verifier read, named by the hash its APPROVE quotes.
- **Review ledgers:** `<git-common-dir>/concord/ledger/`, every finding with the review that raised it and the review that closed it.
- **Test reports:** `<git-common-dir>/concord/reports/REPORT_<ticket>-<id>.md`, where `<id>` is the first eight characters of the ticket id. A report opens with the overrides, such as each forced PASS beside its failed commands, the `--user-approved` words and their use, exclusion waivers, runs without a red run or a sandbox, a PASS over out-of-scope changes, each PASS whose phase a later revision changed, phases reviewed below their risk and high-risk phases without a review from another model family. Then come the phases (who wrote each, the plan revision its run followed, the graded candidate and its review), the Test plan, the test lines beside the `Tests:` estimate, the review rounds, the open items for the DAT and the time against the ETA.
- **Run index:** `~/.claude/concord/runs.jsonl`, beside the installed dispatcher: every run and verdict across repositories, written on a best-effort basis and read by `--estimate`.

## Components

| Path | Installs to | What it is |
|---|---|---|
| `concord/concord.py` | `~/.claude/concord/` | The dispatcher: runs one plan phase on one executor, reports the evidence, reviews it, records the verdict |
| `concord/wt.py` | `~/.claude/concord/` | One git worktree per ticket; links large untracked folders from the main checkout |
| `concord/CONTRACT.md` | `~/.claude/concord/` | The contract every executor reads first: twelve rules and the report format |
| `concord/PLAN_TEMPLATE.md` | `~/.claude/concord/` | The plan format |
| `concord/REVIEW.md` | `~/.claude/concord/` | The review task: three closed questions, severities, the REVIEW-JSON format |
| `concord/*.conf` | `~/.claude/concord/` (kept if present) | Model registry and billing routes, harness settings, worktree links, prose style |
| `concord/tests/` | `~/.claude/concord/tests/` | The regression suites; `run_all.sh` runs them in parallel with a fake HOME |
| `adapters/claude-code/` | Claude Code, as the `concord` plugin | `/concord:run` (execute or delegate mode), the skills `concord:design-review`, `concord:plan`, `concord:verify-plan`, `concord:lean-testing` and `concord:review-change`, the wrappers `/concord:plan-then-delegate` and `/concord:delegate`, `/concord:rules-review`, and the implementer, verifier and reviewer agents; also four hook rules (`install.sh --repo`), and the CLAUDE.md rules block and settings keys the installer writes |
| `scripts/demo.sh`, `examples/` | Nowhere | The credential-free demo and its plan |
| `scripts/figures.py` | Nowhere | Writes the dark twin of each figure, the wordmark and the demo card from its light SVG by swapping every color for its dark token. `--check` fails when a twin is missing, stale or has no light file, or a light SVG uses a color outside the token table. After editing a figure, run `python3 scripts/figures.py --write` |
| `tests/` | Nowhere | The repository's own checks: `package_test.sh` (scrub, layout, agents, Python, install, style, hygiene, docs) and `demo_test.sh` |
| `docs/` | Nowhere | Setup, the workflow, this reference, the comparison, the pilot, figures |

## The four outcomes

The rules block that the installer writes into `~/.claude/CLAUDE.md` holds four outcomes firm and leaves the decomposition, the executors and the order to the planner within the approved scope:

- **Governance.** The owner settles consequential behavior and architecture decisions, however small the change; review judges the design that was approved.
- **Testing.** Every changed behavior and path is accounted for; a test stays when it catches a failure the rest of the suite would miss where it matters.
- **Code quality.** An independent reviewer examines each consequential change and its affected callers; a design failure stays visible until it is resolved.
- **Truthful outcomes.** PASS and REVIEWED mean what they say, a waiver names its scope, and recovery keeps the user's work.
