#!/usr/bin/env bash
#
# Unit tests for the PURE helpers in lib.sh: the assertion framework
# (check_eq/check_contains/check_absent) and the section() text extractor. These
# make NO GitHub calls, so they run anywhere in well under a second and are the
# fast safety net for the parts of the harness that carry real logic.
#
# The I/O helpers (wait_label, open_pr_on, approve_proposal, ...) are thin gh
# wrappers extracted verbatim from the scratch/e2e-*.sh scripts; their safety net
# is the scenario runs themselves, not this file.
#
# Run:  bash programs/lfx-mentorship/automation/test/e2e/lib.test.sh
set -uo pipefail
cd "$(dirname "$0")"

# Sourcing lib.sh must have NO side effects (no cd, no trap, no preflight, no gh).
source ./lib.sh

t_pass=0
t_fail=0
ok(){ t_pass=$((t_pass + 1)); }
no(){ t_fail=$((t_fail + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# Run a check_* helper in isolation and assert how it moved the FAILED counter:
# exp=0 means the check should PASS (leaves FAILED at 0), exp=1 means it should
# FAIL (sets FAILED to 1). Output is suppressed; we assert on the counter only.
expect_check(){
  local desc=$1 exp=$2; shift 2
  FAILED=0
  "$@" >/dev/null 2>&1
  if [ "$FAILED" -eq "$exp" ]; then ok; else no "$desc (FAILED=$FAILED, want $exp)"; fi
}

expect_eq(){ # desc, expected, actual
  if [ "$2" = "$3" ]; then ok; else no "$1 (got '$3', want '$2')"; fi
}

echo "== check_eq =="
expect_check "check_eq: equal strings pass"            0 check_eq "l" "abc" "abc"
expect_check "check_eq: unequal strings fail"          1 check_eq "l" "abc" "xyz"
expect_check "check_eq: empty equals empty passes"     0 check_eq "l" "" ""
expect_check "check_eq: empty vs non-empty fails"      1 check_eq "l" "" "x"

echo "== check_contains =="
expect_check "check_contains: needle present passes"   0 check_contains "l" "hello world" "world"
expect_check "check_contains: needle absent fails"     1 check_contains "l" "hello" "world"
expect_check "check_contains: substring at start"      0 check_contains "l" "abcdef" "abc"
expect_check "check_contains: needle with #number"     0 check_contains "l" "lists #197 here" "#197"
expect_check "check_contains: empty haystack fails"    1 check_contains "l" "" "x"

echo "== check_absent =="
expect_check "check_absent: needle absent passes"      0 check_absent "l" "hello" "world"
expect_check "check_absent: needle present fails"      1 check_absent "l" "hello world" "world"
expect_check "check_absent: absent #number passes"     0 check_absent "l" "Newly added #195" "#193"

echo "== section =="
BODY=$'intro\nNewly added:\n- #10\n- #11\nExport files:\ntail'
expect_eq "section: extracts lines between markers" $'- #10\n- #11' "$(section "$BODY" "Newly added:" "Export files:")"
expect_eq "section: empty when start marker absent"  "" "$(section "$BODY" "Nope:" "Export files:")"
UPD=$'Updated:\n- #193\nExport files:\nx'
expect_eq "section: single-line body"                "- #193" "$(section "$UPD" "Updated:" "Export files:")"

echo
if [ "$t_fail" -eq 0 ]; then
  printf '\033[32mlib.test.sh: %d passed\033[0m\n' "$t_pass"
else
  printf '\033[31mlib.test.sh: %d passed, %d FAILED\033[0m\n' "$t_pass" "$t_fail"
  exit 1
fi
