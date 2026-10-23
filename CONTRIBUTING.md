# Contributing to Concord

Changes to Concord follow Concord. Every change is a small ticket with a plan, tests written before the code, an independent review and a recorded verdict, the same loop Concord enforces for any other repository.

## Before you start

- Open an issue for anything larger than a small fix, so the design can be agreed before work starts.
- Read [docs/WORKFLOW.md](docs/WORKFLOW.md) for the loop and `concord/PLAN_TEMPLATE.md` for the plan format.

## Making a change

1. Write `PLAN_<ticket>.md` from the template: phases with exact files, acceptance commands and a risk level.
2. Add or extend a suite under `concord/tests/` that fails before the change (bash, a fake HOME, no network). Tests are written before the implementation and are not edited by whoever implements it.
3. Implement the phase, by hand or through `concord.py`.
4. Get an independent review: someone or something that did not write the change.
5. Run the checks; all three must pass:

```bash
bash concord/tests/run_all.sh
bash tests/package_test.sh
bash tests/demo_test.sh
```

## Rules the checks enforce

- Line budgets (`tests/package_test.sh budgets`). A change that needs more lines raises the budget in the same pull request and says why. Rules that produced no change in a month are retired rather than kept.
- No internal names. Keep your own private patterns in `~/.config/concord/scrub.txt` (one regular expression per line) and run `bash tests/package_test.sh scrub` before you push.
- Standard-library Python 3.9+ and bash 3.2+; no new dependencies.
- Concord never commits. Maintainers review the diff and commit.
- A release raises `version` in `adapters/claude-code/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` together (the layout check requires them to agree); installed plugins keep their cached copy until the version changes.

## License

Contributions are accepted under the [MIT License](LICENSE).
