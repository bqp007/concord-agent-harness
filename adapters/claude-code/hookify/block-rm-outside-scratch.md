---
name: block-rm-outside-scratch
enabled: true
event: bash
action: block
pattern: \brm\s+-\w*r\w*\s+(?!"?\$\{?TMPDIR|"?/(?:private/)?tmp/claude(?:-\d+)?/[^\s/]+/[^\s/]+/scratchpad/)\S
---
Recursive delete whose first path is not this session's scratchpad or $TMPDIR. Rule: delete only what you created, under your own scratchpad or $TMPDIR, by literal absolute path; run `du -sh` first; anything else is the user's call per item. Untracked data in this repo is irreplaceable.
