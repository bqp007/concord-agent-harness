# repo-notes

Files here are keyed by the main checkout's folder name (`repo_name()` in concord.py), so a
worktree reads its main checkout's notes.

- `<repo-dir-name>.md`: binding facts for executors — test runner, entry points, conventions.
  concord.py prepends it to every executor task and adds it to every review prompt (flash, packet, pull
  request) for that repository, truncated at 4000 characters.
- A `Risk floor <tier>: <globs>` line in that file (tier low, medium or high) raises the review tier of any
  phase that changes a matching non-test file, and the tier each such file needs at the pull-request gate: a
  phase review names the reviewer the raised tier needs, and `--pr-status` counts the file covered only by a
  review at the raised tier or above.

This README is the only file shipped in `~/.claude/concord/repo-notes/`.
