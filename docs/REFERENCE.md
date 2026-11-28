# Concord reference

*The commands, exit codes, failure causes, records and components in one place. How a ticket runs: [WORKFLOW.md](WORKFLOW.md); installation and executors: [SETUP.md](SETUP.md).*

## Commands

In a shell:

```bash
python3 ~/.claude/concord/wt.py new <TICKET>            # one git worktree per ticket, on its own branch
python3 ~/.claude/concord/concord.py --pr-status <PR>   # exits 0 only when the PR's current diff is REVIEWED
python3 ~/.claude/concord/concord.py --help             # every dispatcher command
```

Concord never commits to a branch, pushes or changes branches in your checkout; `wt.py fork` writes one commit object, a snapshot of the working state that no branch or ref points to (`git gc` prunes it once the fork is removed), and `wt.py` creates and removes worktrees only when you ask.

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
| `concord.py --plan-verdict FILE --plan PLAN` | Records the verifier's answer, which must hold exactly one VERDICT line and one PLAN-HASH line; an APPROVE binds to the hash of the plan read it quotes |
| `concord.py --estimate --plan PLAN` | Phase minutes from the run ledger, the lanes, the critical path and the ETA; ESTIMATE LINT lines name the waits it ignores |
| `concord.py --begin PHASE` and `--end RUN` | Open and close a session run, for a phase the planner or a Claude implementer writes; `--end` refuses an executor run, a run begun in another checkout and a run whose session lock is gone |
| `concord.py --verdict RUN PASS\|FAIL [--cause CAUSE] [--note TEXT]` | Records the phase's outcome |
| `concord.py --grade RUN` | After a cleanup or a fix outside a run, grades the checkout as the run's new candidate with the acceptance, characterization and static checks; it needs the checkout to itself |
| `concord.py --review RUN [--packet]` | A read-only review of a run's graded change by a low-cost model or, with `--packet`, a prompt for a Claude reviewer agent |
| `concord.py --review-record RUN --reviewer NAME --file FILE` | Stores a Claude reviewer's answer on the run |
| `concord.py --review-pr PR [--delta] [--tier TIER]` | A read-only review of an open pull request at its head |
| `concord.py --phases`, `--report`, `--drift` | The state of each approved phase; the test report, a status export written once every run of the plan has a verdict, which does not require a PASS for every phase or a review of the final tree; the drift against the plan |
| `concord.py --restore RUN`, `--abort RUN` | Put back the in-scope files a run changed, where they are still as it left them, links as links, with the checkout to itself (exit 1 on a partial restore, naming what is left); close an open run without a report, stopping a live executor run first |
| `concord.py --mutate RUN [--mutants FILE]` | Opt-in mutation testing of a reported run's changed lines (Python, C/C++) in a grading copy of its candidate; each mutant runs the acceptance commands until one gives another result than expected. On a command expected green, any non-zero exit kills the mutant except 126 and 127 (invalid) and 124 (a timeout); on a command expected red, a failing test is the expected result, exit 0 kills the mutant and any other exit is invalid |
| `concord.py --resolve NAME`, `--models [--verify]` | How a model name resolves; the model registry, checked against the public catalogs with `--verify` |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success; for `--pr-status`, the current head is REVIEWED |
| 1 | `--pr-status`: the head is short of REVIEWED, has no changed file or is not open; `--plan-verdict`: a REVISE verdict, nothing recorded; `--restore`: a partial restore; `--fork-graded`: the fork has no Concord run, or no run passed with the fork as its candidate |
| 2 | Usage, plan or lock, including a declared path that is absolute or has a `..` part and a lock file that cannot be read; `--grade` or `--restore` while a live run holds the lock; `--end` of an executor run, of a run begun in another checkout or of one without its session lock; `--abort` of a run that has a report or that another existing checkout began, or whose executor outlives SIGKILL (the lock is kept); a verifier answer with more than one VERDICT or PLAN-HASH line; a review answer that quotes no packet of its run or lacks its findings, clauses, tests or verdict; a PASS given from a checkout other than the run's; `--report` while a run of the plan is open or has no verdict; a `--tier` below a file's needed tier; `--review-pr` of a closed or merged PR or of one with no changed file; a delta review of a fix that rewrites a file; `--mutate` of a run with no candidate |
| 3 | A Claude model on the run path, or a tool (git, gh) missing or failing; a model review that ended with no usable answer (its process failed, or its answer did not parse after the retry); `--check` with git missing, or a harness binary that `executors.conf` names missing |
| 4 | Unknown model; `--fork-graded` on a fork, or toward a destination, with an open run |
| 5 | Billing guard, a filter on the model id's text: a model id with the word `claude`, `anthropic`, `sonnet`, `opus` or `haiku` sent to another harness, or a harness started without an explicit model |
| 6 | Red run: an acceptance command already passes before the change, so the executor never started |
| 7 | PASS refused: an acceptance result missing or not the expected one, a rejected run, a post-run command that changed the tree or a grading file, a checkout that no longer holds the graded candidate or the grading files it was graded with (content and executable bit), or a checkout that differs from the state the run was graded in besides its tree (HEAD, branch, index, git internals, the watched files outside the checkout, the plan, permission bits, ignored files in the write scope); also `--grade` refused because the checkout differs from the run's start outside its write scope, including the plan of a run that may not write it |
| 8 | A full review of a pull request past the cap of three reviewed heads; your words through `--user-approved` lift it |
| 9 | A provider refused a review; nothing was recorded |
| 10 | Drift block, or a plan whose report is written |
| 11 | No plan-verifier APPROVE for this plan text, or the stored plan read of the approved revision is gone, unreadable or changed after its APPROVE |
| 75 | The pull request's head is unsettled or unverified: gh reports one head and the fetched pull ref another, or one of the two cannot be read, gh's included; nothing is judged or written, so run again |
| 124 | Timeout |
| 125 | Resource limit: the run watchdog stopped the run, or free disk was below the floor |
| 130 | A delegate run interrupted (Ctrl-C, or the SIGTERM or SIGHUP that `--abort` sends): the executor was stopped and its lock released |

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

