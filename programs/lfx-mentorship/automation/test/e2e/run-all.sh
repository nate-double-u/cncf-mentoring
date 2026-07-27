#!/usr/bin/env bash
#
# LFX Mentorship intake e2e suite runner. Runs each scenario in test/e2e/scenarios/
# SERIALLY (they hit real GitHub, Actions, and the shared DEMO board, so they
# must never run in parallel), then prints a PASS/FAIL summary. Exits non-zero if
# any scenario failed.
#
# Each scenario is a standalone script that self-cleans via its own EXIT trap and
# exits 0 (pass) or non-zero (fail); this runner only invokes them and collects
# results, so it stays decoupled from scenario internals.
#
# This is a manually-run PRE-PROMOTION gate on the DEV fork, not CI: a full run
# hits live services and can take 30-60 min. Run it against dev main after
# merging a change and before promoting to prod.
#
# Usage:
#   bash programs/lfx-mentorship/automation/test/e2e/run-all.sh [options]
#     --only <name>   run just scenarios/<name>.sh (repeatable)
#     --keep          keep artifacts (E2E_KEEP=1) for debugging
#     --reset         preflight force-clears each scenario's OWN leftovers
#     --list          list available scenarios and exit
#     -h, --help      this help
#
# Env: E2E_RETRIES (poll attempts x5s, default 90) is passed through.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCEN_DIR="$HERE/scenarios"

usage(){ sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

ONLY_LIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY_LIST="$ONLY_LIST $2"; shift 2;;
    --only=*) ONLY_LIST="$ONLY_LIST ${1#*=}"; shift;;
    --keep) export E2E_KEEP=1; shift;;
    --reset) export E2E_RESET=1; shift;;
    --list) for f in "$SCEN_DIR"/*.sh; do [ -e "$f" ] && basename "$f" .sh; done; exit 0;;
    -h|--help) usage; exit 0;;
    *) echo "unknown argument: $1" >&2; usage; exit 2;;
  esac
done

# Build the scenario list: explicit --only names, else every scenarios/*.sh.
scenarios=""
if [ -n "$ONLY_LIST" ]; then
  for name in $ONLY_LIST; do
    f="$SCEN_DIR/$name.sh"
    [ -f "$f" ] || { echo "no such scenario: $name (try --list)" >&2; exit 2; }
    scenarios="$scenarios $f"
  done
else
  for f in "$SCEN_DIR"/*.sh; do [ -e "$f" ] && scenarios="$scenarios $f"; done
fi
[ -n "$scenarios" ] || { echo "no scenarios found in $SCEN_DIR" >&2; exit 2; }

names=""
results=""
overall=0
for f in $scenarios; do
  name=$(basename "$f" .sh)
  printf '\n\033[1m######## SCENARIO: %s ########\033[0m\n' "$name"
  if bash "$f"; then r="PASS"; else r="FAIL"; overall=1; fi
  names="$names $name"
  results="$results $r"
done

printf '\n\033[1m================ SUITE SUMMARY ================\033[0m\n'
# shellcheck disable=SC2086
set -- $names
for r in $results; do
  color=32; [ "$r" = FAIL ] && color=31
  printf '  \033[%sm%-4s\033[0m %s\n' "$color" "$r" "$1"
  shift
done
if [ "$overall" -eq 0 ]; then printf '\033[32mSUITE PASSED\033[0m\n'; else printf '\033[31mSUITE FAILED\033[0m\n'; fi
exit "$overall"
