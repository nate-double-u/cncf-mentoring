# LFX Mentorship intake e2e suite

End-to-end regression tests for the LFX Mentorship intake automation. This is a
**manually-run, pre-promotion gate on the dev fork** (`nate-double-u/mentoring`),
not CI: each scenario drives real GitHub issues, Actions, and the DEMO project
board, so a full run hits live services and can take 30-60 minutes.

## Convention

- **Every new automation feature ships with an e2e scenario here.**
- **Run the suite on any non-trivial change**, time permitting, before promoting
  dev to prod.

## Running

```bash
# whole suite
bash programs/lfx-mentorship/automation/test/e2e/run-all.sh

# one scenario
bash programs/lfx-mentorship/automation/test/e2e/run-all.sh --only multi-command

# list scenarios
bash programs/lfx-mentorship/automation/test/e2e/run-all.sh --list
```

Flags: `--only <name>` (repeatable), `--keep` (leave artifacts for debugging),
`--reset` (preflight clears this scenario's own leftovers), `--list`.
Env: `E2E_RETRIES` (poll attempts x5s, default 90).

The pure helpers have fast unit tests that make no GitHub calls:

```bash
bash programs/lfx-mentorship/automation/test/e2e/lib.test.sh
```

## Layout

| Path | Purpose |
|------|---------|
| `lib.sh` | Shared harness: assertions, gh helpers, self-clean framework. Sourced, no side effects. |
| `lib.test.sh` | Unit tests for the pure helpers (`check_*`, `section`). |
| `run-all.sh` | Serial runner; aggregates PASS/FAIL, non-zero exit on any failure. |
| `scenarios/*.sh` | One scenario per file, sourcing `lib.sh`. |
| `fixtures/*.md` | Disposable proposal bodies. |

## Writing a scenario

```bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
TITLE_TAG="cleanup e2e <unique>"          # this test's disposable title tag
PROPOSAL_BODY="$HERE/../fixtures/<x>.md"
e2e_init                                   # cd repo root, preflight, arm teardown

# ... drive the proposal, asserting with check_eq / check_contains / check_absent
P=$(gh issue create -R "$REPO" ... | grep -oE '[0-9]+$')
e2e_track_issue "$P"                        # register what THIS run creates
# e2e_track_branch "$SOME_PR_BRANCH"        # for export/url PR scenarios

e2e_summary                                 # print result, exit non-zero on fail
```

### Self-clean rules

1. **Track only what you create** (`e2e_track_issue`, `e2e_track_branch`).
2. **`e2e_init` arms an EXIT trap** that tears down exactly those artifacts on
   success, failure, or interrupt, including the board card that board-sync
   re-adds when an issue closes.
3. **Preflight asserts a clean slate** for this scenario's `TITLE_TAG` and
   declared branches, and fails loudly if dirty. It never sweeps other tests'
   leftovers; a human cleans up, or you re-run with `E2E_RESET=1`.

## Safety

Scenarios only ever target the dev fork. `e2e_init` refuses to run when `REPO`
is a `cncf/*` repository.
