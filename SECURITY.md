# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue. Use GitHub's private vulnerability reporting (the **Report a vulnerability** button on this repository's Security tab). Include the version or commit, what you ran, what happened and, if you can, a minimal reproduction.

Concord is maintained by one independent developer. Reports are acknowledged within seven days on a best-effort basis, and confirmed problems are fixed in the next release, with credit if you want it. There is no bug bounty.

Only the latest release on the default branch receives fixes.

## What Concord is, and what it is not

Concord is a workflow harness, not a sandbox. The agents it starts (the planning session, the executors and the reviewers) run with your user account's permissions: they can run shell commands, read what your account can read and reach the network through their harness. Plans, prompts, diffs and repository notes are sent to the model providers you configure.

The dispatcher enforces the plan approval, the red run, the out-of-scope report, the PASS rule, the review tier, the billing guard and an allow-list of the environment variables an executor receives. Everything else it relies on (the executor contract, the hook rules) is an instruction that a model can ignore, and the hook rules catch only common spellings of the commands they name.

## Known limitations

- File scope is enforced for an executor's edit tools on OpenCode only. A shell command, such as a redirection, can still write outside the phase's files. Changes inside the repository show up in the out-of-scope report after the run; changes outside it are not tracked.
- On OpenCode, executors may run any shell command except a short deny list (deleting files, changing branches or git state, committing, pushing, `sudo`); other harnesses apply their own permission settings.
- On macOS, Concord runs the OpenCode and pi executors under a Seatbelt profile (`concord/opencode.sandbox.sb`) that hides credential stores such as `~/.ssh` and `~/.aws` and limits writes. It is skipped on Linux and inside another Seatbelt sandbox, such as a Claude Code shell, and `--no-sandbox` or `CONCORD_NO_SANDBOX=1` turn it off. The network stays open; OpenCode's cache folder and other tickets' worktrees stay writable; and the acceptance commands that run after an executor, like every later test run, execute the code it wrote as your user, unsandboxed: they run in a temporary copy of the checkout, which keeps their output out of the checkout but confines nothing.
- Concord hashes its own files and your agent configuration before and after each run, and keeps the start state that grades a run in its own memory. This detects tampering after the fact; it does not prevent it, and it does not yet cover the plugin's files or the review records under `.git/concord/`, which the PR gate reads.
- `install.sh` adds `sandbox.excludedCommands` entries to `~/.claude/settings.json`, so `gh`, `git push`, `git fetch`, `git pull` and `git clone` run outside Claude Code's sandbox in every project. Remove them if you do not want that.

## Recommendations

- Run Concord where the agents cannot reach credentials you would not hand them: no production keys, cloud administrator tokens or SSH keys to systems that matter. A disposable container or virtual machine is the safest place for an untrusted repository.
- Keep secrets out of plans, repository notes and prompts.
- Read every diff before you commit. Concord never commits or pushes; keep it that way in your own setup.
- Keep the dispatcher and the plugin up to date.

Problems in the model providers or agent harnesses that Concord drives belong with their maintainers.
