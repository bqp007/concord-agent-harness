---
name: concord:verify-plan
description: Have a fresh verifier challenge a plan against the actual repository - which claims and assumptions fail, which acceptance checks would pass broken code, which risk labels are too low, and what to cut or fix. Use it whenever a plan should be verified, checked or challenged before it is approved or run; for a Concord PLAN_<ticket>.md it records the verdict that the dispatcher's run gate requires, bound to the exact text the verifier read.
argument-hint: <plan file>
---

# Verify a plan

The planner does not check its own plan. Spawn the `plan-verifier` agent, by the name the Concord rules in CLAUDE.md give it, from a fresh context, on the model the planning session does not use (`fable` or `opus`), with the plan and the facts that the plan does not state. It reads the code the plan touches and answers with one VERDICT block.

A Concord plan (`PLAN_<ticket>.md` in a repository with the dispatcher) is approved for the hash of its approval-relevant text:
- `concord.py --lint <phase> --plan <PLAN> --repo <dir>` for each phase (no model call); fix what its ACCEPTANCE LINT and PLAN LINT lines name. Each lint writes the plan's approval-relevant text to a plan read and prints `PLAN-READ: <path>`: the verifier reads the newest one.
- One round; a second, on a new plan read, only to confirm your fixes. Apply each item, or reject it with the owner decision that settles it.
- Save the final answer to a file and record it: `concord.py --plan-verdict <file> --plan <PLAN>`; an answer with more than one VERDICT or PLAN-HASH line records nothing (exit 2). The approval holds only for the read whose hash the answer quotes. An edit outside the prose of `## Open questions`, `## Handoff` and `## Passes` needs a new read and verdict: until then every run of the plan exits 11, and no owner words (`--user-approved` included) stand in for it.

Any other plan or spec, a split plan included (its `## Split` table has no phases to lint or run): give the verifier the file itself and record nothing. Each child ticket's plan is then verified on its own.

## Result

The verdict, then: the claims and assumptions that fail, with the paths read; the acceptance checks that a stub or a wrong change would pass; the risk labels to raise; the owner decisions the plan breaks and the consequential choices it leaves open; the cuts and fixes. For a Concord plan, also the revision that `--plan-verdict` recorded, or why nothing was recorded.
