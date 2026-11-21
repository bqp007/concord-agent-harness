---
name: concord-design-review
description: Decide which choices in a proposed change are the owner's and which are ordinary execution. Use it when you write, grill or challenge a plan, when you decide whether a task can take the direct-edit path, and when implementation exposes a choice the plan did not settle, even when the change is one line or looks routine.
---

# Design review

A design is ready when an implementer can deliver it without silently deciding something the owner would care about. The owner settles consequential choices. The implementer chooses the means within that agreement.

A choice matters when plausible answers make different promises to a caller or commit the project to different responsibilities. A one-line permission change can decide who may publish a release. A rename across thirty files can leave every caller's contract intact. Diff size settles neither question. Such choices often sit in small edits to who may approve or release, what is trusted, what is deleted or kept, money, and security.

Judge the proposal against the governing requirement and the code that must honor it. If the owner already settled the choice, identify any mismatch and its consequence. If the choice is still open, name the smallest decision the owner can make and what changes for whom under each plausible answer. A sound recommendation can accompany the question.

Leave room for implementation judgment once the contract and its architectural constraints are clear. How the work is split, ordered and delegated is execution, not an owner choice. Discovering an existing caller that would lose a promised behavior reopens the affected choice. Finding a simpler implementation that preserves the agreement is ordinary execution.
