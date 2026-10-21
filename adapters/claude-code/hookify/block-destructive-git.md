---
name: block-destructive-git
enabled: true
event: bash
action: block
conditions:
  - field: command
    operator: regex_match
    pattern: git\s+(merge\b(?!-)|rebase\b|reset\s+--hard|clean\s+-\w*[fd]|(checkout\s+--|restore)\s+\.(\s|$)|stash\s+pop(?!\s+stash@)|push\b[^|;&]*\s(-f|--force)\b|branch\s+(?-i:-D)\b)|gh\s+pr\s+merge\b
  - field: command
    operator: not_contains
    pattern: /scratchpad/
---
Blocked by the owner's standing rules: no merge, rebase, reset --hard, clean, discard-all, bare stash pop, force-push, branch -D or PR merge from Claude. Merges and history rewrites need the user's explicit go for this exact command; with it, set `enabled: false` in .claude/hookify.block-destructive-git.local.md for that one command, then restore it. A bare stash pop once dumped another ticket's debris into a worktree: check the stash list and name the entry (stash@{n}). Throwaway repos under a session scratchpad are exempt.
