#!/usr/bin/env bash
#
# Scenario: custom-prerequisite validation (cncf/mentoring#1954). The limit logic
# is unit-tested; this proves the workflow wiring in lfx-proposal-validate.yml.
#
#   S1  over-limit custom prereq (name 59, description 606) -> Validation Failed,
#       comment flags both the name (limit 20) and description (limit 500).
#   S2  edit within limits -> Validation Passed, comment lists the custom prereq.
#   S3  edit to an UNCHECKED box but over-limit copy -> Validation Failed, comment
#       flags the unchecked box AND both length problems together.
#   S4  edit to an unchecked box with empty fields -> Validation Passed, comment
#       says nothing about a custom prerequisite.
#
# Run:  bash programs/lfx-mentorship/automation/test/e2e/scenarios/custom-prereq.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

TITLE_TAG="cleanup e2e prereq"
BODY_OVER="$HERE/../fixtures/prereq-over.md"
BODY_OK="$HERE/../fixtures/prereq-ok.md"
BODY_UNCHECKED_COPY="$HERE/../fixtures/prereq-unchecked-copy.md"
BODY_NONE="$HERE/../fixtures/prereq-none.md"

for f in "$BODY_OVER" "$BODY_OK" "$BODY_UNCHECKED_COPY" "$BODY_NONE"; do [ -f "$f" ] || die "missing body file: $f"; done
e2e_init

# ---- S1: open with an over-limit custom prereq -> Validation Failed -----------
step "S1 open proposal with over-limit custom prereq (expect Validation Failed)"
A=$(gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG (disposable test)" --body-file "$BODY_OVER" | grep -oE '[0-9]+$')
[ -n "$A" ] || die "could not create the proposal"
e2e_track_issue "$A"
echo "  proposal = #$A"
wait_label "$A" "Validation Failed" || die "#$A never reached Validation Failed (check the validate run)"
has_label "$A" "Validation Passed" && c_fail "S1 Validation Passed should be absent" || c_pass "S1 Validation Failed set, Validation Passed absent"
C1=$(val_comment "$A")
check_contains "S1-MSG name over limit"         "$C1" "Custom Prerequisite Name is 59 chars (LFX limit is 20)"
check_contains "S1-MSG description over limit"   "$C1" "Custom Prerequisite Description is 606 chars (LFX limit is 500)"
check_contains "S1-MSG has the failed header"    "$C1" "issue(s) found"

# ---- S2: edit within limits -> Validation Passed -----------------------------
step "S2 edit to a within-limit custom prereq (expect Validation Passed)"
gh issue edit "$A" -R "$REPO" --body-file "$BODY_OK" >/dev/null || die "could not edit the proposal body"
wait_label "$A" "Validation Passed" || die "#$A never flipped to Validation Passed after the edit"
has_label "$A" "Validation Failed" && c_fail "S2 Validation Failed should be cleared" || c_pass "S2 Validation Passed set, Validation Failed cleared"
C2=$(val_comment "$A")
check_contains "S2-MSG all checks passed"         "$C2" "All checks passed"
check_contains "S2-MSG lists the custom prereq"   "$C2" "Custom Prerequisite: name 14/20 chars, description 90/500 chars"
check_absent   "S2-MSG no name-limit error"       "$C2" "Custom Prerequisite Name is"
check_absent   "S2-MSG no description-limit error" "$C2" "Custom Prerequisite Description is"

# ---- S3: unchecked box but over-limit copy -> all problems together ----------
step "S3 edit to UNCHECKED box + over-limit copy (expect Validation Failed, all edits at once)"
gh issue edit "$A" -R "$REPO" --body-file "$BODY_UNCHECKED_COPY" >/dev/null || die "could not edit to unchecked-copy body"
# it was Passed after S2; wait for it to flip back to Failed
for i in $(seq 1 "$RETRIES"); do has_label "$A" "Validation Failed" && ! has_label "$A" "Validation Passed" && break; sleep 5; done
has_label "$A" "Validation Failed" || die "#$A never flipped to Validation Failed after S3 edit"
C3=$(val_comment "$A")
check_contains "S3-MSG flags the unchecked box"    "$C3" "Custom Prerequisite box is not checked"
check_contains "S3-MSG name over limit too"        "$C3" "Custom Prerequisite Name is 59 chars (LFX limit is 20)"
check_contains "S3-MSG description over limit too"  "$C3" "Custom Prerequisite Description is 606 chars (LFX limit is 500)"

# ---- S4: unchecked box, empty fields (no custom prereq) -> mundane pass -------
step "S4 edit to unchecked + empty custom prereq (expect Validation Passed, nothing about it)"
gh issue edit "$A" -R "$REPO" --body-file "$BODY_NONE" >/dev/null || die "could not edit to none body"
wait_label "$A" "Validation Passed" || die "#$A never flipped to Validation Passed after S4 edit"
has_label "$A" "Validation Failed" && c_fail "S4 Validation Failed should be cleared" || c_pass "S4 Validation Passed set, Validation Failed cleared"
C4=$(val_comment "$A")
check_contains "S4-MSG all checks passed"           "$C4" "All checks passed"
check_absent   "S4-MSG says nothing about a custom prereq" "$C4" "Custom Prerequisite"

e2e_summary
