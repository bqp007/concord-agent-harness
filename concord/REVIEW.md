# Review checklists for `concord.py --review` (read-only pass by a cheap model after acceptance passes)

Distilled 2026-10-15 from ECC 2.2.3 reviewer agents (python/cpp/kotlin/swift/security reviewers,
silent-failure-hunter, mle-reviewer, pr-test-analyzer). Sections are chosen by the changed files'
types; `--checklist a,b` overrides. Keep each section short: the reviewer reads the diff, not the repo.
The dispatcher post-filters findings before the verifier sees them: a BLOCKER/HIGH/MEDIUM outside the diff hunks (±3
lines), whose fix is a TODO, or whose fix only deletes code becomes `[NOTE] ... (auto: <reason>, was <SEV>)`.
Since 2026-10-19 every reviewer answers with one REVIEW-JSON block (REVIEW_TASK in concord.py): a BLOCKER/HIGH/MEDIUM
needs a reproduction from a real input source or it becomes a NOTE, the dispatcher computes the verdict and renders the
report, and the ticket's (or PR's) review ledger (finding ids, adjudications, decisions, assumptions) is binding for
every later reviewer. After a fix commit a PR gets a delta review (`--review-pr N --delta`): the fix diff with the
touched functions as context, plus the ledger. The nearest reviewed ancestor head is the base,
never skipped; when it has open findings the fix must touch their files. A file rewritten past half of
its lines, merged reviewed lineages, a rebuilt branch or a broken chain needs a full review.

## any
Grouped by the four expectations of the CHI '26 agent-behaviour taxonomy (2026-10-18). Before any finding, read the
code around it: name the caller, input or line that makes it real. A finding you cannot anchor that way is NOTE.
The same defect in several places is ONE finding, anchored at its first instance in the diff: name the defect class and list every instance (path:line) in its problem text.

Solve the problem (context, validation):
- Behaviour that contradicts the phase, the plan's Example or Edge cases, or a caller visible in the diff.
- Off-by-one, wrong boundary (<= vs <), wrong sort stability or tie-break, mutable default argument.
- A changed path no acceptance command exercises (the executor did not validate it).

Code quality and reliability:
- Silent failure: empty catch, error turned into None/[]/default, log-and-continue on a path that must stop.
- Swallowed cancellation or exception that hides a failing call from the caller.
- Fallback value that masks a real failure downstream (a default where an error belongs).
- Missing timeout or error handling around network, file, subprocess or database calls.
- Resource not released (file, socket, lock, temp dir) on the error path.
- Over-hardening: a validation or hardening finding must name the untrusted input that reaches the code; extra checks
  on trusted internal callers or already-validated data are NOTE at most, never BLOCKER or HIGH.

Standards and process (scope, conventions):
- Behaviour outside the phase: refactors, renames, reformatting, new dependencies the plan did not ask for.
- New code that ignores the surrounding file's conventions (naming, error style, helpers it already has).

Collaboration (what the reader is told):
- Comment or docstring that now contradicts the code.
- A message, log line or report field that misstates what the code did.
## python
- Bare `except:` or `except Exception: pass`; catch the specific exception, re-raise or report.
- `type(x) == T` instead of `isinstance`; `== None` instead of `is None`.
- Shell commands built from strings with external input; use `subprocess` list args.
- Paths built from input without `normpath` and a `..` check; `yaml.load` without SafeLoader; `eval`/`exec`/`pickle` on untrusted data.
- Shared state across threads without a lock; blocking calls inside async code.
- Byte/str confusion, encoding assumptions, `str.isdigit()` where ASCII digits were meant.
- Functions over ~50 lines or 5 parameters added by this change; duplicated logic that already exists in the repo.

## cpp
- Raw `new`/`delete`, manual resource management without RAII; missing Rule of Five after adding an owning member.
- Buffer overflow risk: C arrays, `strcpy`/`sprintf`, unchecked index, iterator invalidated by insert/erase.
- Use-after-free, dangling reference/pointer, uninitialized member or local read before assignment.
- Integer overflow or signed/unsigned mix on sizes from input; `reinterpret_cast` without justification.
- Data race: shared mutable state without a mutex; manual lock/unlock instead of `std::lock_guard`; inconsistent lock order.
- Large objects passed by value; missing `std::move` for sink parameters; `using namespace std;` in a header.
- `const` correctness on new methods and parameters; include guards; `using namespace` leaks.

## kotlin
- `GlobalScope`; coroutine launched outside a structured scope; `CancellationException` caught and swallowed.
- Blocking IO on `Dispatchers.Main`; Flow collected in `init {}`; mutable collection inside `StateFlow`.
- Domain module importing Android/framework types; entities or DTOs leaking to the UI layer.
- `!!` on nullable values; `var` where `val` works; `when` on a sealed type without exhaustive branches.
- Compose: side effects outside `LaunchedEffect`; unstable lambda or object created per recomposition; `LazyColumn` items without keys.
- Context/Activity reference stored in a singleton or ViewModel; secrets or PII written to logs.

## swift
- Force unwrap `!`, `try!`, `as!` on production paths; `fatalError`/`precondition` where a thrown error belongs.
- Empty `catch {}` or `try?` discarding a meaningful error.
- Data race: shared mutable state without actor isolation; `@MainActor` missing for UI updates; blocking the main actor.
- Strong `self` captured in a long-lived closure; delegate not `weak`; unstructured `Task {}` without cancellation.
- Secrets in `UserDefaults` or source; ATS exceptions; string interpolation into queries or shell commands.
- `default:` hiding new cases of an evolving enum; `var` where `let` works.

## security
- Hardcoded secret, token, key or password; credentials or PII in logs.
- Command, SQL or path injection from any external input (user text, message text, URL, file name, env).
- Untrusted data deserialized or parsed without size and shape limits; regex on untrusted input with catastrophic backtracking shape.
- Fetch or redirect to an attacker-controlled host; TLS or certificate checks disabled.
- Weak or home-made crypto; randomness from a non-cryptographic source where security matters.
- Verify context before flagging: test fixtures, checksums (not passwords), example configs are usually fine.

## ml
- Leakage: random split on time- or user-dependent data; features that use post-outcome fields; eval rows that overlap training.
- Metrics or thresholds changed without a baseline comparison on the same slice; a tuned threshold hard-coded as a constant.
- Training not reproducible from code + config + data version + seed; artifact overwritten without a version.
- Train/serve skew: preprocessing copied by hand into the serving path instead of shared or equivalence-tested.
- Model or artifact version absent from outputs or logs; prediction path without timeout or fallback.
- Secrets, PII or raw corpus rows written into datasets, notebooks, logs or test fixtures.

## tests
- Each changed behaviour has a test that fails without the change (not only a "does not throw" check).
- Edge and error paths covered: empty, boundary, malformed, oversized, concurrent where relevant.
- Assertions are specific (values, not just truthiness); no snapshot of the implementation's own output as the golden.
- Tests pin behaviour, not structure: no asserts on call order, private names or formatting.
- No dependence on time, network, ordering or shared state (flakiness); fast enough to run on every attempt.
- Rate gaps: critical (behaviour untested), important (edge path), nice-to-have.
