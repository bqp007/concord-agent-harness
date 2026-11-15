# Review checklists

`concord.py --review` and `--review-pr` send each reviewer the sections that fit the changed files: `any` and `security`
always, the languages seen, `ml` for model, eval or data paths, `tests` when only tests changed (`--checklist a,b`
overrides). Reviewers answer one REVIEW-JSON block, severities BLOCKER, HIGH, MEDIUM or NOTE. The first three need a
reproduction from a real input source and a line inside the diff, or the dispatcher makes them a NOTE. Findings get
ledger ids (F1, F2, ...) that bind later reviewers of the ticket or PR. The session fixes BLOCKER and HIGH, and a MEDIUM
only when its reproduction comes from a real flow; the other findings go to the test report for the owner's DAT.

## any
Anchor every finding: name the caller, input or line that makes it real, else it is a NOTE. One defect in several places
is ONE finding at its first instance in the diff, listing every instance (path:line).
- Behaviour that contradicts the phase, its tests or a caller visible in the diff.
- Off-by-one, wrong boundary (<= vs <), unstable sort or tie-break, mutable default argument.
- A changed path no acceptance command exercises.
- Silent failure: empty catch, an error turned into None, [] or a default, log-and-continue where the path must stop,
  a swallowed exception or cancellation.
- Missing timeout or error handling around network, file, subprocess or database calls; a file, socket, lock or temp
  dir not released on the error path.
- Over-hardening: a validation finding must name the untrusted input that reaches the code; extra checks on trusted
  callers or validated data are NOTE at most.
- Changes the phase did not ask for (refactors, renames, reformatting, dependencies) or that ignore the file's conventions.
- A comment, docstring, message, log line or report field that misstates what the code does.

## python
- Bare `except:` or `except Exception: pass`; catch the specific exception, re-raise or report.
- Shell commands built from strings with external input (use list args); input paths without `normpath` and a `..`
  check; `yaml.load` without SafeLoader; `eval`, `exec` or `pickle` on untrusted data.
- Shared state across threads without a lock; blocking calls in async code.
- Byte/str confusion, encoding assumptions, `str.isdigit()` where ASCII digits were meant.

## cpp
- Raw `new`/`delete` or manual resource management without RAII; no Rule of Five after adding an owning member.
- Buffer overflow: C arrays, `strcpy`/`sprintf`, unchecked index, iterator invalidated by insert or erase.
- Use-after-free, dangling reference or pointer, a read before initialization.
- Integer overflow or signed/unsigned mix on sizes from input; unjustified `reinterpret_cast`.
- Data race: shared mutable state without a mutex, manual lock/unlock instead of `std::lock_guard`, inconsistent lock order.

## kotlin
- `GlobalScope` or a coroutine outside a structured scope; `CancellationException` swallowed.
- Blocking IO on `Dispatchers.Main`; Flow collected in `init {}`; a mutable collection inside `StateFlow`.
- Domain code importing Android or framework types; entities or DTOs leaking to the UI layer.
- `!!` on nullable values; a non-exhaustive `when` on a sealed type.
- Compose: side effects outside `LaunchedEffect`; unstable lambdas or objects created per recomposition; `LazyColumn`
  items without keys.
- A Context or Activity held by a singleton or ViewModel.

## swift
- `!`, `try!` or `as!` on production paths; `fatalError` or `precondition` where a thrown error belongs.
- Empty `catch {}` or `try?` discarding a meaningful error.
- Data race: shared mutable state without actor isolation; UI updates off `@MainActor`; blocking the main actor.
- Strong `self` in a long-lived closure; a delegate that is not `weak`; an unstructured `Task {}` without cancellation.
- Secrets in `UserDefaults`; ATS exceptions.
- `default:` hiding new cases of an evolving enum.

## security
- Hardcoded secret, token, key or password; credentials or PII in logs.
- Command, SQL or path injection from any external input (user or message text, URL, file name, environment).
- Untrusted data parsed without size and shape limits; a regex on untrusted input that can backtrack catastrophically.
- Fetch or redirect to an attacker-controlled host; TLS or certificate checks disabled.
- Weak or home-made crypto; non-cryptographic randomness where security matters.
- Check the context first: test fixtures, checksums (not passwords) and example configs are usually fine.

## ml
- Leakage: a random split on time- or user-dependent data, post-outcome features, eval rows that overlap training.
- Metrics or thresholds changed without a baseline on the same slice; a tuned threshold hard-coded.
- Training not reproducible from code, config, data version and seed; an artifact overwritten without a version.
- Train/serve skew: preprocessing copied by hand into serving instead of shared or equivalence-tested.
- No model or artifact version in outputs or logs; a prediction path without timeout or fallback.
- Secrets, PII or raw corpus rows in datasets, notebooks, logs or fixtures.

## tests
- Each changed behaviour has a test that fails without the change, not only a "does not throw" check.
- Edge and error paths: empty, boundary, malformed, oversized, concurrent where relevant.
- Specific assertions (values, not truthiness); no golden copied from the implementation's output.
- Behaviour, not structure: no asserts on call order, private names or formatting.
- No dependence on time, network, ordering or shared state; fast enough for every attempt.
- Test bloat: a new test or case where an existing one covers the behavior (extend or merge it instead), setup or
  asserts duplicated across the tests the change touched, or more than one new test for one finding.
