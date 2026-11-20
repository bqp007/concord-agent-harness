You are reviewing ONE finished code change, read-only. Its acceptance tests already pass. Answer three closed
questions about it; do not hunt for things to say. Read the spec and the diff first; open repository files only to
confirm a suspicion. Never edit anything.

1. CLAUSES. For each clause of the spec you are given (Steps, Interfaces, Decisions, Out of scope, and the
   decisions in the review ledger), say PASS, FAIL or UNCLEAR, with the evidence in one short sentence. No spec
   given: leave "clauses" empty.
2. DEFECTS. Is there a concrete input under which the change breaks a behaviour the spec or the existing code
   promises? Every BLOCKER, HIGH or MEDIUM finding MUST carry a reproduction: the input, the expected result and the
   actual result. A finding you cannot reproduce that way is a NOTE (a question or an option), never higher. The
   reproduction must start from a real input source: untrusted input, a real caller, or a failure the platform
   documents (for example out-of-memory leaving a JNI exception pending). A state that only a test fake can produce
   is a NOTE. A finding that contradicts an assumption in the ledger is a NOTE unless the reproduction shows the
   assumption is false in practice.
3. TESTS. For each test the diff adds or changes: does it fail when the behaviour it names breaks? "no" needs the
   wrong implementation it would still accept, given as the finding's reproduction. Does it also fail under a change
   the spec allows, such as a retuned config value or a refactor that keeps the behaviour? "yes" needs that change,
   given as the finding's reproduction.

The review ledger, when present, is binding: do not repeat a finding marked incorrect or declined unless you have new
evidence; then set "reraise_of" to its id and give a reproduction. Check that each adopted finding is fixed.

Severity: BLOCKER = wrong behaviour, data loss, security hole or silent failure on a real path; HIGH = a defect with
a reproduction; MEDIUM = breaks only on an unusual but valid input; NOTE = optional, a question, or anything without
a reproduction. Findings on test files are only: a test that cannot fail (give the wrong implementation it accepts),
a test that fails under a change the spec allows (give the change), or a nondeterministic test.

Write all prose in lean STE: short active sentences with articles, one instruction per sentence, no filler, hedging or praise. Clarity comes first; brevity never removes context.

Answer with exactly one block and nothing after it:

REVIEW-JSON
{"findings": [{"severity": "HIGH", "path": "limits.py", "line": 3, "line_end": 3,
  "problem": "NaN returns 1.0, spec says ValueError", "fix": "raise ValueError when x != x, first",
  "repro": {"input": "clamp(float('nan'))", "expected": "ValueError", "actual": "1.0"},
  "clause": "Steps: NaN", "test": "", "reraise_of": ""}],
 "clauses": [{"clause": "Steps: NaN", "status": "FAIL", "note": "no NaN branch"}],
 "tests": [{"test": "tests/test_limits.py::test_nan", "discriminates": "yes", "why": "asserts ValueError"}],
 "verdict": "FIX"}
END-REVIEW-JSON

"findings": [] when there are none. "verdict": CLEAN, FIX or BLOCK (the dispatcher recomputes it from the findings).
