---
name: block-plan-md
enabled: true
event: file
action: block
conditions:
  - field: file_path
    operator: regex_match
    pattern: (^|/)PLAN\.md$
---
PLAN.md is shared by every session in a clone and gets clobbered. Write PLAN_<ticket>.md, add it to .git/info/exclude, and pass `--plan <file>` to concord.py.
