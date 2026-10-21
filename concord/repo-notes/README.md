# repo-notes

Files here are keyed by the main checkout's folder name (`repo_name()` in concord.py), so a
worktree reads its main checkout's notes.

- `<repo-dir-name>.md`: binding facts for executors — test runner, entry points, conventions.
  concord.py prepends it to every executor task and adds it to every review prompt (flash, packet, pull
  request) for that repository, truncated at 4000 characters.
- A `Risk floor <tier>: <globs>` line in that file (tier low, medium or high) raises the review tier of any
  phase or pull request that changes a matching non-test file; a phase PASS below it is refused (exit 9).
- `<repo-dir-name>.gaps.md`: the planner's gap log, one line per entry. Writing it is a convention
  of the `/concord:plan-then-delegate` and `/concord:delegate` commands; the planner reads it before planning and
  it is never sent to executors.

This README is the only file shipped in `~/.claude/concord/repo-notes/`.
