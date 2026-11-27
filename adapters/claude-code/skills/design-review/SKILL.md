---
name: concord:design-review
description: Find the callers a proposed change affects, the behavior each one relies on, and the consequential choices that are the owner's to make. Use it when you write, grill or challenge a plan, when you decide whether a task can take the direct-edit path, when implementation exposes a choice the plan did not settle, and whenever someone asks for a design review of a proposal or change, even when the change is one line or looks routine.
argument-hint: <proposal, plan or change>
---

# Design review

A design is ready when an implementer can deliver it without silently deciding something the owner would care about. The owner settles consequential choices. The implementer chooses the means within that agreement.

A choice matters when plausible answers make different promises to a caller or commit the project to different responsibilities. A one-line permission change can decide who may publish a release. A rename across thirty files can leave every caller's contract intact. Diff size settles neither question. Such choices often sit in small edits to who may approve or release, what is trusted, what is deleted or kept, money, and security.

Choices also hide in how a change acts on approvals and measured state. Ask what was approved and what identifies that approval, what state supports each decision and whether it can change before the code acts, and what a receiving program such as a shell, git or a parser will read into a value and whether that reading is intended and validated. Which approval and which evidence a gate accepts are promises to its callers, so the owner settles them. Passing a value so that its receiver reads it as intended is execution.

Find the callers before you judge: the code, file formats, commands and people that use what the change touches, and what each of them relies on. Where a language server is set up for the repository, take a symbol's callers and the tests that use it from the server: a text search misses aliased imports and overloads, and finds the name in strings and comments. Judge the proposal against the governing requirement and the code that must honor it. If the owner already settled the choice, identify any mismatch and its consequence. If the choice is still open, name the smallest decision the owner can make and what changes for whom under each plausible answer. A sound recommendation can accompany the question.

Leave room for implementation judgment once the contract and its architectural constraints are clear. How the work is split, ordered and delegated is execution, not an owner choice. Discovering an existing caller that would lose a promised behavior reopens the affected choice. Finding a simpler implementation that preserves the agreement is ordinary execution.

## Result

- Affected callers: each one, the behavior it relies on, and whether the change keeps it.
- Owner decisions: each open consequential choice as its smallest decision, what changes for whom under each answer, and your recommendation; each settled choice the proposal breaks, with the consequence. "No owner decision needed" is a valid result.
- Execution: what the implementer may decide alone.
