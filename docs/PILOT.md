# Pilot: the full loop against a lighter path

*Does the full Concord loop pay for itself on real work? The pilot answers it with the owner's time, rework, model spend and defects, measured on comparable tickets.*

## Setup

- **Tickets.** About ten real tickets, taken in pairs that match in repository, `Size:` and `Risk:` tier.
- **Arms.** In each pair, one ticket runs the full loop and the other runs the lighter path. Alternate which arm takes the first ticket of a pair.
- **Same bar for both arms.** Before merge, the acceptance commands of every phase pass on the final tree, and `concord.py --pr-status` prints REVIEWED.

| Arm | What runs |
|---|---|
| Full loop | Plan, verifier, estimate, phases on executors, a review of each implementing phase, the PR gate |
| Lighter path | One plan you approve, the planner writes the code directly, the PR gate |

## Measures

Record one row per ticket in [pilot.csv](pilot.csv).

| Column | Meaning |
|---|---|
| `engineer_minutes` | Your own minutes on the ticket until the PR is accepted: reading, answering, reviewing. Wall time does not count. |
| `review_rounds` | Full review rounds after the first one. |
| `fail_verdicts` | FAIL verdicts recorded for the ticket's runs. |
| `model_spend_usd` | Every model call of the ticket priced at its list price (tokens times the published rate), subscription calls included. |
| `defects_30d` | Defects traced to the ticket within 30 days of its merge. |

## Reading the result

With about five pairs, report the difference within each pair and the median difference per measure, not a significance test. The full loop earns its place where it saves engineer minutes or defects at a model spend you accept. Where it does not, use the lighter path for that kind of ticket.
