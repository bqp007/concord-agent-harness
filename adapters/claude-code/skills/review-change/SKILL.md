---
name: concord:review-change
description: Review a change - a diff, a branch, a pull request or a Concord run - against its intent and the callers it affects, and return concrete findings with locations, reproductions and consequences. Use it whenever someone asks to review a diff, branch, PR or work in progress, with or without a Concord ticket; inside /concord:run it reviews through the dispatcher's packets and tiers, which record the evidence.
argument-hint: <diff, branch, PR or run>
---

# Review a change

A review answers the three closed questions of `~/.claude/concord/REVIEW.md` about a finished change, and nothing else: whether it meets its intent, whether a concrete input breaks a promised behavior (its callers included), and whether each test it touches can fail. Read REVIEW.md first: it also holds the reproduction rule, the severities and the answer format.

## An ordinary change

The reviewer did not write the change: when this session wrote or shaped it, spawn a fresh `concord:reviewer-opus55` agent; review it here only when this session had no part in it. Pin what is under review (a commit range, a branch against its merge base, a pull request, or the working tree against HEAD) and check that the diff is not empty. Its intent comes from the pull request or issue, the commit messages, a spec the user names, or the user's words; with none, judge the change against the promises of the existing code and say so. A reviewer agent gets a brief file in `$TMPDIR`: the diff command, the intent and the path of REVIEW.md. Nothing is recorded and no `.git/concord` state is written.

## Inside the Concord workflow

The dispatcher reviews a run's graded candidate or a pull request's current head and records each answer against it; the tier picks the reviewer. Read [gate.md](gate.md) before a ticket's full revision: tiers, reviewers, the review loop, delta reviews and the PR gate.

## Result

The findings, most severe first: severity, path:line, the problem, the reproduction and its consequence, the fix. Then the clauses that fail or stay unclear, and the tests that cannot fail or that reject an allowed change. CLEAN when there is none. Inside the workflow, also the recorded verdict and what the change still needs.
