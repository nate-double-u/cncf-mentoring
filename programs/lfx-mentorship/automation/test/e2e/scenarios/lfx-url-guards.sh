#!/usr/bin/env bash
#
# Scenario: /lfx-url "not ready yet" guardrails. The decision functions are
# unit-tested; this exercises the workflow wiring (the handler returns at each
# gate, posts the right comment, records nothing, opens no PR, board unchanged).
#
#   G1  /lfx-url before the proposal is exported at all (no Exported label)
#         -> lfxUrlDecision => 'not-exported'.
#   G2  /lfx-url after export but before the export PR is merged (not on main)
#         -> locateExportedProgram => null.
#   G3  recovery: merge the export PR, re-run /lfx-url -> succeeds.
#
# Run:  bash programs/lfx-mentorship/automation/test/e2e/scenarios/lfx-url-guards.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

TITLE_TAG="cleanup e2e urlguard"
PROPOSAL_BODY="$HERE/../fixtures/proposal-A.md"
URL_C="https://mentorship.lfx.linuxfoundation.org/project/cccccccc-0000-4000-8000-0000000000c3"
E2E_PREFLIGHT_BRANCHES="$EXPORT_BRANCH $URL_BRANCH"

[ -f "$PROPOSAL_BODY" ] || die "missing proposal body: $PROPOSAL_BODY"
e2e_init
assert_no_open_approved
# G2 leaves the export PR open until G3, and G3 leaves the URL PR open; track both
# branches so teardown closes whatever is still open.
e2e_track_branch "$EXPORT_BRANCH"
e2e_track_branch "$URL_BRANCH"

# ---- S1: create + approve proposal C (NOT exported) --------------------------
step "S1 create + approve proposal C (do NOT export yet)"
C=$(gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG C (disposable test)" --body-file "$PROPOSAL_BODY" | grep -oE '[0-9]+$')
[ -n "$C" ] || die "could not create C"
e2e_track_issue "$C"
echo "  proposal C = #$C"; approve_proposal "$C"; c_pass "C (#$C) is CNCF Approved (no Exported label)"
has_label "$C" "Exported" && die "C unexpectedly already has the Exported label; did an export run?"

# ---- G1: /lfx-url before the proposal is exported at all ----------------------
step "G1 /lfx-url before export (expect: rejected, nothing recorded)"
gh issue comment "$C" -R "$REPO" --body "/lfx-url $URL_C" >/dev/null
wait_comment_with "$C" "has not been exported yet" || die "G1: never got the not-exported reply (check the approvals run)"
sleep 8   # let the always() board-sync step settle
check_contains "G1-MSG reply says not exported"       "$(comment_with "$C" "has not been exported yet")" "Run the export first"
check_eq       "G1-NO-RECORD no recorded-URL comment"  "0" "$(count_comments_with "$C" "LFX URL recorded")"
check_eq       "G1-NO-PR no URL PR opened"             ""  "$(open_pr_on "$URL_BRANCH")"
check_absent   "G1-BOARD card not Posted to LFX"       "$(card_status "$C")" "Posted to LFX"

# ---- S2: export -> E_C, but DO NOT merge; C gets Exported --------------------
step "S2 export (open export PR E_C, leave it UNMERGED)"
gh workflow run lfx-export.yml -R "$REPO" -f term="$LFX_TERM" || die "dispatch failed"
EC=$(wait_pr_on "$EXPORT_BRANCH") || die "export PR E_C never appeared"
echo "  export PR E_C = #$EC (left open)"
wait_label "$C" "Exported" || die "C never got the Exported label"
c_pass "S2 C now Exported, export PR #$EC open (not merged)"

# ---- G2: /lfx-url after export, before the export PR is merged ---------------
step "G2 /lfx-url with export PR unmerged (expect: rejected, nothing recorded)"
gh issue comment "$C" -R "$REPO" --body "/lfx-url $URL_C" >/dev/null
wait_comment_with "$C" "no exported program for this issue is on" || die "G2: never got the not-on-main reply"
sleep 8
G2NOTE=$(comment_with "$C" "no exported program for this issue is on")
check_contains "G2-MSG says not on main yet"       "$G2NOTE" "no exported program for this issue is on"
check_contains "G2-MSG advises merging export PR"  "$G2NOTE" "Merge the term's export PR"
check_contains "G2-MSG hands back the re-run cmd"  "$G2NOTE" "/lfx-url $URL_C"
check_eq       "G2-NO-RECORD still no recorded-URL comment" "0" "$(count_comments_with "$C" "LFX URL recorded")"
check_eq       "G2-NO-PR still no URL PR opened"            ""  "$(open_pr_on "$URL_BRANCH")"
check_absent   "G2-BOARD card not Posted to LFX"           "$(card_status "$C")" "Posted to LFX"

# ---- S3 + G3: merge the export PR, re-run /lfx-url -> succeeds ----------------
step "G3 merge export PR then re-run /lfx-url (expect: recorded)"
gh pr merge "$EC" -R "$REPO" --merge --delete-branch || die "merge E_C failed"
sleep 5   # let the merge land on main before the handler checks out main
gh issue comment "$C" -R "$REPO" --body "/lfx-url $URL_C" >/dev/null
UC=$(wait_pr_title "$URL_BRANCH" "(1 programs)") || die "G3: URL PR never appeared after merge + re-run"
wait_comment_with "$C" "LFX URL recorded" || die "G3: recorded-URL comment never posted"
sleep 8
G3NOTE=$(comment_with "$C" "LFX URL recorded")
c_pass         "G3-PR URL PR opened (#$UC)"
check_contains "G3-RECORD recorded-URL comment" "$G3NOTE" "LFX URL recorded"
check_contains "G3-NEXT next-steps appended"    "$G3NOTE" "Next on LFX"
check_contains "G3-JSON export json has C url"   "$(export_json_on "$URL_BRANCH")" "$URL_C"
check_eq       "G3-BOARD card now Posted to LFX" "Posted to LFX" "$(card_status "$C")"

e2e_summary
