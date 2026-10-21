# Setting up Concord

This guide covers requirements, installation, executors and configuration. The [README](../README.md) has the overview; [WORKFLOW.md](WORKFLOW.md) describes a ticket from plan to commit.

## Requirements

- macOS or Linux, bash 3.2+, git, Python 3.9+ (standard library only).
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) for the `concord` plugin, which carries the commands and agents. The planner, the Claude implementer and the Opus reviewers run as Claude Code subagents on your subscription.
- [OpenCode](https://opencode.ai) on PATH for the cheap executors (`opencode run`). The default executor is DeepSeek v4.1 Flash on the OpenCode Go allowance. Without OpenCode the dispatcher still runs Claude subagent phases, reviews and verdicts.
- The `hookify` plugin for Claude Code if you want the four hook rules enforced. They are plain Markdown rule files; without the plugin they do nothing.

The demo (`bash scripts/demo.sh`) needs only bash, git and Python.

## Install

```bash
git clone https://github.com/bqp007/concord-agent-harness.git && cd concord-agent-harness
./install.sh --dry-run            # shows every copy, keep and backup; writes nothing
./install.sh                      # installs the dispatcher, then runs Concord's fourteen test suites from the installed copy
./install.sh --repo ~/src/myrepo  # also drops the hook rules into that repository's .claude/
```

Then add the plugin in Claude Code:

```text
/plugin marketplace add bqp007/concord-agent-harness
/plugin install concord@concord
```

`/plugin marketplace add` also takes the path of a local clone, so the commands and agents come from your checkout. To update, pull, run `./install.sh` again, then `claude plugin marketplace update concord` and `claude plugin update concord@concord`, and restart Claude Code.

What `install.sh` does: copies `concord/` to `~/.claude/concord/` (or `$CLAUDE_HOME/delegate/`). Before overwriting an earlier install it copies the old files to `~/.claude/concord/backup/<timestamp>-pre-install/`; backups are never pruned. `models.conf`, `executors.conf`, `worktrees.conf` and `repo-notes/README.md` are kept when they already exist, so your edits survive upgrades. Command and agent files that an earlier install left in `~/.claude/commands/` and `~/.claude/agents/` are listed, not removed: delete them once the plugin is installed, so each command exists once.

What the plugin adds: the commands `/concord:plan-then-delegate`, `/concord:delegate` and `/concord:rules-review`, and the agents `concord:implementer`, `concord:implementer-opus48`, `concord:reviewer-opus48` and `concord:reviewer-opus55`.

What it never touches: `~/.claude/CLAUDE.md` and `~/.claude/settings.json`. Merge `adapters/claude-code/CLAUDE.md` and `adapters/claude-code/settings.snippet.json` into them by hand; both are short. `--no-tests` skips the suites; exit code 2 means a usage error or a missing prerequisite.

Restart Claude Code once after installing: new agent files load only at session start.

## Executors

- `concord/models.conf` maps plain names to a harness and a model id: `deepseek-flash` (default), `glm`, `kimi`, `qwen` and `minimax` on the OpenCode Go allowance; `zen-*` on OpenCode credits. `sonnet`, `haiku` and `opus` always mean the Claude Code `concord:implementer` subagent on your subscription and are never sent to another harness (the dispatcher refuses with exit 5). `concord.py --resolve "<name>"` shows how a name resolves; `--models --verify` checks the ids against OpenCode's catalogs.
- Reasoning effort for OpenCode models is the `#high` suffix on the model id.
- The native `qwen`, `pi`, `dsh` and `kimi` harness adapters ship but are untested in this release; OpenCode is the reference harness.
- Review tiers are fixed in `concord.py` (`TIER_RANK`, `REVIEWER_RANK`): low = a cheap `--review` run, medium = the `concord:reviewer-opus48` agent, high = `concord:reviewer-opus55`; the dispatcher drops the `concord:` prefix before it compares. To retarget a tier, change the agent file's `model:` line and the `REVIEWER_RANK` entry together; `concord/tests/guards_test.sh` pins the names.

## Other harnesses

The dispatcher does not depend on Claude Code. What the Claude Code adapter provides, and the equivalent elsewhere:

| Claude Code piece | Role | Codex CLI | Any other CLI or a plain terminal |
|---|---|---|---|
| `CLAUDE.md` | the standing rules the planner follows | `AGENTS.md` at the repository root (same text) | paste into the planner's system prompt |
| `/concord:plan-then-delegate`, `/concord:delegate`, `/concord:rules-review` | step lists for the planner | saved prompts with the same text | run the steps by hand; every one is a `concord.py` call |
| `concord:implementer*` agents | Claude models as executors on the subscription | not available; use OpenCode executors for every phase | same |
| `concord:reviewer-opus*` agents | medium and high review tiers | a second Codex session fed the packet from `concord.py --review <run> --packet`, its REVIEW-JSON recorded with `--review-record` | same, with any strong model; keep the reviewer's context fresh |
| hookify rules | block destructive commands before they run | Codex's own sandbox and approval policy | your shell's discipline |

Reports, ledgers, red runs, scope enforcement on OpenCode, attempt caps and tier guards live in `concord.py` and work the same everywhere.

## Configuration files

- `concord/executors.conf`: wall-clock limit, red-run and post-run acceptance toggles, static checks (ruff), extra "generated" globs.
- `concord/worktrees.conf`: per repository, the untracked folders `wt.py` links into each worktree and the base branch.
- `concord/repo-notes/`: per-repository notes for executors (`<repo>.md`) and the planner's plan-gap ledger (`<repo>.gaps.md`).

## Running the checks

```bash
bash tests/package_test.sh                 # the repository's contract (about a minute; installs into temporary HOMEs)
bash tests/demo_test.sh                    # the credential-free demo, end to end
bash concord/tests/run_all.sh              # the dispatcher's fourteen suites against this checkout
bash ~/.claude/concord/tests/run_all.sh   # the same suites against the installed copy
```

`tests/package_test.sh scrub` reads private patterns from `~/.config/concord/scrub.txt` (or `$CONCORD_SCRUB_FILE`), one regular expression per line, so a fork can keep its own internal names out of a public copy without publishing them.
