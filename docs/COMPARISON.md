# How Concord compares

Concord grew out of reading other workflows and papers, keeping what held up in daily use. This page sets it beside the systems it learned from, each read against the same questions: the unit of work, who plans and who writes code, where a human decides, what evidence a run leaves, who reviews, which rules code enforces rather than a prompt requests, isolation, learning, cost and results. The facts come from each project's source or paper as read on 21 October 2026; only Concord itself was run.

<p align="center"><img src="figures/fig0-concord-layers.svg" alt="Concord's governance layers and which of them this repository builds" width="760"></p>

## At a glance

| | Where a human decides | Evidence a run must leave | Who reviews | Enforced by code, not by a prompt |
|---|---|---|---|---|
| Concord | approves every plan; commits | the dispatcher's report (scope, red run, acceptance re-run) and a verdict with a cause | a fresh agent, once, at the change's risk tier | red run, acceptance-file hashes, attempt cap, PR review tier, billing guard; edit scope and no web on OpenCode |
| ECC | `/plan` asks for approval before code; the orchestration pipeline adds a gate before commit (both prompt text) | test-first and verification skills write reports quoting real commands | a separate reviewer agent; cross-provider and adversarial reviews on request | hooks that block `--no-verify`, protect config files and gate a first edit |
| agentic-sdlc | three sign-offs (advisory); git commands ask first | gate reports quoting command, exit code and runner summary | a separate reviewer agent on the session's model | a hook that asks before commit, tag, push and publish (it fails open by design); strike counters in a state script |
| agent-protocols | none required | checklists inside the skills | an optional persona | nothing |
| Claude Code built-ins | permission prompts; plan approval | none built in | optional: subagents, `/code-review`, a second session | permission rules, hooks, plan mode's edit block, an OS sandbox for the shell, worktrees |
| Harness² | none during a run | a ledger that must reach a fixed number of rollouts | an anonymized selector; on one benchmark the judge and the editor are the same model | grader verdicts kept out of the improver's context; turn and time caps |
| MetaGPT | none during a run | unit tests, three retries | the author checks its own work | stage order, retry cap |
| ChatDev | none during a run | execution feedback and a static review | the same model in a reviewer role | phase order, round cap |

## Claude Code, the host

Concord runs inside Claude Code and leans on its real enforcement: subagents for reviewers with a fresh context, hooks (through the hookify plugin) for the four rules that block destructive git commands, recursive deletes outside a scratch folder and writes to a shared `PLAN.md`, and git worktrees for one ticket per checkout. What Claude Code does not provide is a lifecycle around a change: no plan format, evidence record, mandatory review or ledger. Concord fills that gap.

## Plugins for the same host

ECC is the largest of them: 71 agents, 311 skills and 27 hook registrations, installed from a plugin marketplace or npm, with tooling tests across 33 CI jobs and a large community. A few of its hooks really block (`--no-verify`, config protection, a first-edit gate); its plan approval, test-first order and review delegation are prompt text, and fully independent review is opt-in (`/santa-loop`, `/orch-review`). Its report on its own first-edit gate is unusually candid: the benefit was "not established". Concord started next to ECC, and both refuse to let a finding block without proof. When ECC was switched off, mainly for the roughly 33,000 tokens its catalog added to every session on our setup, Concord's four hook rules moved to the hookify plugin unchanged.

agentic-sdlc drives a seven-phase lifecycle with 35 subagents, persisted state and resumable phases. Its strongest idea is evidence that quotes the command, exit code and runner summary instead of a claim; Concord re-runs the acceptance commands itself. agent-protocols is a set of 25 concise skills and seven commands, such as plan, build, review and ship, with verification checklists and tables that answer the excuses an agent gives for skipping a step; nothing in it is enforced. Both rest mostly on instructions a model may ignore. Concord's bet is that the few rules that matter should fail a run, not ask nicely.

## Multi-agent role play

MetaGPT turns a one-line requirement into a repository through a chain of typed documents (requirements, design, tasks, code, tests) written by agents playing product manager, architect, project manager, engineer and QA engineer. ChatDev runs a chat chain of a CEO, a CTO, a programmer, a reviewer and a tester. Concord keeps MetaGPT's typed hand-off, since its plan file names exact files, interfaces and acceptance commands, and drops the personas. Its four roles differ in what they may do, not in what they are told they are: the planner plans and verifies, the executor edits only its phase's files, the reviewer only reads, the owner approves and commits. In both role-play systems the author or the same model reviews the work; in Concord the reviewer is always an agent that did not write the code.

