---
name: concord:lean-testing
description: Find the smallest check that catches the regression that matters for a behavior, a diff or a set of tests - the existing test to keep or extend, or the missing test and the failure it must expose; "existing coverage is sufficient" is a valid answer. Use it whenever you write a Test plan, add, change, review or consolidate tests, add a regression test for a fix, find a test that duplicates or contradicts another, decide what to do with a test a change turned red, decide whether something needs a test at all, or are about to add a guard or validation check, even when the request only says "add tests" or "make it robust".
argument-hint: <behavior, diff or tests>
---

# Lean testing

A test earns its place when it catches a failure that the rest of the suite would miss, at the point where it must be caught, and passes on every change the spec allows. Read [principles.md](principles.md) before you write a Test plan, a failing test, a test review or a consolidation pass: it holds the principles, what a finished test set shows and how to review tests.

## In a Concord plan

- The Test plan has one row per touched behavior: the behavior, its existing tests, one action and its Home test file. The action is KEEP, EXTEND, MERGE, REPLACE or DELETE, or ADD only when no test covers the behavior.
- Failing tests come first where they buy evidence: a changed behavior gets its failing tests in their own run, and the planner checks that each fails for the stated reason before any implementation starts. A routine change (a refactor under characterization checks, a mechanical migration) needs no separate red run. Implementers never edit tests.
- After the last phase, the consolidation pass goes over the tests the ticket touched. Only the planner merges or deletes tests, and it names the remaining test that catches what each removed one caught.

## Result

For each behavior or test, one line: KEEP, EXTEND or ADD with the failure the case must expose and the source of its expected value; MERGE, REPLACE or DELETE with the test that keeps the coverage; or "existing coverage is sufficient" with the test that already catches the failure. Called on its own, it writes and runs nothing unless asked, and records nothing.
