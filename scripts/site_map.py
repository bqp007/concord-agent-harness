#!/usr/bin/env python3
"""Build site/map/data.js, the data of the interactive Concord map, from the repository.

Usage, from any directory:
  python3 scripts/site_map.py --write   # write site/map/data.js
  python3 scripts/site_map.py --check   # exit 1, naming each problem, when data.js differs from a fresh build,
                                        # a node's source file is missing, or a command, skill or agent under
                                        # adapters/claude-code/ has no node; exit 0 otherwise

This file holds the curated part of the map: the nodes, the hand-laid views, the edges and the group boxes.
The rest is read from the repository on every build, so the map cannot drift from it:
  - each command's, skill's and agent's name, description, argument hint, model and tools come from the front
    matter of adapters/claude-code/commands/*.md, skills/*/SKILL.md and agents/*.md;
  - each dispatcher step's flags and their help text come from `concord/concord.py --help`, and wt.py's
    description and subcommands from `concord/wt.py --help`;
  - each node's source path is checked to exist and becomes a link into the repository on GitHub.
The output is deterministic: the same repository gives the same data.js byte for byte.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "site" / "map" / "data.js"
ADAPTER = "adapters/claude-code"
REPO_URL = "https://github.com/bqp007/concord-agent-harness"
BLOB_URL = REPO_URL + "/blob/main/"

# Geometry shared with site/map/index.html, which reads it from data.js.
W, H = 180, 60            # node box
CW = 224                  # column pitch: a 44 px gap between columns, where side-to-side edges run
PITCH = 72                # vertical pitch of stacked nodes in a generated view
GROUP_GAP = 60            # space between two groups stacked in one column: 46 for the two box edges, 14 clear
MAX_TITLE, MAX_SUB = 20, 25   # characters that fit a node box at 14 px and 12 px
MAX_HEX_TITLE, MAX_HEX_SUB = 18, 23   # the hexagon of a "you" node is narrower

KINDS = {
    "you": "You: a decision or a step",
    "command": "Command you call",
    "skill": "Skill you call",
    "planner": "The planning session",
    "writer": "Agent that writes code",
    "judge": "Agent that judges",
    "step": "Dispatcher step or script",
    "file": "File or record",
    "stop": "Refusal or failure",
}
AGENT_KINDS = ("planner", "writer", "judge")
EDGE_KINDS = ("calls", "feeds", "loop")

# ----------------------------------------------------------------------------------------------------------------
# Nodes. `title` and `sub` are the two lines in the box; `detail` is what the node does. Nodes with `file` take
# their name, detail and facts from that file's front matter. `flags` name the concord.py options whose help text
# the panel shows; `cmd` lists the options whose usage forms the panel's command line.
# ----------------------------------------------------------------------------------------------------------------
NODES = [
    # --- you -----------------------------------------------------------------------------------------------------
    dict(id="ticket", kind="you", title="You bring a ticket", sub="A task or a plan",
         source=f"{ADAPTER}/commands/run.md",
         detail="You start a ticket in Claude Code with /concord:run and a mode. In execute mode the planning "
                "session writes every phase; in delegate mode, the default, each phase goes to the executor the "
                "approved plan assigns. To continue a plan from where its records stand, name it with --plan.",
         type="/concord:run execute <what you want done>\n/concord:run delegate <what you want done>\n"
              "/concord:run delegate --plan PLAN_<ticket>.md <phase|all>"),
    dict(id="approve", kind="you", title="You approve", sub="the plan, 1 of 2",
         source=f"{ADAPTER}/commands/run.md",
         detail="First the planning session asks at most five blocking questions, each with the default it takes "
                "without an answer. Then you give one go or no-go on the lane diagram, the computed ETA, the "
                "verifier's cuts and the open items. A go holds while each phase stays as you saw it: when a fix "
                "or a later revision changes a phase in more than its executor, size, wait, notes or risk, that "
                "phase comes back to you for a new go.",
         never="No owner words stand in for the verifier's APPROVE: --user-approved lifts a drift block or the "
               "review-round cap, never exit 11."),
    dict(id="commit", kind="you", title="You commit", sub="decision 2 of 2",
         source=f"{ADAPTER}/CLAUDE.md",
         detail="The session never commits: you read the test report and the diff, then commit and merge. For a "
                "pull request, concord.py --pr-status exits 0 only when the PR's current diff is REVIEWED. Between "
                "your two decisions a run still comes back to you when a phase changes, a drift limit is reached, "
                "a phase fails three times or a choice is yours to make."),
    dict(id="you-settle", kind="you", title="You settle", sub="consequential choices",
         source=f"{ADAPTER}/skills/design-review/SKILL.md",
         detail="A choice is consequential when plausible answers make different promises to a caller or commit "
                "the project to different responsibilities, whatever the size of the diff. The owner settles it, "
                "from the smallest decision the review names and what changes for whom under each answer; how "
                "the work is split, ordered and delegated stays with the implementer."),
    dict(id="you-rules", kind="you", title="You decide", sub="on the one rules diff",
         source=f"{ADAPTER}/commands/rules-review.md",
         detail="The weekly rules review proposes one diff with a verdict table. Nothing changes before you "
                "approve it, and nothing is hard-deleted."),

    # --- commands and skills (front matter adds name, description and argument hint) ---------------------------
    dict(id="run", kind="command", title="run", sub="Plans, or splits a ticket",
         file=f"{ADAPTER}/commands/run.md",
         reads="PLAN_<ticket>.md when it continues one, the Concord rules in CLAUDE.md, and the state the "
               "dispatcher recorded for the plan (concord.py --phases).",
         writes="The plan: the grill's answers under ## Settled and ## Defaults taken, the lanes under ## Passes "
                "and, when the context runs large, ## Handoff. After the report, the repo-notes lines the ticket "
                "changed.",
         never="Works beyond the approved plan without asking; lets owner words stand in for the verifier's "
               "APPROVE; commits."),
    dict(id="delegate", kind="command", title="delegate", sub="run delegate, on a plan",
         file=f"{ADAPTER}/commands/delegate.md",
         reads="An existing plan; it passes its arguments to /concord:run delegate.",
         writes="Nothing of its own: /concord:run does the work."),
    dict(id="plan-then-delegate", kind="command", title="plan-then-delegate", sub="run delegate, from a task",
         file=f"{ADAPTER}/commands/plan-then-delegate.md",
         reads="The task you describe; it passes it to /concord:run delegate.",
         writes="Nothing of its own: /concord:run does the work."),
    dict(id="rules-review", kind="command", title="rules-review", sub="Weekly, 10 minutes",
         file=f"{ADAPTER}/commands/rules-review.md",
         reads="Your CLAUDE.md, the run workflow, REVIEW.md, the Concord skills, project memory, runs.jsonl, each "
               "repository's findings ledgers and test reports, and the rule candidates in NOTES.md.",
         writes="A table (keep, merge, move or retire, with the reason) and one diff, which you approve before "
                "anything changes.",
         never="Hard-deletes anything or touches another session's files."),
    dict(id="design-review", kind="skill", title="design-review", sub="Callers and owner choices",
         file=f"{ADAPTER}/skills/design-review/SKILL.md",
         reads="The code, file formats, commands and people that use what the change touches; a language "
               "server's callers where one is set up.",
         writes="Nothing: it returns the affected callers, the owner decisions with a recommendation, and what "
                "the implementer may decide alone.",
         never="Lets the size of a diff decide whether a choice is the owner's."),
    dict(id="plan", kind="skill", title="plan", sub="Drafts PLAN_<ticket>.md",
         file=f"{ADAPTER}/skills/plan/SKILL.md",
         reads="The repository notes, the code, the spec or design the task names, the Cases: file the notes "
               "name, and the skills that fit.",
         writes="PLAN_<ticket>.md at the repository root, in the format of PLAN_TEMPLATE.md, kept out of git.",
         never="Edits code while planning, writes minutes (concord.py --estimate computes them), or overwrites "
               "a plan without asking."),
    dict(id="verify-plan", kind="skill", title="verify-plan", sub="A fresh verifier's check",
         file=f"{ADAPTER}/skills/verify-plan/SKILL.md",
         reads="The plan read that concord.py --lint writes for the plan.",
         writes="The verifier's answer, recorded with concord.py --plan-verdict for the exact text it read.",
         never="Has the planner check its own plan, or lets owner words stand in for a new verdict after an edit."),
    dict(id="lean-testing", kind="skill", title="lean-testing", sub="The check that catches",
         file=f"{ADAPTER}/skills/lean-testing/SKILL.md",
         reads="principles.md, before a Test plan, a failing test, a test review or a consolidation pass.",
         writes="One line per behavior or test; in a Concord plan, the Test plan rows (KEEP, EXTEND, MERGE, "
                "REPLACE, DELETE or ADD).",
         never="Lets an implementer edit tests, or removes a test without naming the one that keeps its coverage."),
    dict(id="review-change", kind="skill", title="review-change", sub="Findings on any change",
         file=f"{ADAPTER}/skills/review-change/SKILL.md",
         reads="REVIEW.md first; inside the workflow, gate.md before a ticket's full revision.",
         writes="Findings, most severe first, each with path:line, reproduction, consequence and fix; inside the "
                "workflow the dispatcher records each answer against the head it read.",
         never="Lets the session that wrote or shaped a change review it: a fresh reviewer-opus55 does."),

    # --- agents: writers (teal) and judges (blue); front matter adds description, model, tools and skills ---
    dict(id="plan-verifier", kind="judge", title="plan-verifier", sub="Challenges the plan",
         file=f"{ADAPTER}/agents/plan-verifier.md",
         reads="The plan read named by its hash, and the code the plan touches.",
         writes="One VERDICT block: APPROVE or REVISE, with CUT, MERGE and FIX items, CONFLICTS and PLAN_GAPS.",
         never="Runs commands, edits files, or raises again an item the planner rejected with an owner decision."),
    dict(id="implementer", kind="writer", title="implementer", sub="Writes one phase",
         file=f"{ADAPTER}/agents/implementer.md",
         reads="CONTRACT.md, then the approved plan revision its task names, never the plan file on disk.",
         writes="The files in the phase's Files: and Follow-through: lists, and the contract's report block.",
         never="Edits tests it is graded by, stages, commits or changes branches."),
    dict(id="implementer-opus48", kind="writer", title="implementer-opus48", sub="The Opus 4.8 fallback",
         file=f"{ADAPTER}/agents/implementer-opus48.md",
         reads="CONTRACT.md, then the approved plan revision its task names.",
         writes="The files in the phase's Files: and Follow-through: lists, and the contract's report block.",
         never="Edits tests it is graded by, stages, commits or changes branches."),
    dict(id="reviewer-opus55", kind="judge", title="reviewer-opus55", sub="Medium and high reviews",
         file=f"{ADAPTER}/agents/reviewer-opus55.md",
         reads="One review packet or brief, then repository files only to confirm a suspicion, in the read-only "
               "copy the packet names.",
         writes="One REVIEW-JSON block; each confirmed BLOCKER, HIGH or MEDIUM finding streamed as it lands.",
         never="Edits files, runs git commands that change anything, or reports a finding it cannot anchor to a "
               "line of the diff."),
    dict(id="reviewer-delta", kind="judge", title="reviewer-delta", sub="Checks a fix's delta",
         file=f"{ADAPTER}/agents/reviewer-delta.md",
         reads="One delta packet: the open findings and the numbered hunks of the fix.",
         writes="One REVIEW-JSON block that resolves each finding and explains each hunk.",
         never="Edits anything, or guesses: a finding stays open unless it answers yes."),
    dict(id="planning-session", kind="planner", title="planning session", sub="The strongest model",
         source=f"{ADAPTER}/CLAUDE.md",
         detail="The Claude Code session you typed /concord:run in, on the strongest model available at high "
                "effort. It plans, asks the grill, has the failing tests written first, writes what costs less "
                "to write than to specify (every phase in execute mode), reads each run's change, records the "
                "verdicts, fixes confirmed findings and hands you the report.",
         never="Commits: the user reviews the diff and commits."),
    dict(id="executor", kind="writer", title="executor", sub="OpenCode or pi, low cost",
         source="concord/executors.conf",
         detail="In delegate mode a phase whose Executor: names a model from models.conf runs on an external "
                "coding-agent CLI (OpenCode, pi, Qwen Code and others) under the shared executor contract. "
                "Claude models never run there: they run as the implementer subagents. The write scope is "
                "enforced during the run only on OpenCode, which also runs under a macOS sandbox profile.",
         reads="The run's snapshot of the approved plan and phase, with the repository notes prepended.",
         writes="Files inside the phase's write scope; a change outside it rejects the run.",
         never="Grades its own work: the dispatcher re-runs the acceptance on the candidate."),
    dict(id="flash", kind="judge", title="flash reviewer", sub="Another model family",
         source=f"{ADAPTER}/skills/review-change/gate.md",
         detail="A low-cost model from another family than Opus, called by concord.py --review or --review-pr "
                "with the prompt in REVIEW.md. It reviews the low tier alone, approve-only, joins "
                "reviewer-opus55 at the high tier because its blind spots differ, and runs the delta reviews.",
         never="Raises a file above its rank: a flash review counts at the low tier at most."),
    dict(id="review-agent", kind="judge", title="read-only agent", sub="Lists rules to retire",
         source=f"{ADAPTER}/commands/rules-review.md",
         detail="One fresh read-only agent on the Claude subscription reads CLAUDE.md, the run workflow, "
                "REVIEW.md, the Concord skills and the feedback memory, and lists duplicates, contradictions, "
                "superseded rules, rules a hook or concord.py already enforces, and rules for one repository "
                "only."),
    dict(id="implement", kind="writer", title="implement", sub="Execute or delegate",
         source=f"{ADAPTER}/commands/run.md",
         detail="Each approved phase in dependency order. Execute: the planning session writes it between "
                "concord.py --begin and --end. Delegate: the phase goes to the executor the plan assigns, a "
                "low-cost model for bulky, well-specified work, inside its Files: and Follow-through: lists. "
                "Phases whose files are disjoint run at once; a phase that shares a file runs in a fork "
                "(wt.py fork), and the run lock refuses a run whose files overlap a live run's.",
         reads="The run's snapshot of the approved plan text, never the plan file.",
         writes="Only the files in Files: and Follow-through:; any other change rejects the run.",
         never="Edits the tests it is graded by, stages, commits or changes branches (CONTRACT.md)."),

    # --- dispatcher steps and scripts --------------------------------------------------------------------------
    dict(id="wt", kind="step", title="wt.py", sub="A worktree per ticket",
         source="concord/wt.py", wt=True,
         detail="new makes the worktree from the main checkout and links the configured folders; fork and join "
                "run a phase that shares a file in its own copy and apply its graded change back; done archives "
                "the plan and removes the worktree once you have committed.",
         type="python3 ~/.claude/concord/wt.py new <TICKET>",
         never="Deletes a branch or a commit."),
    dict(id="red", kind="step", title="tests fail first", sub="Written, then a red run",
         source=f"{ADAPTER}/commands/run.md", flags=["--no-baseline", "--force"],
         detail="For a changed behavior the planning session writes the failing tests in their own run and checks "
                "that each fails for the stated reason; a routine change under characterization checks needs "
                "none. Before an executor run the dispatcher runs the phase's acceptance on a copy of the "
                "untouched tree: a phase whose acceptance already passes is not run (exit 6), because its tests "
                "do not test it. A session run (--begin) records the same baseline and warns."),
    dict(id="check", kind="step", title="check", sub="Grades the candidate",
         source="concord/concord.py", flags=["--verdict", "--cause", "--grade"], cmd=["--verdict"],
         detail="After a run the checkout becomes its candidate, and the dispatcher runs the acceptance commands "
                "on a copy of it, never on the executor's account. The planning session reads the report and "
                "the change, then records PASS or FAIL with a cause. A PASS is refused (exit 7) when a result is "
                "missing or unexpected, the run was rejected, or the checkout no longer holds the graded "
                "candidate. Only EXECUTOR failures count as attempts: three, then you decide.",
         never="Takes the executor's own account of its work."),
    dict(id="review", kind="step", title="review", sub="By risk tier", view="review-tiers",
         source=f"{ADAPTER}/skills/review-change/gate.md",
         flags=["--review", "--packet", "--review-record", "--review-pr", "--delta"],
         detail="Each implementing phase is reviewed at its Risk: tier: low by a flash model, approve-only; medium "
                "by reviewer-opus55; high by both at once. A round is a full review, the fixes, then a delta "
                "review that closes the findings it shows fixed; the loop stops at no open BLOCKER or HIGH. A "
                "review reads the run's graded change in a read-only copy of the candidate."),
    dict(id="report", kind="step", title="report", sub="From recorded data",
         source="concord/concord.py", flags=["--report"], cmd=["--report"],
         detail="Writes the test report once every run of the plan has a verdict. It opens with the overrides "
                "(forced PASS, owner words and their use, waivers, phases reviewed below their risk), then each "
                "phase with who wrote it, the plan revision, the graded candidate and its review, the Test plan, "
                "each finding's outcome, the open items and the time against the ETA. Writing it stops the drift "
                "clock and closes the plan to new runs (exit 10).",
         never="Writes while a run of the plan is open or has no verdict (exit 2)."),
    dict(id="lint", kind="step", title="--lint", sub="Writes the plan read",
         source="concord/concord.py", flags=["--lint"], cmd=["--lint"],
         detail="A read-only pre-flight of a phase that makes no model call: ACCEPTANCE LINT lines for defects in "
                "acceptance commands that plan reviews kept rediscovering, and PLAN LINT lines for missing "
                "Size:, ETA: or Tests: lines. It writes the plan's approval-relevant text to a plan read named by "
                "its hash and prints PLAN-READ: <path>."),
    dict(id="plan-verdict", kind="step", title="--plan-verdict", sub="Records the APPROVE",
         source="concord/concord.py", flags=["--plan-verdict"], cmd=["--plan-verdict"],
         detail="Reads the verifier's answer. An APPROVE that quotes the hash of a plan read of the plan's current "
                "text becomes the next approved revision of the ticket; a REVISE records nothing (exit 1). Only "
                "that text opens --begin and executor runs.",
         never="Records an approval for a plan read that no longer hashes to its name."),
    dict(id="estimate", kind="step", title="--estimate", sub="Lanes, critical path, ETA",
         source="concord/concord.py", flags=["--estimate"], cmd=["--estimate"],
         detail="Turns each phase's Size: and After: waits, and the median and p75 run times in the run ledger, "
                "into phase minutes, the lanes, the critical path and the ETA, and stores the ETA for the drift "
                "gate. Code computes; the model challenges."),
    dict(id="begin-end", kind="step", title="--begin / --end", sub="A session run",
         source="concord/concord.py", flags=["--begin", "--end", "--abort"], cmd=["--begin", "--end"],
         detail="Wraps a phase written by the planning session or a Claude implementer subagent, so it gets the "
                "same gates, backup, scope report and plan check as an executor run. --begin refuses a plan text "
                "with no APPROVE (exit 11) and a drift block (exit 10), takes the run lock and prints the run's "
                "snapshot of the approved plan; --end writes the report."),
    dict(id="executor-run", kind="step", title="executor run", sub="One phase, external CLI",
         source="concord/concord.py", flags=["words", "--extra", "--wall"],
         type="python3 ~/.claude/concord/concord.py <model> <phase> --plan PLAN_<ticket>.md",
         detail="Runs one phase on an external coding-agent CLI under the executor contract: it records the start "
                "tree, backs up in-scope files, runs the red run, starts the executor in the checkout, then "
                "reports from snapshots, never from the executor's account. A change outside the write scope, a "
                "deletion, a staged path or a moved branch rejects the run."),
    dict(id="run-record", kind="step", title="each run", sub="Session or executor",
         source="concord/concord.py", flags=["--begin", "--end"],
         detail="Every run, a session run between --begin and --end or an executor run, checks the plan's "
                "approved revision before it starts (exit 11 without one), keeps its evidence in its run folder "
                "and appends a line to runs.jsonl when it ends; each verdict appends another."),
    dict(id="pr-status", kind="step", title="--pr-status", sub="The pull request gate",
         source="concord/concord.py", flags=["--pr-status", "--exclude"], cmd=["--pr-status"],
         detail="Reads the pull request's diff from its merge base to its current head. Each file needs the "
                "highest Risk: among the runs whose work is in the PR's commits, or medium when no run's is. It "
                "prints REVIEWED, and exits 0, only when no finding is open and every file is covered at its tier "
                "by a review that read it, or excluded by the owner's words naming it."),
    dict(id="tier", kind="step", title="tier", sub="Risk: and the floor",
         source=f"{ADAPTER}/skills/review-change/gate.md", flags=["--tier"],
         detail="A phase's tier is its Risk: line, medium when it has none, raised for matching non-test files by "
                "a repo-notes Risk floor line. High risk means untrusted input, scores or thresholds, security, "
                "money, data deletion or concurrency. At the pull request gate a tier below a file's need is "
                "refused."),
    dict(id="low", kind="step", title="low tier", sub="One flash review",
         source=f"{ADAPTER}/skills/review-change/gate.md", flags=["--review"],
         detail="concord.py --review <run> on a flash model. Approve-only: it judges BLOCKER and HIGH only, keeps a "
                "MEDIUM it reports as a note, and its clean verdict reads CLEAN at low (BLOCKER and HIGH only)."),
    dict(id="medium", kind="step", title="medium tier", sub="reviewer-opus55",
         source=f"{ADAPTER}/skills/review-change/gate.md", flags=["--packet", "--review-record"],
         detail="concord.py --review <run> --packet writes a review packet; a fresh reviewer-opus55 agent answers "
                "it each round, and --review-record stores the answer. A CLEAN review at medium found no "
                "BLOCKER, HIGH or MEDIUM."),
    dict(id="high", kind="step", title="high tier", sub="Both, at the same time",
         source=f"{ADAPTER}/skills/review-change/gate.md", flags=["--review", "--packet"],
         detail="reviewer-opus55 and, started at the same time, a flash review from another model family, whose "
                "findings join the same list. The report lists a high phase without that second review under "
                "Overrides."),
    dict(id="delta", kind="step", title="delta review", sub="Reads only the fix",
         source=f"{ADAPTER}/skills/review-change/gate.md", flags=["--delta"],
         detail="After a fix, a delta review answers for each open finding (yes with the lines as evidence, else "
                "no or unsure) and ties each changed hunk to the finding it fixes. A hunk that changes anything "
                "else stays for a review at its file's tier. Delta reviews run on flash, else on reviewer-delta, "
                "never on Opus."),

    # --- files and records ---------------------------------------------------------------------------------------
    dict(id="plan-file", kind="file", title="PLAN_<ticket>.md", sub="The plan you approve",
         source="concord/PLAN_TEMPLATE.md",
         detail="One page at the repository root, kept out of git: Done when, Design, Test plan, open questions "
                "and, per phase, Executor:, Risk:, Size:, Files:, Follow-through:, the steps and the acceptance "
                "commands. The verifier's APPROVE binds to its approval-relevant text: an edit outside the prose "
                "of ## Open questions, ## Handoff and ## Passes needs a new verdict."),
    dict(id="plan-read", kind="file", title="plan read", sub="plan-reads/<hash>.md",
         source="concord/concord.py",
         detail="--lint writes the plan's approval-relevant text to the runs root as plan-reads/<hash>.md. The "
                "verifier reads this file and quotes its hash, --plan-verdict records that hash, and each run "
                "checks that the stored read still holds the approved text."),
    dict(id="drift-json", kind="file", title="drift.json", sub="Approvals, ETA, clock",
         source="concord/concord.py",
         detail="In the runs root, per ticket: the approved revisions (the plan read hashes), the ETA that "
                "--estimate stored, the drift clock, and whether the report closed the plan. --drift warns at "
                "1.2 times the measure and blocks at 1.5 times (exit 10)."),
    dict(id="run-folder", kind="file", title="run folder", sub="concord/<run-id>/",
         source="concord/concord.py",
         detail="One folder per run under the repository's git directory, outside the working tree: the backup of "
                "in-scope files, the run's snapshot of the approved plan and phase, the baseline and acceptance "
                "results, report.md, meta.json with the start tree and the candidate, and the review answers."),
    dict(id="runs-jsonl", kind="file", title="runs.jsonl", sub="Every run, every repo",
         source="concord/concord.py",
         detail="~/.claude/concord/runs.jsonl: one line per run and per verdict, across repositories, written best "
                "effort (a sandbox may make it read-only). --estimate reads its run times; the weekly rules "
                "review reads its verdicts and causes."),
    dict(id="ledger", kind="file", title="findings ledger", sub="ledger/<key>.json",
         source="concord/concord.py",
         detail="Per ticket or per pull request, in the runs root: every finding with its severity, reproduction "
                "and head, each resolution and the review that closed it, written atomically under a lock. An "
                "unreadable ledger stops the dispatcher (exit 2) instead of being reset."),
    dict(id="report-file", kind="file", title="test report", sub="REPORT_<ticket>-<id>.md",
         source="concord/concord.py",
         detail="The report --report writes in the runs root, for your acceptance test: overrides first, then the "
                "phases, the Test plan, the reviews and each finding's outcome, the open items and the time "
                "against the ETA."),
    dict(id="repo-notes", kind="file", title="repo notes", sub="repo-notes/<repo>.md",
         source="concord/repo-notes/README.md",
         detail="Binding facts for executors, keyed by the main checkout's folder name: prepended to every "
                "executor task and added to every review prompt, cut at 4000 characters. A Risk floor "
                "<tier>: <globs> line raises the review tier of matching files."),
    dict(id="claude-md", kind="file", title="CLAUDE.md rules", sub="The Concord block",
         source=f"{ADAPTER}/CLAUDE.md",
         detail="The block the installer merges into ~/.claude/CLAUDE.md: four outcomes that hold firm "
                "(governance, testing, code quality, truthful outcomes), when to plan and when to edit directly, "
                "the agent names, the planner model, and that the session never commits."),
    dict(id="review-md", kind="file", title="REVIEW.md", sub="Three closed questions",
         source="concord/REVIEW.md",
         detail="The review prompt: does the change meet each clause of its spec, does a concrete input break a "
                "promised behavior, and can each touched test fail. A finding above NOTE needs a reproduction."),
    dict(id="gate-md", kind="file", title="gate.md", sub="Tiers and the PR gate",
         source=f"{ADAPTER}/skills/review-change/gate.md",
         detail="The review gate inside the workflow: phase tiers and reviewers, the review loop, delta reviews, "
                "and the pull request gate with its coverage and waiver rules."),
    dict(id="principles", kind="file", title="principles.md", sub="What a test must earn",
         source=f"{ADAPTER}/skills/lean-testing/principles.md",
         detail="The principles of lean testing: an expected value must come from a source that outranks the code, "
                "and a test set is a filter that catches broken changes and passes allowed ones."),
    dict(id="callers", kind="file", title="the code", sub="And every caller of it",
         source=f"{ADAPTER}/skills/design-review/SKILL.md",
         detail="The code, file formats, commands and people that use what a change touches, and what each relies "
                "on. Where a language server is set up, the callers and tests come from it: a text search misses "
                "aliased imports and finds the name in strings and comments."),
    dict(id="rules-diff", kind="file", title="one proposed diff", sub="With a verdict table",
         source=f"{ADAPTER}/commands/rules-review.md",
         detail="The output of the weekly rules review: a table of rules (keep, merge into, move to, retire, with "
                "the reason) and the one diff that applies it."),

    # --- refusals ------------------------------------------------------------------------------------------------
    dict(id="exit-6", kind="stop", title="exit 6", sub="Acceptance already green",
         source="concord/concord.py",
         detail="The red run found acceptance commands that pass before the change, so the phase is not run: "
                "mark each one (characterization) if it guards existing behavior, or fix the test."),
    dict(id="exit-7", kind="stop", title="exit 7", sub="PASS refused",
         source="concord/concord.py",
         detail="An acceptance result is missing or not the expected one, the run was rejected, a post-run command "
                "changed the tree, or the checkout no longer holds the graded candidate or its grading files. "
                "--force records PASS (forced), which the report lists first, under Overrides."),
    dict(id="exit-1", kind="stop", title="exit 1", sub="Not REVIEWED yet",
         source="concord/concord.py",
         detail="--pr-status exits 1 unless the PR's current head is REVIEWED: an open finding, or a file not "
                "covered at its tier by a review that read it. A review counts at most at its reviewer's rank, "
                "and owner words never raise it."),
]

# ----------------------------------------------------------------------------------------------------------------
# Hand-laid views. Positions are (column, y): x = column * CW. Edges: (from, to, kind, label, route), where route
# "h" runs side to side through a column gap, "v" top to bottom through a row gap, and "loop" dips below a row.
# ----------------------------------------------------------------------------------------------------------------
OVERVIEW = dict(
    id="overview", title="From ticket to commit",
    about="You approve the plan and you commit. Between the two, the run comes back to you when a phase changes, "
          "a limit is reached or a phase fails three times.",
    place=[("ticket", 0, 0), ("run", 1, 0), ("plan-verifier", 2, 0), ("approve", 3, 0), ("commit", 5, 0),
           ("wt", 0, 142), ("red", 1, 142), ("implement", 2, 142), ("check", 3, 142), ("review", 4, 142),
           ("report", 5, 142),
           ("design-review", 0, 318), ("plan", 1, 318), ("verify-plan", 2, 318), ("lean-testing", 3, 318),
           ("review-change", 4, 318), ("rules-review", 5, 318)],
    edges=[("ticket", "run", "calls", None, "h"), ("run", "plan-verifier", "calls", None, "h"),
           ("plan-verifier", "approve", "calls", None, "h"), ("approve", "red", "calls", "go", "v"),
           ("red", "implement", "calls", None, "h"), ("implement", "check", "calls", None, "h"),
           ("check", "review", "calls", None, "h"), ("review", "report", "calls", None, "h"),
           ("report", "commit", "calls", None, "v"),
           ("review", "implement", "loop", "fix, then a delta review", "loop"),
           ("run", "wt", "feeds", "worktree", "v")],
    groups=[("A run does these", ["red", "implement", "check", "review", "report"]),
            ("Any time, each on its own",
             ["design-review", "plan", "verify-plan", "lean-testing", "review-change", "rules-review"])],
)

REVIEW_TIERS = dict(
    id="review-tiers", title="Review tiers",
    about="Who reads a change at each risk tier, how a fix is checked, and the pull request gate.",
    place=[("plan-file", 0, 0), ("tier", 0, 110), ("repo-notes", 0, 220),
           ("low", 1, 0), ("medium", 1, 110), ("high", 1, 220),
           ("flash", 2, 0), ("reviewer-opus55", 2, 110),
           ("ledger", 3, 110), ("delta", 3, 220), ("reviewer-delta", 3, 330),
           ("pr-status", 4, 110), ("exit-1", 4, 220), ("commit", 5, 110)],
    edges=[("plan-file", "tier", "feeds", "Risk:", "v"), ("repo-notes", "tier", "feeds", "Risk floor", "v"),
           ("tier", "low", "calls", None, "h"), ("tier", "medium", "calls", None, "h"),
           ("tier", "high", "calls", None, "h"),
           ("low", "flash", "calls", None, "h"), ("medium", "reviewer-opus55", "calls", None, "h"),
           ("high", "reviewer-opus55", "calls", None, "h"), ("high", "flash", "calls", None, "h"),
           ("flash", "ledger", "feeds", None, "h"), ("reviewer-opus55", "ledger", "feeds", None, "h"),
           ("ledger", "delta", "calls", "after a fix", "v"), ("delta", "ledger", "loop", "closes fixed", "v"),
           ("delta", "reviewer-delta", "calls", "if no flash", "v"),
           ("ledger", "pr-status", "feeds", None, "h"), ("pr-status", "commit", "calls", None, "h"),
           ("pr-status", "exit-1", "calls", None, "v")],
    groups=[("Tier, from the phase's Risk:", ["low", "medium", "high"]),
            ("Pull request gate", ["pr-status", "exit-1"])],
)

FILES = dict(
    id="files", title="Files and records",
    about="What the dispatcher and the agents write, and who reads it. Dotted arrows point from writer to record "
          "and from record to reader.",
    place=[("planning-session", 0, 48), ("lint", 0, 192), ("plan-verdict", 0, 288),
           ("repo-notes", 1, 0), ("plan-file", 1, 96), ("plan-read", 1, 192), ("drift-json", 1, 288),
           ("executor", 2, 0), ("plan-verifier", 2, 96), ("run-record", 2, 192), ("review", 2, 288),
           ("report", 2, 384),
           ("run-folder", 3, 48), ("runs-jsonl", 3, 192), ("ledger", 3, 288), ("report-file", 3, 384),
           ("estimate", 4, 192), ("pr-status", 4, 288), ("commit", 4, 384)],
    edges=[("planning-session", "repo-notes", "feeds", None, "h"),
           ("planning-session", "plan-file", "feeds", None, "h"),
           ("plan-file", "lint", "feeds", None, "h"), ("lint", "plan-read", "feeds", None, "h"),
           ("plan-read", "plan-verdict", "feeds", None, "h"), ("plan-verdict", "drift-json", "feeds", None, "h"),
           ("repo-notes", "executor", "feeds", None, "h"), ("plan-read", "plan-verifier", "feeds", None, "h"),
           ("drift-json", "run-record", "feeds", None, "h"),
           ("run-folder", "executor", "feeds", None, "h"), ("run-record", "run-folder", "feeds", None, "h"),
           ("run-record", "runs-jsonl", "feeds", None, "h"), ("review", "ledger", "feeds", None, "h"),
           ("ledger", "report", "feeds", None, "h"), ("report", "report-file", "feeds", None, "h"),
           ("runs-jsonl", "estimate", "feeds", None, "h"), ("ledger", "pr-status", "feeds", None, "h"),
           ("report-file", "commit", "feeds", None, "h")],
    groups=[("Plan and approval", ["repo-notes", "plan-file", "plan-read", "drift-json"]),
            ("Runs and reviews", ["run-folder", "runs-jsonl", "ledger", "report-file"])],
)

# ----------------------------------------------------------------------------------------------------------------
# Generated views, one per command and skill: inputs on the left, the command or skill in the middle, what it
# loads, runs, names and writes on the right, and in a far column what those start, write or refuse.
# Item relations: "reads" (item to center, dotted), "by" (item calls or loads the center), "loads", "runs" and
# "names" (center to item, solid), "writes" (center to item, dotted). Far edges: (parent, child, relation).
# ----------------------------------------------------------------------------------------------------------------
AUTO_VIEWS = {
    "run": dict(
        left=[("It reads", [("plan-file", "reads"), ("claude-md", "reads")]),
              ("It loads", [("plan", "loads"), ("design-review", "loads"), ("verify-plan", "loads"),
                            ("lean-testing", "loads"), ("review-change", "loads")])],
        right=[("It runs, in order", [("wt", "runs"), ("estimate", "runs"), ("begin-end", "runs"),
                                      ("executor-run", "runs"), ("check", "runs"), ("report", "runs")])],
        far=("Who writes, what is kept, what refuses",
             [("begin-end", "planning-session", "names"), ("begin-end", "implementer", "names"),
              ("begin-end", "implementer-opus48", "names"), ("executor-run", "executor", "names"),
              ("executor-run", "exit-6", "runs"), ("check", "exit-7", "runs"),
              ("report", "report-file", "writes")])),
    "delegate": dict(
        left=[("It reads", [("plan-file", "reads")])],
        right=[("It runs, in delegate mode", [("run", "runs")])]),
    "plan-then-delegate": dict(
        left=[("You give it a task", [("ticket", "by")])],
        right=[("It runs, in delegate mode", [("run", "runs")])]),
    "rules-review": dict(
        left=[("It reads", [("claude-md", "reads"), ("review-md", "reads"), ("runs-jsonl", "reads"),
                            ("ledger", "reads"), ("report-file", "reads")])],
        right=[("It names", [("review-agent", "names")]), ("It writes", [("rules-diff", "writes")])],
        far=("Then", [("rules-diff", "you-rules", "runs")])),
    "design-review": dict(
        left=[("Loaded by", [("run", "by"), ("plan", "by"), ("plan-verifier", "by")]),
              ("It reads", [("callers", "reads")])],
        right=[("It returns, for you", [("you-settle", "writes")])]),
    "plan": dict(
        left=[("Loaded by", [("run", "by")]), ("It reads", [("repo-notes", "reads"), ("callers", "reads")])],
        right=[("It loads", [("design-review", "loads"), ("lean-testing", "loads")]),
               ("It writes", [("plan-file", "writes")])],
        far=("Next", [("plan-file", "verify-plan", "writes")])),
    "verify-plan": dict(
        left=[("Loaded by", [("run", "by")]), ("It reads", [("plan-file", "reads")])],
        right=[("It runs, in order", [("lint", "runs"), ("plan-verifier", "names"), ("plan-verdict", "runs")])],
        far=("What is kept", [("lint", "plan-read", "writes"), ("plan-read", "plan-verifier", "reads"),
                              ("plan-verdict", "drift-json", "writes")])),
    "lean-testing": dict(
        left=[("Loaded by", [("run", "by"), ("plan", "by"), ("plan-verifier", "by")]),
              ("It reads", [("principles", "reads")])],
        right=[("It feeds the Test plan of", [("plan-file", "writes")])]),
    "review-change": dict(
        left=[("Loaded by", [("run", "by")]), ("It reads", [("review-md", "reads"), ("gate-md", "reads")])],
        right=[("It names", [("reviewer-opus55", "names")]), ("It runs", [("review", "runs"), ("pr-status", "runs")])],
        far=("Reviewers, records, refusals",
             [("review", "flash", "names"), ("review", "reviewer-delta", "names"), ("review", "ledger", "writes"),
              ("ledger", "pr-status", "reads"), ("pr-status", "exit-1", "runs")])),
}
AUTO_ABOUT = {
    "command": "What it reads, what it runs, the agents it names and what it writes. Click it for its contract.",
    "skill": "Who loads it, what it reads and what it returns. Click it for its contract.",
}
MENU = [("Flows", ["overview", "review-tiers", "files"]),
        ("Commands", ["run", "delegate", "plan-then-delegate", "rules-review"]),
        ("Skills", ["design-review", "plan", "verify-plan", "lean-testing", "review-change"])]


class MapError(Exception):
    pass


def rel(path):
    return path.relative_to(ROOT).as_posix()


def front_matter(path):
    """The key: value lines (and `  - item` lists) between the leading --- lines of a markdown file."""
    lines = path.read_text().splitlines()
    if not lines or lines[0].strip() != "---":
        raise MapError(f"{rel(path)}: no front matter")
    out, key = {}, None
    for line in lines[1:]:
        if line.strip() == "---":
            return out
        item = re.match(r"^\s+-\s+(.*)$", line)
        if item and key:
            out[key] = (out[key] if isinstance(out[key], list) else []) + [item.group(1).strip()]
            continue
        m = re.match(r"^([A-Za-z][\w-]*):\s*(.*)$", line)
        if m:
            key, out[m.group(1)] = m.group(1), m.group(2).strip()
    raise MapError(f"{rel(path)}: front matter is not closed")


def run_help(script):
    """`<script> --help` with a wide terminal, so argparse keeps every help text on one line."""
    env = {k: v for k, v in os.environ.items() if k not in ("FORCE_COLOR", "PYTHON_COLORS")}
    env.update(COLUMNS="1000", NO_COLOR="1")
    proc = subprocess.run([sys.executable, "-B", "-I", str(ROOT / script), "--help"], capture_output=True,
                          text=True, env=env, cwd=ROOT, timeout=60)
    if proc.returncode != 0:
        raise MapError(f"{script} --help exited {proc.returncode}: {proc.stderr.strip()[-200:]}")
    return proc.stdout


def parse_help(text):
    """(description, {option: {"usage", "help"}}) from argparse help output."""
    lines = text.splitlines()
    i = 0
    while i < len(lines) and lines[i].strip():        # the usage block ends at the first blank line
        i += 1
    desc = []
    for line in lines[i + 1:]:
        if not line.strip() or line.rstrip().endswith(":"):
            break
        desc.append(line.strip())
    flags, last = {}, None
    for line in lines:
        m = re.match(r"^  (\S.*?)(?:\s{2,}(\S.*))?$", line)
        if m and not line.startswith("   "):
            usage = m.group(1).strip()
            name = next((t.rstrip(",") for t in usage.split() if t.startswith("--")), usage.split()[0])
            last = flags[name] = {"usage": usage, "help": (m.group(2) or "").strip()}
        elif last is not None and line.startswith("    ") and line.strip():
            last["help"] = (last["help"] + " " + line.strip()).strip()
        else:
            last = None
    return " ".join(desc), flags


def build():
    problems = []
    nodes = {}
    _desc, flags = parse_help(run_help("concord/concord.py"))
    wt_desc, wt_flags = parse_help(run_help("concord/wt.py"))
    wt_subs = next((u["usage"].strip("{}").split(",") for u in wt_flags.values() if u["usage"].startswith("{")), [])

    for spec in NODES:
        n = dict(spec)
        nid, kind = n["id"], n["kind"]
        if nid in nodes:
            problems.append(f"node {nid}: defined twice")
        if kind not in KINDS:
            problems.append(f"node {nid}: unknown kind {kind}")
        limits = (MAX_HEX_TITLE, MAX_HEX_SUB) if kind == "you" else (MAX_TITLE, MAX_SUB)
        for field, limit in zip(("title", "sub"), limits):
            if len(n.get(field, "")) > limit:
                problems.append(f"node {nid}: {field} longer than {limit} characters: {n[field]!r}")
        facts, name = [], n["title"]
        if "file" in n:
            path = ROOT / n["file"]
            n["source"] = n.pop("file")
            if not path.is_file():
                problems.append(f"node {nid}: source {n['source']} is missing")
                continue
            fm = front_matter(path)
            if kind in ("command", "skill"):
                name = fm.get("name") or f"concord:{path.stem}"
                n["type"] = f"/{name} {fm.get('argument-hint', '')}".strip()
            else:
                name = fm.get("name", path.stem)
            if not fm.get("description"):
                problems.append(f"node {nid}: {n['source']} has no description")
            n["detail"] = fm.get("description", "")
            agent_facts = [("Model", " ".join(x for x in (fm.get("model", ""), fm.get("effort") and
                                                          f"effort {fm['effort']}") if x)),
                           ("Tools", fm.get("tools", "")),
                           ("Preloads", ", ".join(fm["skills"]) if isinstance(fm.get("skills"), list) else "")]
        else:
            agent_facts = []
        if kind == "command" or kind == "skill":
            name = "/" + name
            n["view"] = nid
        if n.pop("wt", False):
            n["detail"] = f"{wt_desc} {n['detail']}"
            n["subcommands"] = ", ".join(wt_subs)
        if not (ROOT / n["source"]).is_file():
            problems.append(f"node {nid}: source {n['source']} is missing")
        command = list(filter(None, n.get("type", "").split("\n")))
        for flag in n.get("cmd", []):
            if flag in flags:
                command.append(f"python3 ~/.claude/concord/concord.py {flags[flag]['usage']}")
        if command:
            facts.append(["You type" if kind in ("you", "command", "skill") else "Command", "\n".join(command),
                          "code"])
        if n.get("subcommands"):
            facts.append(["Subcommands", n["subcommands"]])
        for label, key in (("Reads", "reads"), ("Writes", "writes"), ("Never", "never")):
            if n.get(key):
                facts.append([label, n[key]])
        facts += [[k, v] for k, v in agent_facts if v]
        listed = []
        for flag in n.get("flags", []):
            if flag not in flags:
                problems.append(f"node {nid}: {flag} is not in concord.py --help")
            elif flags[flag]["help"]:
                listed.append([flags[flag]["usage"], flags[flag]["help"]])
        if listed:
            facts.append(["concord.py --help", listed, "flags"])
        out = {"id": nid, "kind": kind, "title": n["title"], "sub": n["sub"], "name": name,
               "detail": n.get("detail", ""), "facts": facts, "source": n["source"]}
        if n.get("view"):
            out["view"] = n["view"]
        if not out["detail"]:
            problems.append(f"node {nid}: no detail")
        nodes[nid] = out

    # Every command, skill and agent the adapter ships has a node (and each command and skill a view).
    shipped = {f"{ADAPTER}/commands/{p.name}" for p in (ROOT / ADAPTER / "commands").glob("*.md")}
    shipped |= {rel(p) for p in (ROOT / ADAPTER / "skills").glob("*/SKILL.md")}
    shipped |= {f"{ADAPTER}/agents/{p.name}" for p in (ROOT / ADAPTER / "agents").glob("*.md")}
    covered = {n["source"] for n in nodes.values() if n["kind"] in ("command", "skill") + AGENT_KINDS}
    for path in sorted(shipped - covered):
        problems.append(f"{path} has no node in scripts/site_map.py")

    views = [hand_view(OVERVIEW, nodes, problems)]
    for nid in [i for _label, ids in MENU[1:] for i in ids]:
        if nid not in AUTO_VIEWS:
            problems.append(f"view {nid}: no entry in AUTO_VIEWS")
            continue
        views.append(auto_view(nid, AUTO_VIEWS[nid], nodes, problems))
    views += [hand_view(REVIEW_TIERS, nodes, problems), hand_view(FILES, nodes, problems)]
    ids = {v["id"] for v in views}
    for n in nodes.values():
        if n.get("view") and n["view"] not in ids:
            problems.append(f"node {n['id']}: its view {n['view']} does not exist")
    menu = [{"label": label, "views": [v for v in vids if v in ids]} for label, vids in MENU]
    used = {p["id"] for v in views for p in v["nodes"]}
    for nid in sorted(set(nodes) - used):
        problems.append(f"node {nid}: in no view")
    if problems:
        raise MapError("\n".join(problems))
    return {"repo": REPO_URL, "blob": BLOB_URL, "size": {"w": W, "h": H}, "kinds": KINDS, "menu": menu,
            "nodes": nodes, "views": views}


def view_record(vid, title, about, place, edges, groups, nodes, problems):
    for p in place:
        if p["id"] not in nodes:
            problems.append(f"view {vid}: unknown node {p['id']}")
    seen = [p["id"] for p in place]
    if len(seen) != len(set(seen)):
        problems.append(f"view {vid}: a node is placed twice")
    for i, a in enumerate(place):            # boxes keep a clear margin, so nothing overlaps at any zoom
        for b in place[i + 1:]:
            if abs(a["x"] - b["x"]) < W + 24 and abs(a["y"] - b["y"]) < H + 12:
                problems.append(f"view {vid}: {a['id']} and {b['id']} overlap")
    out_edges = []
    for e in edges:
        frm, to, kind, label, route = e
        if frm not in seen or to not in seen:
            problems.append(f"view {vid}: edge {frm} -> {to} names a node not in the view")
        if kind not in EDGE_KINDS:
            problems.append(f"view {vid}: edge {frm} -> {to} has unknown kind {kind}")
        rec = {"from": frm, "to": to, "kind": kind, "route": route}
        if label:
            rec["label"] = label
        out_edges.append(rec)
    out_groups = []
    for label, ids in groups:
        missing = [i for i in ids if i not in seen]
        if missing:
            problems.append(f"view {vid}: group {label!r} names nodes not in the view: {missing}")
        out_groups.append({"label": label, "ids": ids})
    return {"id": vid, "title": title, "about": about, "nodes": place, "edges": out_edges, "groups": out_groups}


def hand_view(spec, nodes, problems):
    place = [{"id": nid, "x": col * CW, "y": y} for nid, col, y in spec["place"]]
    return view_record(spec["id"], spec["title"], spec["about"], place, spec["edges"], spec["groups"], nodes,
                       problems)


def stack(groups, x, center_y):
    """Positions and group boxes for groups of ids stacked in one column, centered on center_y."""
    height = sum(len(ids) * PITCH - (PITCH - H) for _l, ids in groups) + GROUP_GAP * (len(groups) - 1)
    y, place = center_y + H / 2 - height / 2, []
    for _label, ids in groups:
        for nid in ids:
            place.append({"id": nid, "x": x, "y": round(y)})
            y += PITCH
        y += GROUP_GAP - (PITCH - H)
    return place


def auto_view(nid, spec, nodes, problems):
    """A command's or skill's own view, laid out in columns so every edge runs between adjacent columns."""
    def item(entry):
        return entry if len(entry) == 3 else (entry[0], entry[1], None)

    center = nodes.get(nid)
    if center is None:
        problems.append(f"view {nid}: no node")
        return {"id": nid, "title": nid, "about": "", "nodes": [], "edges": [], "groups": []}
    edges, groups = [], []
    left = [(label, [item(e) for e in entries]) for label, entries in spec.get("left", [])]
    right = [(label, [item(e) for e in entries]) for label, entries in spec.get("right", [])]
    place = [{"id": nid, "x": 0, "y": 0}]
    place += stack([(label, [i for i, _r, _l in entries]) for label, entries in left], -CW, 0)
    place += stack([(label, [i for i, _r, _l in entries]) for label, entries in right], CW, 0)
    for side in (left, right):
        for label, entries in side:
            groups.append((label, [i for i, _r, _l in entries]))
            for other, how, _text in entries:      # no edge labels here: a 44 px column gap has no room
                if how in ("reads", "by"):
                    edges.append((other, nid, "feeds" if how == "reads" else "calls", None, "h"))
                elif how in ("loads", "runs", "names", "writes"):
                    edges.append((nid, other, "feeds" if how == "writes" else "calls", None, "h"))
                else:
                    problems.append(f"view {nid}: unknown relation {how}")
    if spec.get("far"):
        label, links = spec["far"]
        ys = {p["id"]: p["y"] for p in place}
        mids = {p["id"] for p in place if p["x"] == CW}
        children = []
        for parent, child, how in links:
            inner, outer = (parent, child) if parent in mids else (child, parent)
            if inner not in mids:
                problems.append(f"view {nid}: far edge {parent} -> {child} does not start in the right column")
                continue
            if outer not in children:
                children.append(outer)
            if how == "reads":
                edges.append((outer, inner, "feeds", None, "h"))
            else:
                edges.append((inner, outer, "feeds" if how == "writes" else "calls", None, "h"))
        # order the far column by the mean height of each node's parents, so edges do not cross
        def mean_parent(child):
            parents = [ys[a if b == child else b] for a, b, *_ in edges if child in (a, b) and
                       (a in mids or b in mids) and (a if b == child else b) in mids]
            return sum(parents) / len(parents)
        first = {c: i for i, c in enumerate(children)}
        children.sort(key=lambda c: (mean_parent(c), first[c]))
        middle = sum(mean_parent(c) for c in children) / len(children)
        place += stack([(label, children)], 2 * CW, middle)
        groups.append((label, children))
    shift = -min(p["x"] for p in place)          # the leftmost column starts at x = 0
    top = -min(p["y"] for p in place)
    for p in place:
        p["x"] += shift
        p["y"] += top
    title = f"{'Command' if center['kind'] == 'command' else 'Skill'}: {center['name']}"
    about = f"{center['sub']}. {AUTO_ABOUT[center['kind']]}"
    return view_record(nid, title, about, place, edges, groups, nodes, problems)


def render():
    data = build()
    body = json.dumps(data, indent=1, sort_keys=True, ensure_ascii=True)
    return ("// Generated by scripts/site_map.py from the repository. Do not edit by hand:\n"
            "// run `python3 scripts/site_map.py --write` after a change to the adapters or concord.py --help.\n"
            f"window.CONCORD_MAP = {body};\n")


def main():
    parser = argparse.ArgumentParser(description="Build or check site/map/data.js, the data of the Concord map.")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="write site/map/data.js")
    mode.add_argument("--check", action="store_true", help="exit 1 when data.js is stale or the map is incomplete")
    args = parser.parse_args()
    try:
        text = render()
    except MapError as exc:
        for line in str(exc).splitlines():
            print(f"site_map: {line}", file=sys.stderr)
        return 1
    if args.write:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(text)
        print(f"site_map: wrote {rel(OUT)}")
        return 0
    current = OUT.read_text() if OUT.is_file() else None
    if current != text:
        print(f"site_map: {rel(OUT)} {'is missing' if current is None else 'differs from a fresh build'}: "
              "run python3 scripts/site_map.py --write", file=sys.stderr)
        return 1
    print(f"site_map: {rel(OUT)} is current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
