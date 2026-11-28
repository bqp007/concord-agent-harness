# Pilot: the full loop against a lighter path

*Does the full Concord loop pay for itself on real work? The pilot answers it with the owner's time, rework, model spend and defects, measured on comparable tickets.*

## Setup

- **Tickets.** About ten real tickets, taken in pairs that match in repository, `Size:` and `Risk:` tier.
- **Arms.** In each pair, one ticket runs the full loop and the other runs the lighter path. Alternate which arm takes the first ticket of a pair.
- **Same bar for both arms.** Before merge, the acceptance commands of every phase pass on the final tree, and both pull requests of a pair are reviewed to the same final standard: the same pull-request tier, the higher of the tiers `concord.py --pr-status` requires for the two, until `--pr-status` prints REVIEWED for each.

| Arm | What runs |
|---|---|
| Full loop | Plan, verifier, estimate, phases on executors, a review of each implementing phase, the PR gate |
| Lighter path | One plan you approve, the planner writes the code directly, the PR gate |

## Measures

Record one row per ticket in [pilot.csv](pilot.csv).

| Column | Meaning |
|---|---|
| `engineer_minutes` | Your own minutes on the ticket until the PR is accepted: reading, answering, reviewing. Wall time does not count. |
| `review_rounds` | Full review rounds at the pull-request gate after the first one. Both arms record them the same way, at the same tier, so this is the rework measure to compare across arms. |
| `fail_verdicts` | FAIL verdicts recorded for the ticket's runs. The arms record different numbers of runs, so this column describes rework within an arm and is not compared across arms. |
| `model_spend_usd` | Every model call of the ticket priced at its list price (tokens times the published rate), subscription calls included. |
| `defects_30d` | Defects traced to the ticket within 30 days of its merge. |

## Reading the result

With about five pairs, report the difference within each pair and the median difference per measure except `fail_verdicts`, not a significance test. The full loop earns its place where it saves engineer minutes or defects at a model spend you accept. Where it does not, use the lighter path for that kind of ticket.
