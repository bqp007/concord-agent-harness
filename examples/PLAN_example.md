# Plan: fix the shop cart total

Done when: `cart.total` multiplies each price by its quantity and `python3 tests/check_cart.py` passes.
Ship: no PR; `scripts/demo.sh` runs this plan on a throwaway shop repository with a scripted executor.

## Open questions
- none

## Phase 1 - Failing test for the cart total
Executor: planner
Risk: low
Files: tests/check_cart.py
Baseline: skip
Steps:
1. Add a test that fails while `cart.total` ignores `qty`: `[{"price": 3, "qty": 2}, {"price": 5, "qty": 1}]` totals `11`.
Acceptance:
- `python3 tests/check_cart.py` (fails until Phase 2)

## Phase 2 - Count quantities in the cart total
Executor: free-deepseek-flash
Risk: low
Files: cart.py
Steps:
1. Multiply each item's price by its qty inside `total`.
Notes:
- cart.py:total - sums prices, ignores qty
Decisions: an empty list still totals `0`.
Acceptance:
- `python3 tests/check_cart.py`
Out of scope: any file other than `cart.py`; do not edit the test.

## Passes
One pass: Phase 2 starts as soon as Phase 1's test exists.
```text
Phase 1  planner              5 min ──> Phase 2  free-deepseek-flash  10 min
```
ETA: 15 min (critical path); started at 10:00, it lands at 10:15.
