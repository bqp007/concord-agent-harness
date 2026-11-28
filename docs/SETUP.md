# Setting up Concord

This guide covers requirements, installation, executors and configuration. The [README](../README.md) has the overview; [WORKFLOW.md](WORKFLOW.md) describes a ticket from plan to commit.

## Requirements

- macOS or Linux, bash 3.2+, git, Python 3.9+ (standard library only).
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) for the `concord` plugin, which carries the commands and agents. The planner, the Claude implementer and the Opus reviewers run as Claude Code subagents on your subscription.
- The cheap executors: [OpenCode](https://opencode.ai) (`opencode run`) for DeepSeek or GLM Flash on the OpenCode Zen free tier, tried first, and the `pi` CLI for the models on the OpenCode Go allowance, including the `default`, DeepSeek v4.1 Flash. File scope is enforced only by OpenCode's edit tools; on pi the report's out-of-scope lines are the check. Without either, Claude subagent phases, verdicts and the medium-tier review by `reviewer-opus55` still work; the low-tier review and the second review from another model family that a high-risk change needs cannot run.
- The `hookify` plugin for Claude Code if you want the four hook rules enforced. They are plain Markdown rule files; without the plugin they do nothing.

The demo (`bash scripts/demo.sh`) needs only bash, git and Python.

## The demo

```bash
bash scripts/demo.sh          # add --keep to inspect the run folders afterwards
```

The demo runs the whole loop in both modes in about a minute inside a temporary folder, with a scripted executor instead of a model: no network, no account, nothing left outside that folder. A toy repository has a bug and a failing test. In delegate mode the first attempt fixes the bug but also edits a file outside the phase's scope, so the run is rejected and the phase fails with cause EXECUTOR. The second attempt stays in scope: the red run, the passing acceptance, a review and the PASS verdict follow. In execute mode a second copy of the repository runs the same ticket with the phase assigned to the planner: the script plays the planning session and writes the fix inside a recorded `--begin`/`--end` run, with the same check, review and verdict. Each ticket's report then shows who wrote each phase, the plan revision, the graded candidate and its review. The plan it uses is [examples/PLAN_example.md](../examples/PLAN_example.md).

## Install

```bash
git clone https://github.com/bqp007/concord-agent-harness.git && cd concord-agent-harness
bash install.sh --dry-run            # shows every link, copy, keep and backup; writes nothing
bash install.sh                      # the default: links the commands, agents and skills, installs the dispatcher, then runs Concord's test suites from the installed copy
bash install.sh --plugin             # the marketplace layout instead of the links; prints the /plugin commands
bash install.sh --repo ~/src/myrepo  # also drops the hook rules into that repository's .claude/
```

The default (`--link`) symlinks the commands, the agents and the five skills into `~/.claude` (names below), and edits your live setup: it writes the Concord rules into `~/.claude/CLAUDE.md` between `<!-- concord:begin -->` and `<!-- concord:end -->`, and adds to `~/.claude/settings.json` the keys it lacks: the drift hook, compaction windows for two models, and `sandbox.excludedCommands` entries for `gh *`, `git push *`, `git fetch *`, `git pull *` and `git clone *`, which then run outside Claude Code's sandbox in every project. An existing `sandbox.excludedCommands` list keeps its entries and gains the Concord entries it lacks on every install, so an entry you remove comes back; a value there that is not a list stops the install before anything is written. It backs up each file it changes first and leaves everything outside the markers untouched.

With `--plugin` the commands and agents come from the marketplace instead. Each install records the links it makes, with their targets, in `~/.claude/concord/links.tsv`. The installer removes the links that point into this checkout or that this record lists with their current target, such as a link into a moved or deleted clone, and keeps, with a note, any other link of the same name, such as a personal skill. A link from an install that left no record counts as Concord's only when it points to the same path inside another Concord checkout that still exists. The default install follows the same rule and never replaces such a link. Add the marketplace in Claude Code:

```text
/plugin marketplace add bqp007/concord-agent-harness
/plugin install concord@concord
```

To update or remove Concord, see [Upgrade](#upgrade) and [Uninstall](#uninstall).

What `install.sh` does: first it checks that `settings.json` can be merged and that the `CLAUDE.md` markers pair, and it stops before writing anything when either fails (a `settings.json` that is not a JSON object, or whose `hooks` have another shape than Claude Code's, cannot be merged, and neither can a hook whose command is not a string); a `CLAUDE.md` that has the Concord heading but no markers stops the install with instructions. A relative `CLAUDE_HOME` is resolved from the current folder first. `CLAUDE_HOME` moves the install, the drift hook path and the paths in the `CLAUDE.md` block; the agent, command and skill texts and some dispatcher lookups still name `~/.claude`, so a home elsewhere suits testing more than daily use. Then it copies `concord/` to `~/.claude/concord/` (or `$CLAUDE_HOME/concord/`), together with the MIT `LICENSE`. Whenever that folder already exists it first copies the old files to `~/.claude/concord/backup/<timestamp>-pre-install/`; backups are never pruned. The settings merge adds missing keys and removes only hook entries whose whole command is one this installer ships or shipped before (a shipped command you extended stays, and the installer names it), and the drift hook points into the `CLAUDE_HOME` it installs to. It merges from `settings.json` as the file is when it writes, through a temporary file beside it, so an edit made during the install is kept; a file that can no longer be merged by then is left as it was, and the installer says so. An edit to `settings.json` made between that last read and the rename is lost. It writes `CLAUDE.md` the same way, through a temporary file it then renames over the old one, so a failed write leaves the file as it was. If the install stops after it wrote anything, it lists on stderr what it wrote (the dispatcher files as a count, each link, `CLAUDE.md`, `settings.json`); the backup folder holds what it replaced. Suites that Concord retired (`card`, `lessons`, `map`, `reuse` and `slim`) are then removed from `tests/` (the backup keeps them); a suite of your own in `tests/` stays. `models.conf`, `executors.conf`, `worktrees.conf`, `style.conf` and `repo-notes/README.md` are kept when they already exist, so your edits survive upgrades. The suites run after everything is in place; when one fails, the installer says the install is complete and only the tests failed. `--no-tests` skips the suites; exit code 2 means a usage error or a missing prerequisite.

Prose style: `~/.claude/concord/style.conf` sets `prose = lean` (the default, lean STE: short active sentences with articles, no filler) or a sentence of your own. The values `terse` and `lean`, and an empty value, all select lean STE. The planner, executors and reviewers follow it.

Restart Claude Code once after installing: new agent files load only at session start.

### Names

Both install modes give the same names.

| What | Plugin install (`--plugin`) | Linked install (default) |
|---|---|---|
| The workflow | `/concord:run execute <task>`, `/concord:run delegate <task>`, either with `--plan PLAN_<ticket>.md` | the same, from `~/.claude/commands/concord/run.md` |
| Former entry points | `/concord:plan-then-delegate <task>`, `/concord:delegate <phases>` (both call `/concord:run delegate`) | the same |
| Weekly rules review | `/concord:rules-review` | the same |
| Skills | `/concord:design-review`, `/concord:plan`, `/concord:verify-plan`, `/concord:lean-testing`, `/concord:review-change` | the same, from the links `~/.claude/skills/concord:<name>` |
| Agents | `concord:implementer`, `concord:implementer-opus48`, `concord:plan-verifier`, `concord:reviewer-opus55`, `concord:reviewer-delta` | the same without the `concord:` prefix (links in `~/.claude/agents`) |

A linked skill takes the name of its link, `concord:<name>`, and the plugin gives each skill the same name, so an agent preloads it by that name in either mode. The CLAUDE.md rules block names the agents as the install mode provides them.

### Upgrade

Pull the new version in your clone, then run the installer in the mode you installed with:

```bash
git pull
bash install.sh                 # a linked install
bash install.sh --plugin        # a marketplace install; then, in a terminal:
claude plugin marketplace update concord
claude plugin update concord@concord
```

Restart Claude Code afterwards; agent files load only at session start. The installer refreshes the dispatcher in `~/.claude/concord/`, keeps your `models.conf`, `executors.conf`, `worktrees.conf`, `style.conf` and `repo-notes/`, and backs up what it replaces. On a marketplace install, plain `bash install.sh` switches to the linked layout: it links the commands, agents and skills beside the plugin and rewrites the `CLAUDE.md` block with unprefixed agent names. Run `bash install.sh --plugin` to stay on the marketplace layout. `python3 ~/.claude/concord/concord.py --check` compares the installed plugin and dispatcher with the marketplace source and prints the update commands when they differ.

### Uninstall

1. Commands, agents and skills.
   - A marketplace install: `claude plugin uninstall concord@concord`, then `claude plugin marketplace remove concord`.
   - A linked install: remove each link listed in the first column of `~/.claude/concord/links.tsv` (`commands/concord`, `agents/implementer.md`, `agents/implementer-opus48.md`, `agents/reviewer-opus55.md`, `agents/reviewer-delta.md`, `agents/plan-verifier.md`, and `skills/concord:<name>` for each of the five skills), after checking that each one still points into a Concord checkout.
2. `CLAUDE.md`. Remove the Concord block and its markers:
   `sed -i.bak '/^<!-- concord:begin -->$/,/^<!-- concord:end -->$/d' ~/.claude/CLAUDE.md`
3. `settings.json`. Remove the `PostToolUse` hook whose command runs `~/.claude/concord/drift_hook.sh`, the five `sandbox.excludedCommands` entries (`gh *`, `git push *`, `git fetch *`, `git pull *`, `git clone *`) unless you want them, and the `modelSettings` entries for `claude-opus-5-5` and `claude-fable-5-1` unless you set them yourself. The installer does not record which keys it added; `~/.claude/concord/backup/` holds the file as it was before each install.
4. `~/.claude/concord/`. It holds the dispatcher, your `models.conf`, `executors.conf`, `worktrees.conf`, `style.conf` and `repo-notes/`, the backups, `runs.jsonl` (the index of runs across repositories), `links.tsv` and `LICENSE`. Copy what you want to keep, then remove the folder.
5. In each repository you used:
   - Run `wt.py done <TICKET>` for each worktree under `.claude/worktrees/` first.
   - Remove `.claude/hookify.block-destructive-git.local.md`, `.claude/hookify.block-rm-outside-scratch.local.md`, `.claude/hookify.block-plan-md.local.md` and `.claude/hookify.block-rm-home-paths.local.md` (from `--repo`), and the exclude line you added for them.
   - Remove the run data in `<git-common-dir>/concord/` (run folders, reports, ledgers, approvals, archived plans, `drift.json`).
   - Remove `concord.lock`, `concord.lock.mutex` and `concord-id` in each git directory.
   - Remove the lines `wt.py` added to `.git/info/exclude` (`.claude/worktrees/`, `/PLAN_*.md`, and its `/name` and `!/name/` link patterns).
6. Restart Claude Code.

## Executors

- `concord/models.conf` maps plain names to a harness and a model id: `free-deepseek-flash` and `free-glm-flash` on the OpenCode Zen free tier (no credits, a daily limit); `deepseek-flash` (default), `glm`, `minimax` and the Kimi and Qwen models (`concord.py --models` lists their names) on the OpenCode Go allowance; `zen-*` on OpenCode credits, used only after you agree. `sonnet`, `haiku` and `opus` always mean the Claude Code `implementer` subagent on your subscription. The dispatcher refuses with exit 5 a model id that contains the word `claude`, `anthropic`, `sonnet`, `opus` or `haiku` on another harness, and an executor run with no explicit model; the guard reads the model id's text, not the route the harness takes. `concord.py --resolve "<name>"` shows how a name resolves; `--models --verify` checks the ids against OpenCode's catalogs.
- `models.conf` is a registry you own. The installer copies it once and keeps your copy on every upgrade, so a model that a later release adds or renames in `concord/models.conf` reaches you only when you merge it in. Model ids and free tiers change at the providers. `python3 ~/.claude/concord/concord.py --models --verify` fetches OpenCode's public Zen and Go catalogs and marks each `opencode/` and `opencode-go/` id as available or not listed; ids for other harnesses carry no mark, and a catalog that cannot be reached is named and left unchecked. The dispatcher's other network requests of its own are `gh pr view` and `git fetch` of the pull request's head and base branch, in `--review-pr` (dry runs included), `--pr-status` and `--report` (for each pull request reviewed on the ticket's commits); `wt.py new` runs `git fetch origin` unless you pass `--no-fetch`. The executors and the commands a plan names reach the network on their own.
- Reasoning effort for OpenCode models is the `#high` suffix on the model id.
- `pi` runs the default executor and the other Go models. The native `qwen`, `dsh` and `kimi` harness adapters ship but are untested in this release. An executor name always means its own harness: `concord.py qwen <phase>` and `concord.py kimi <phase>` run the native adapters, never a Go model.
- Executors receive only allow-listed environment variables: a base list (`PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `TERM`, `LANG`, `LC_*`, `TZ`, `XDG_*`) and the names `executors.conf` lists for the harness as `<harness>.env`. Add a name there when a harness needs one; `--dry-run` prints the names a run passes. Names that begin with `ANTHROPIC_` or `CLAUDE_`, and `CLAUDECODE`, never reach an executor, even when `<harness>.env` lists them.
- Review tiers are fixed in `concord.py` (`TIER_RANK`, `REVIEWER_RANK`): low = a cheap `--review` run, medium = the `reviewer-opus55` agent, high = that agent and a cheap `--review` run, a model from another family; the dispatcher drops a plugin agent's `concord:` prefix before it compares. A review's rank and model family follow from the reviewer name the caller passes to `--review-record`; the dispatcher does not check which model produced the text. At the PR gate a review counts at most at its reviewer's rank, and `--pr-status` names the reviewer a pull request still needs. To retarget a tier, change the agent file's `model:` line and the `REVIEWER_RANK` entry together; `concord/tests/lean_test.sh` pins the names.

## Other harnesses

The dispatcher does not depend on Claude Code. What the Claude Code adapter provides, and the equivalent elsewhere:

| Claude Code piece | Role | Codex CLI | Any other CLI or a plain terminal |
|---|---|---|---|
| `CLAUDE.md` | the standing rules the planner follows | `AGENTS.md` at the repository root (same text) | paste into the planner's system prompt |
| `/concord:run`, the `concord:*` skills, `/concord:rules-review` | step lists for the planner | saved prompts with the same text | run the steps by hand; every one is a `concord.py` call |
| `implementer*` agents | Claude models as executors on the subscription | not available; use OpenCode executors for every phase | same |
| `reviewer-opus*` agents | medium and high review tiers | a second Codex session fed the packet from `concord.py --review <run> --packet`, its REVIEW-JSON recorded with `--review-record` | same, with any strong model; keep the reviewer's context fresh |
| hookify rules | block destructive commands before they run | Codex's own sandbox and approval policy | your shell's discipline |

Reports, ledgers, the plan approval, red runs, the PASS rule, scope enforcement on OpenCode and the PR-gate check live in `concord.py` and work the same everywhere.

## Sandbox

On macOS the OpenCode and pi executors run under `sandbox-exec` with `concord/opencode.sandbox.sb`. Reads are open except credential stores and private data: `~/.ssh`, `~/.aws`, `~/.config/gcloud`, `~/.config/gh`, `~/.gnupg`, `~/.docker`, `~/Library/Keychains`, `~/.netrc`, `~/.npmrc`, `~/.pypirc`, `~/.git-credentials`, the Hugging Face token files, `~/.kube`, Claude Code's `~/.claude.json`, transcripts, session data and history, and the paths `opencode.sandbox_deny` lists. Writes go only to the worktree, OpenCode's data and cache folders, `$TMPDIR` and the standard streams; the repository's Git directory, which holds the hooks, the config, the index and the run folders, stays unwritable. The network is open: Seatbelt cannot filter by host. The wrapper is skipped on Linux and inside another Seatbelt sandbox, such as a Claude Code shell, so start executors outside Claude Code's sandbox. `--no-sandbox`, `CONCORD_NO_SANDBOX=1` or `opencode.sandbox = no` turn it off. The run report records whether a run was sandboxed and, when not, why (a switch, a missing `sandbox-exec` or profile, or a nested sandbox), and the test report lists unsandboxed runs under Overrides. For an OpenCode run the report reads OpenCode's own record of its tool calls and names each denied web fetch; a shell command's network use leaves no record.

Outside the wrapper, on every platform: the red run, the acceptance commands before and after an executor, the static checks, `--grade` and every later test run execute the code in the checkout as your user, with your environment, the network and the repository's shared Git metadata. Inside it, OpenCode's cache folder and `$TMPDIR` are writable, and so are other tickets' worktrees under `.claude/worktrees/` when a run works in the main checkout. A write outside the checkout is not blocked there: the dispatcher compares a fixed set of files outside the checkout before and after each run and rejects the run when one changed ([SECURITY.md](../SECURITY.md) lists them).

## Configuration files

- `concord/executors.conf`: wall-clock limit, red-run and post-run acceptance toggles, the sandbox switch, the environment names each harness receives, static checks (ruff), extra "generated" globs.
  - Limits: the wall-clock limit (`wall`, default 30m, or `--wall`), a memory cap and a free-disk floor (`mem_cap_mib`, default 8192, and `disk_floor_gib`, default 5) cover the process tree of an executor or a cheap review; the dispatcher stops the tree 60 seconds after the wall limit of an executor run. `check_timeout` (default 300s) covers each red-run, characterization, acceptance and mutation command on its own: a command that runs over it has its process group killed and counts as exit 124, and its output is collected for 5 more seconds. Checks have no memory or disk limit, and the dispatcher holds a check's whole output in memory. Each `gh` and `git` call on the pull-request path has 120 seconds.
- `concord/worktrees.conf`: per repository, the untracked folders `wt.py` links into each worktree and the base branch.
- `concord/repo-notes/`: per-repository notes for executors and the planner (`<repo>.md`); its README gives the format.

## Running the checks

```bash
bash tests/package_test.sh                 # the repository's contract (about a minute; installs into temporary HOMEs)
bash tests/demo_test.sh                    # the credential-free demo, end to end
bash concord/tests/run_all.sh              # the dispatcher's suites against this checkout; skipped checks are counted apart
bash ~/.claude/concord/tests/run_all.sh   # the same suites against the installed copy
```

CI runs the three checkout commands on Python 3.12 on Ubuntu and macOS, and on Python 3.9, the documented minimum, on Ubuntu. The installed copy is not run in CI.

`tests/package_test.sh scrub` reads private patterns from `~/.config/concord/scrub.txt` (or `$CONCORD_SCRUB_FILE`), one regular expression per line, so a fork can keep its own internal names out of a public copy without publishing them.
