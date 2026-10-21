---
name: block-rm-home-paths
enabled: true
event: bash
action: block
pattern: \brm\s+-\w*r\w*[^;|&]*\s(~|/Users/|\.\./)
---
Recursive delete reaching the home directory, /Users/… or a parent directory (../). Same rule as block-rm-outside-scratch: only your own scratchpad or $TMPDIR, literal absolute paths, `du -sh` first; everything else is the user's call.
