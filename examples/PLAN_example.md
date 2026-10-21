# Plan: fix the shop cart total

One governed phase on a throwaway shop repository; `scripts/demo.sh` runs it with a scripted executor.

## Executors (review before approving)
| Phase | Executor | Risk | Runs as | Billed to | Review | Why this executor |
|---|---|---|---|---|---|---|
| 1 | planner | - | this session | none | none | writes the failing test before the fix |
| 2 | deepseek-flash | low | OpenCode (qwen in the demo) | none in the demo | flash | one-file fix with a test that already fails |

## Phase 1 - Failing test for the cart total
Executor: planner
Purpose: pin the intended total before anyone fixes the cart.
Files: tests/check_cart.py
Baseline: skip
Steps:
1. Add a test that fails while `cart.total` ignores `qty`.
Acceptance:
- `python3 tests/check_cart.py` (fails now, passes after Phase 2)

## Phase 2 - Count quantities in the cart total
Executor: deepseek-flash
Risk: low
Purpose: make `cart.total` multiply each price by its quantity.
Files: cart.py
Context: tests/check_cart.py
Inputs:
- items: list of dicts with `price` and `qty`, both non-negative integers; total = sum of price * qty
Steps:
1. Multiply each item's price by its qty inside `total`.
Example: `[{"price": 3, "qty": 2}, {"price": 5, "qty": 1}]` -> `11`
Edge cases: an empty list -> `0`
Decisions: none
Acceptance:
- `python3 tests/check_cart.py`
Out of scope: any file other than `cart.py`; do not edit the test.

## Handoff (updated after every phase; the next session reads it first)
- Changed: cart.py - price * qty in total.
- Checks ran: python3 tests/check_cart.py - fails before the fix, passes after.
- Checks NOT run: none.
- Risks and open points: none.
- Next reads: tests/check_cart.py.
