# Setting up Concord

This guide covers requirements, installation, executors and configuration. The [README](../README.md) has the overview; [WORKFLOW.md](WORKFLOW.md) describes a ticket from plan to commit.

## Requirements

- macOS or Linux, bash 3.2+, git, Python 3.9+ (standard library only).
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) for the `concord` plugin, which carries the commands and agents. The planner, the Claude implementer and the Opus reviewers run as Claude Code subagents on your subscription.
- The cheap executors: [OpenCode](https://opencode.ai) (`opencode run`) for DeepSeek or GLM Flash on the OpenCode Zen free tier, tried first, and the `pi` CLI for the models on the OpenCode Go allowance, including the `default`, DeepSeek v4.1 Flash. File scope is enforced only by OpenCode's edit tools; on pi the report's out-of-scope lines are the check. Without either, the dispatcher still runs Claude subagent phases, reviews and verdicts.
- The `hookify` plugin for Claude Code if you want the four hook rules enforced. They are plain Markdown rule files; without the plugin they do nothing.

The demo (`bash scripts/demo.sh`) needs only bash, git and Python.

## Install

```bash
git clone https://github.com/bqp007/concord-agent-harness.git && cd concord-agent-harness
bash install.sh --dry-run            # shows every link, copy, keep and backup; writes nothing
bash install.sh                      # the default: links the commands, agents and skill, installs the dispatcher, then runs Concord's test suites from the installed copy
bash install.sh --plugin             # the marketplace layout instead of the links; prints the /plugin commands
bash install.sh --repo ~/src/myrepo  # also drops the hook rules into that repository's .claude/
```

The default (`--link`) symlinks `/concord:plan-then-delegate`, `/concord:delegate` and `/concord:rules-review`, the agents and the `concord-design-review` skill into `~/.claude`, and edits your live setup: it writes the Concord rules into `~/.claude/CLAUDE.md` between `<!-- concord:begin -->` and `<!-- concord:end -->`, and adds to `~/.claude/settings.json` the keys it lacks: the drift hook, compaction windows for two models, and `sandbox.excludedCommands` entries for `gh *`, `git push *`, `git fetch *`, `git pull *` and `git clone *`, which then run outside Claude Code's sandbox in every project. It backs up each file it changes first and leaves everything outside the markers untouched.

With `--plugin` the commands and agents come from the marketplace instead. The installer removes the links that point into this checkout, or to the same path in another checkout of this kit such as a moved clone, and keeps, with a note, any other link of the same name, such as a personal skill. The default install follows the same rule and never replaces such a link. Add the marketplace in Claude Code:

```text
/plugin marketplace add bqp007/concord-agent-harness
/plugin install concord@concord
```

To update, run `git pull` then `bash install.sh`, and restart Claude Code.

What `install.sh` does: first it computes the merged `settings.json` and checks that the `CLAUDE.md` markers pair, and it stops before writing anything when either fails (a `settings.json` that is not a JSON object, or whose `hooks` have another shape than Claude Code's, cannot be merged, and neither can a hook whose command is not a string); a `CLAUDE.md` that has the Concord heading but no markers stops the install with instructions. A relative `CLAUDE_HOME` is resolved from the current folder first. Then it copies `concord/` to `~/.claude/concord/` (or `$CLAUDE_HOME/concord/`). Whenever that folder already exists it first copies the old files to `~/.claude/concord/backup/<timestamp>-pre-install/`; backups are never pruned. The settings merge adds missing keys and removes only hook entries whose whole command is one this installer ships or shipped before (a shipped command you extended stays, and the installer names it), and the drift hook points into the `CLAUDE_HOME` it installs to. Suites that Concord retired (`card`, `lessons`, `map`, `reuse` and `slim`) are then removed from `tests/` (the backup keeps them); a suite of your own in `tests/` stays. `models.conf`, `executors.conf`, `worktrees.conf` and `repo-notes/README.md` are kept when they already exist, so your edits survive upgrades. `--no-tests` skips the suites; exit code 2 means a usage error or a missing prerequisite.

Prose style: `~/.claude/concord/style.conf` sets `prose = lean` (the default, lean STE: short active sentences with articles, no filler) or a sentence of your own. The values `terse` and `lean`, and an empty value, all select lean STE. The planner, executors and reviewers follow it.

Restart Claude Code once after installing: new agent files load only at session start.

## Executors

- `concord/models.conf` maps plain names to a harness and a model id: `free-deepseek-flash` and `free-glm-flash` on the OpenCode Zen free tier (no credits, a daily limit); `deepseek-flash` (default), `glm`, `minimax` and the Kimi and Qwen models (`concord.py --models` lists their names) on the OpenCode Go allowance; `zen-*` on OpenCode credits, used only after you agree. `sonnet`, `haiku` and `opus` always mean the Claude Code `concord:implementer` subagent on your subscription and are never sent to another harness (the dispatcher refuses with exit 5). `concord.py --resolve "<name>"` shows how a name resolves; `--models --verify` checks the ids against OpenCode's catalogs.
- Reasoning effort for OpenCode models is the `#high` suffix on the model id.
- `pi` runs the default executor and the other Go models. The native `qwen`, `dsh` and `kimi` harness adapters ship but are untested in this release. An executor name always means its own harness: `concord.py qwen <phase>` and `concord.py kimi <phase>` run the native adapters, never a Go model.
- Executors receive only allow-listed environment variables: a base list (`PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `TERM`, `LANG`, `LC_*`, `TZ`, `XDG_*`) and the names `executors.conf` lists for the harness as `<harness>.env`. Add a name there when a harness needs one; `--dry-run` prints the names a run passes.
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

Reports, ledgers, the plan approval, red runs, the PASS rule, scope enforcement on OpenCode and the PR-gate check live in `concord.py` and work the same everywhere.

## Sandbox

On macOS the OpenCode and pi executors run under `sandbox-exec` with `concord/opencode.sandbox.sb`: credential stores such as `~/.ssh` and `~/.aws` are unreadable, and writes go only to the worktree, OpenCode's data and cache folders, `$TMPDIR` and the run folder. The wrapper is skipped on Linux and inside another Seatbelt sandbox, such as a Claude Code shell, so start executors outside Claude Code's sandbox. `--no-sandbox`, `CONCORD_NO_SANDBOX=1` or `opencode.sandbox = no` turn it off. The run report records whether a run was sandboxed, and the test report lists unsandboxed runs under Overrides.

What it does not cover: the acceptance commands that run after an executor, and every later test run, execute the code the executor wrote, as your user and unsandboxed; OpenCode's cache folder and other tickets' worktrees under `.claude/worktrees/` are writable; the network is open.

## Configuration files

- `concord/executors.conf`: wall-clock limit, red-run and post-run acceptance toggles, the sandbox switch, the environment names each harness receives, static checks (ruff), extra "generated" globs.
- `concord/worktrees.conf`: per repository, the untracked folders `wt.py` links into each worktree and the base branch.
- `concord/repo-notes/`: per-repository notes for executors and the planner (`<repo>.md`); its README gives the format.

## Running the checks

```bash
bash tests/package_test.sh                 # the repository's contract (about a minute; installs into temporary HOMEs)
bash tests/demo_test.sh                    # the credential-free demo, end to end
bash concord/tests/run_all.sh              # the dispatcher's suites against this checkout; skipped checks are counted apart
bash ~/.claude/concord/tests/run_all.sh   # the same suites against the installed copy
```

`tests/package_test.sh scrub` reads private patterns from `~/.config/concord/scrub.txt` (or `$CONCORD_SCRUB_FILE`), one regular expression per line, so a fork can keep its own internal names out of a public copy without publishing them.
