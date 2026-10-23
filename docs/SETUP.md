# Setting up Concord

This guide covers requirements, installation, executors and configuration. The [README](../README.md) has the overview; [WORKFLOW.md](WORKFLOW.md) describes a ticket from plan to commit.

## Requirements

- macOS or Linux, bash 3.2+, git, Python 3.9+ (standard library only).
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) for the `concord` plugin, which carries the commands and agents. The planner, the Claude implementer and the Opus reviewers run as Claude Code subagents on your subscription.
- [OpenCode](https://opencode.ai) on PATH for the cheap executors (`opencode run`). Phases go first to DeepSeek or GLM Flash on the OpenCode Zen free tier, then to DeepSeek v4.1 Flash on the OpenCode Go allowance (the `default`). Without OpenCode the dispatcher still runs Claude subagent phases, reviews and verdicts.
- The `hookify` plugin for Claude Code if you want the four hook rules enforced. They are plain Markdown rule files; without the plugin they do nothing.

The demo (`bash scripts/demo.sh`) needs only bash, git and Python.

## Install

```bash
git clone https://github.com/bqp007/concord-agent-harness.git && cd concord-agent-harness
bash install.sh --dry-run            # shows every link, copy, keep and backup; writes nothing
bash install.sh                      # the default: links the commands and agents, installs the dispatcher, then runs Concord's twenty test suites from the installed copy
bash install.sh --plugin             # the marketplace layout instead of the links; prints the /plugin commands
bash install.sh --repo ~/src/myrepo  # also drops the hook rules into that repository's .claude/
```

The default (`--link`) symlinks `/concord:plan-then-delegate`, `/concord:delegate` and `/concord:rules-review` and the agents into `~/.claude`, and edits your live setup: it writes the Concord rules into `~/.claude/CLAUDE.md` between `<!-- concord:begin -->` and `<!-- concord:end -->`, and adds any missing keys to `~/.claude/settings.json`. It backs up each file it changes first and leaves everything outside the markers untouched.

With `--plugin` the commands and agents come from the marketplace instead; add it in Claude Code:

```text
/plugin marketplace add bqp007/concord-agent-harness
/plugin install concord@concord
```

To update, run `git pull` then `bash install.sh`, and restart Claude Code.

What `install.sh` does: copies `concord/` to `~/.claude/concord/` (or `$CLAUDE_HOME/concord/`). Before overwriting an earlier install it copies the old files to `~/.claude/concord/backup/<timestamp>-pre-install/`; backups are never pruned. Suites the new version no longer ships are then removed from `tests/` (the backup keeps them). `models.conf`, `executors.conf`, `worktrees.conf` and `repo-notes/README.md` are kept when they already exist, so your edits survive upgrades. `--no-tests` skips the suites; exit code 2 means a usage error or a missing prerequisite.

Prose style: `~/.claude/concord/style.conf` sets `prose = terse` (the default) or a sentence of your own; the planner, executors and reviewers follow it.

Restart Claude Code once after installing: new agent files load only at session start.

## Executors

- `concord/models.conf` maps plain names to a harness and a model id: `free-deepseek-flash` and `free-glm-flash` on the OpenCode Zen free tier (no credits, a daily limit); `deepseek-flash` (default), `glm`, `kimi`, `qwen` and `minimax` on the OpenCode Go allowance; `zen-*` on OpenCode credits, used only after you agree. `sonnet`, `haiku` and `opus` always mean the Claude Code `concord:implementer` subagent on your subscription and are never sent to another harness (the dispatcher refuses with exit 5). `concord.py --resolve "<name>"` shows how a name resolves; `--models --verify` checks the ids against OpenCode's catalogs.
- Reasoning effort for OpenCode models is the `#high` suffix on the model id.
- The native `qwen`, `pi`, `dsh` and `kimi` harness adapters ship but are untested in this release; OpenCode is the reference harness.
- Review tiers are fixed in `concord.py` (`TIER_RANK`, `REVIEWER_RANK`): low = a cheap `--review` run, medium and high = the `concord:reviewer-opus55` agent; the dispatcher drops the `concord:` prefix before it compares. At the PR gate a review counts at most at its reviewer's rank, and `--pr-status` names the reviewer a pull request still needs. To retarget a tier, change the agent file's `model:` line and the `REVIEWER_RANK` entry together; `concord/tests/lean_test.sh` pins the names.

## Other harnesses

The dispatcher does not depend on Claude Code. What the Claude Code adapter provides, and the equivalent elsewhere:

| Claude Code piece | Role | Codex CLI | Any other CLI or a plain terminal |
|---|---|---|---|
| `CLAUDE.md` | the standing rules the planner follows | `AGENTS.md` at the repository root (same text) | paste into the planner's system prompt |
| `/concord:plan-then-delegate`, `/concord:delegate`, `/concord:rules-review` | step lists for the planner | saved prompts with the same text | run the steps by hand; every one is a `concord.py` call |
| `concord:implementer*` agents | Claude models as executors on the subscription | not available; use OpenCode executors for every phase | same |
| `concord:reviewer-opus*` agents | medium and high review tiers | a second Codex session fed the packet from `concord.py --review <run> --packet`, its REVIEW-JSON recorded with `--review-record` | same, with any strong model; keep the reviewer's context fresh |
| hookify rules | block destructive commands before they run | Codex's own sandbox and approval policy | your shell's discipline |

Reports, ledgers, red runs, scope enforcement on OpenCode, attempt caps and the PR-gate tier check live in `concord.py` and work the same everywhere.

## Configuration files

- `concord/executors.conf`: wall-clock limit, red-run and post-run acceptance toggles, static checks (ruff), extra "generated" globs.
- `concord/worktrees.conf`: per repository, the untracked folders `wt.py` links into each worktree and the base branch.
- `concord/repo-notes/`: per-repository notes for executors and the planner (`<repo>.md`); its README gives the format.

## Running the checks

```bash
bash tests/package_test.sh                 # the repository's contract (about a minute; installs into temporary HOMEs)
bash tests/demo_test.sh                    # the credential-free demo, end to end
bash concord/tests/run_all.sh              # the dispatcher's twenty suites against this checkout
bash ~/.claude/concord/tests/run_all.sh   # the same suites against the installed copy
```

`tests/package_test.sh scrub` reads private patterns from `~/.config/concord/scrub.txt` (or `$CONCORD_SCRUB_FILE`), one regular expression per line, so a fork can keep its own internal names out of a public copy without publishing them.