- **Run folders:** `<git-common-dir>/concord/<run-id>/`, outside the working tree: the run's start state, the executor's prompt (`prompt.txt`; `cmd.json` holds the command with the prompt left out), its raw output (`output.log`), the red-run and acceptance output tails, the backups of the in-scope files and the pinned grading inputs, the approved plan text, its report, its verdict and its review packets and answers. The runs folder and each run folder are created owner-only (0700); the files inside keep your umask's mode, a runs folder made by an earlier version keeps its mode, and nothing is pruned.
- **Plan reads:** `<git-common-dir>/concord/plan-reads/<hash>.md`, the text a verifier read, named by the hash its APPROVE quotes.
- **Review ledgers:** `<git-common-dir>/concord/ledger/`, every finding with the review that raised it and, for a pull request, the review that closed it.
- **Test reports:** `<git-common-dir>/concord/reports/REPORT_<ticket>-<id>.md`, where `<id>` is the first eight characters of the ticket id. A report opens with the overrides, such as each forced PASS beside its failed commands while that PASS stands, a PASS with no acceptance command or (a session run) no change, the `--user-approved` words and their use, exclusion waivers, each red run skipped (`--no-baseline`, `Baseline: skip`, `baseline = no`) or forced over with `--force`, unsandboxed runs, a PASS over out-of-scope changes, each PASS whose phase a later revision changed, and each file of a phase that no review at its tier read, or at high no review from another model family. Then come the phases (who wrote each, the plan revision its run followed, the graded candidate, the acceptance results the verdict judged as `n/m pass`, or `n/m as expected` when a command is expected red, and its review), the Test plan, the test lines beside the `Tests:` estimate, the review rounds, the open items for the DAT and the time against the ETA.
- **Run index:** `~/.claude/concord/runs.jsonl`, beside the installed dispatcher: every run and verdict across repositories, a forced PASS marked as forced, written on a best-effort basis and read by `--estimate`.

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
| `site/` | Nowhere; GitHub Pages serves it | The website: `index.html`, the explainer that plays one ticket's loop step by step, and `map/index.html`, the interactive map of every command, skill, agent and record, which reads its data from `map/data.js` |
| `scripts/site_map.py` | Nowhere | Builds `site/map/data.js` from the map's nodes, views and edges in the script and from the repository: the front matter of the adapter's commands, skills and agents, and the help text of `concord.py` and `wt.py`. `--check` fails when `data.js` differs from a fresh build, a node's source file is missing, or a command, skill or agent has no node. Run `--write` after changing a command, skill or agent, the help text of `concord.py` or `wt.py`, or the map's nodes |
| `.github/workflows/pages.yml` | Nowhere | Publishes `site/` to GitHub Pages on each push to `main` that changes `site/` or the workflow, and when run by hand |
| `tests/` | Nowhere | The repository's own checks: `package_test.sh` (scrub, layout, agents, Python, install, style, hygiene, docs, site) and `demo_test.sh` |
| `docs/` | Nowhere | Setup, the workflow, this reference, the comparison, the pilot, figures |

## The four outcomes

The rules block that the installer writes into `~/.claude/CLAUDE.md` holds four outcomes firm and leaves the decomposition, the executors and the order to the planner within the approved scope:

- **Governance.** The owner settles consequential behavior and architecture decisions, however small the change; review judges the design that was approved.
- **Testing.** Every changed behavior and path is accounted for; a test stays when it catches a failure the rest of the suite would miss where it matters.
- **Code quality.** An independent reviewer examines each consequential change and its affected callers; a design failure stays visible until it is resolved.
- **Truthful outcomes.** PASS and REVIEWED mean what they say, a waiver names its scope, and recovery keeps the user's work.