## Harness evolution and review research

<p align="center"><img src="figures/fig4-papers-to-changes.svg" alt="Eight papers and the change each one made to Concord" width="760"></p>

Several recent papers let an agent rewrite its own harness and keep a change when a score improves. Concord took specific mechanisms from them and left the automatic loop alone:

- **Self-evolving harness:** reviews in a fresh context, re-reading the plan after a context compaction (the paper saw compaction drop the user's request in all 11 runs where it fired), and a line budget on edits to the workflow itself.
- **MILO:** rejected changes are kept as evidence. Concord records every FAIL with its cause and keeps each review's findings in a ledger that later reviewers read.
- **Harmony Harness:** without protection, an agent edited its own evaluation script and reported full marks. Concord hashes the acceptance files and refuses a PASS when any of them changed during the run.
- **Terminal-RSI:** trajectories passed every scenario check yet failed the full verifier. Concord re-runs acceptance after the executor stops and has a TEST_DEFECT cause for failures that come from the test rather than the code.
- **Deep Review:** reviewers each own one segment of a long document but read all of it. Concord built a segmented review of large diffs, then retired it after it added about 400 lines that no daily diff needed; the review cap and the file-group split remain.

Harness² from Google Research evolves a harness for a frozen executor model and keeps a library entry only when behavioural contrasts support it. It has no human gate during a run. Concord borrowed the shape of this repository from it: a short definition, the loop figure, results, a demo that needs no credentials, a citation.

## What Concord skipped on purpose

- **Unattended self-improvement.** Concord changes its own rules only through a ticket the owner approves, under a line budget. Its ledger, a few hundred verdicts, is too small to select changes on.
- **Large catalogs of agents and personas.** They cover more ground, but every description costs context in every session, and most of Concord's failures were plan gaps, which a better plan fixes and another agent does not.
- **Web access for executors.** Harness² leaves the web open and records a rollout that fetched a grading rubric unprompted. On OpenCode, Concord denies the executor's web fetch and reports network use through the shell.

## What Concord still lacks

- **Breadth and one-step install.** ECC and agentic-sdlc cover many more languages and stages. Concord covers one loop, and installs in two steps: a plugin for the commands and agents, which adds about 500 tokens to every session (ECC's catalog added roughly 33,000 on our setup), and a script for the dispatcher.
- **Enforcement outside OpenCode's edit tools.** Claude Code's permission rules, hooks and sandbox act at the tool layer; Concord's scope check covers OpenCode's edit tools, not shell redirection, so the backup taken before every run is the real safety net.
- **A controlled evaluation.** Harness², MILO and Harmony Harness report benchmark results over repeated runs. Concord's numbers come from one developer's ten days, and the same person assigned the failure causes.
- **The rest of the governance model.** A machine-checked contract registry, path reservations before parallel runs, and evidence bound to a hash of the whole checked state; today only the acceptance files are hashed.

## How it grew

<p align="center"><img src="figures/fig0b-timeline.svg" alt="How the workflow grew from 10 to 21 October 2026" width="760"></p>

## Sources

[ECC](https://github.com/affaan-m/ECC) · [agentic-sdlc](https://github.com/orchestratedbyalex/agentic-sdlc-plugin) · [agent-protocols](https://github.com/arneesh/agent-protocols) · [Claude Code documentation](https://code.claude.com/docs/en/overview) · [Harness²](https://github.com/google-research/harness2) ([paper](https://arxiv.org/abs/2610.14224)) · [MetaGPT](https://arxiv.org/abs/2308.00352) · [ChatDev](https://arxiv.org/abs/2307.07924) · [Self-evolving harness](https://arxiv.org/abs/2609.38372) · [MILO](https://arxiv.org/abs/2609.38349) · [Harmony Harness](https://arxiv.org/abs/2610.15150) · [Terminal-RSI](https://arxiv.org/abs/2610.22192) · [Deep Review](https://research.google/blog/analyzing-technical-documents-with-deep-review/) ([paper](https://arxiv.org/abs/2606.28277))
