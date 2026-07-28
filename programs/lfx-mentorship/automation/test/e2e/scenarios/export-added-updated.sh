#!/usr/bin/env bash
#
# Scenario: export PR added-vs-updated split (cncf/mentoring#1992). A re-export
# distinguishes programs newly added to the export from already-exported programs
# whose data merely changed, in both the PR title count and body sections, and
# notifies only the newly-added.
#
#   S1  create + approve A. Export E1 -> "(1 new)": Newly added lists #A, no
#       Updated section, A notified once. Merge -> A baseline.
#   S2  materially edit A + re-approve (A now differs from the baseline).
#   S3  create + approve B (brand new).
#   S4  re-export E2 -> "(1 new, 1 updated)": Newly added #B, Updated #A; B
#       notified, A's notif count UNCHANGED. Merge E2.
#   S5  edit A again + re-approve, re-export with NO new proposal -> "(1 updated)":
#       Updated lists #A, no Newly added, and NOBODY notified (empty notify set).
#
# Run:  bash programs/lfx-mentorship/automation/test/e2e/scenarios/export-added-updated.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

TITLE_TAG="cleanup e2e addupd"
BODY_A="$HERE/../fixtures/addupd-A.md"
BODY_B="$HERE/../fixtures/addupd-B.md"
E2E_PREFLIGHT_BRANCHES="$EXPORT_BRANCH"

for f in "$BODY_A" "$BODY_B"; do [ -f "$f" ] || die "missing proposal body: $f"; done
e2e_init
assert_no_open_approved
e2e_track_branch "$EXPORT_BRANCH"

# ---- S1: create + approve A; export; A newly added + notified ----------------
step "S1 create + approve A, export (A newly added)"
A=$(gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG A (disposable test)" --body-file "$BODY_A" | grep -oE '[0-9]+$')
[ -n "$A" ] || die "could not create A"
e2e_track_issue "$A"
echo "  proposal A = #$A"; approve_proposal "$A"; c_pass "A (#$A) is CNCF Approved"
gh workflow run lfx-export.yml -R "$REPO" -f term="$TERM" || die "dispatch failed"
E1=$(wait_pr_title "$EXPORT_BRANCH" "1 new") || die "export PR '1 new' never appeared"
echo "  export PR E1 = #$E1"
BODY_E1=$(pr_body "$E1")
check_eq       "S1 E1 title '(1 new)'"             "chore: LFX export for $TERM (1 new)" "$(pr_title "$E1")"
check_contains "S1 E1 body has Newly added"        "$BODY_E1" "Newly added:"
check_contains "S1 E1 Newly added lists #$A"       "$(section "$BODY_E1" "Newly added:" "Export files:")" "#$A"
check_absent   "S1 E1 body has NO Updated section" "$BODY_E1" "Updated:"
wait_notif_ge "$A" 1 || die "A never got its export notification"
NOTIF_A=$(notif_count "$A")
check_eq       "S1 A notified once"                "1" "$NOTIF_A"
gh pr merge "$E1" -R "$REPO" --merge --delete-branch || die "merge E1 failed"
wait_label "$A" "Exported" || die "A never got Exported"
sleep 5
c_pass "S1 E1 merged -> A on main (baseline)"

# ---- S2: materially edit A, re-approve (A becomes 'updated') ------------------
step "S2 edit A's description + re-approve (A now differs from baseline)"
sed 's/Revision: 1\./Revision: 2 (edited for e2e)./' "$BODY_A" > "$HERE/../fixtures/.addupd-A-edited.md"
gh issue edit "$A" -R "$REPO" --body-file "$HERE/../fixtures/.addupd-A-edited.md" >/dev/null || die "could not edit A"
rm -f "$HERE/../fixtures/.addupd-A-edited.md"
wait_no_label "$A" "CNCF Approved" || die "A's CNCF approval was not cleared by the material edit"
approve_proposal "$A"; c_pass "A (#$A) re-approved to CNCF Approved with changed data"

# ---- S3: create + approve B (brand new) --------------------------------------
step "S3 create + approve B (newly added next run)"
B=$(gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG B (disposable test)" --body-file "$BODY_B" | grep -oE '[0-9]+$')
[ -n "$B" ] || die "could not create B"
e2e_track_issue "$B"
echo "  proposal B = #$B"; approve_proposal "$B"; c_pass "B (#$B) is CNCF Approved"

# ---- S4: re-export -> B new, A updated; only B re-notified -------------------
step "S4 re-export -> B new + A updated (the regression under test)"
gh workflow run lfx-export.yml -R "$REPO" -f term="$TERM" || die "re-dispatch failed"
E2=$(wait_pr_title "$EXPORT_BRANCH" "1 new, 1 updated") || die "re-export PR '1 new, 1 updated' never appeared -- split regression"
echo "  re-export PR E2 = #$E2"
BODY_E2=$(pr_body "$E2")
NEW_SEC=$(section "$BODY_E2" "Newly added:" "Updated:")
UPD_SEC=$(section "$BODY_E2" "Updated:" "Export files:")
check_eq       "S4 E2 title '(1 new, 1 updated)'"  "chore: LFX export for $TERM (1 new, 1 updated)" "$(pr_title "$E2")"
check_contains "S4 E2 Newly added lists #$B"       "$NEW_SEC" "#$B"
check_absent   "S4 E2 Newly added excludes #$A"    "$NEW_SEC" "#$A"
check_contains "S4 E2 Updated lists #$A"           "$UPD_SEC" "#$A"
check_absent   "S4 E2 Updated excludes #$B"        "$UPD_SEC" "#$B"
wait_notif_ge "$B" 1 || die "B never got its export notification"
c_pass "S4 B notified"
check_eq       "S4 A NOT re-notified (updated, count unchanged)" "$NOTIF_A" "$(notif_count "$A")"
gh pr merge "$E2" -R "$REPO" --merge --delete-branch || die "merge E2 failed"
c_pass "S4 E2 merged (full lifecycle)"

# ---- S5: re-export with ONLY an update (A again), no new -> notify NOBODY -----
step "S5 re-export updated-only (A again, no new) -> notify nobody"
NOTIF_B=$(notif_count "$B")
sed 's/Revision: 1\./Revision: 3 (edited again for e2e)./' "$BODY_A" > "$HERE/../fixtures/.addupd-A-edited2.md"
gh issue edit "$A" -R "$REPO" --body-file "$HERE/../fixtures/.addupd-A-edited2.md" >/dev/null || die "could not edit A again"
rm -f "$HERE/../fixtures/.addupd-A-edited2.md"
wait_no_label "$A" "CNCF Approved" || die "A's CNCF approval not cleared by the 2nd material edit"
approve_proposal "$A"; c_pass "A (#$A) re-approved (updated only, no new proposal this run)"
PREV_RUN=$(latest_export_run)
gh workflow run lfx-export.yml -R "$REPO" -f term="$TERM" || die "S5 dispatch failed"
# "(1 updated)" is unambiguous: it is NOT a substring of "(1 new, 1 updated)".
E3=$(wait_pr_title "$EXPORT_BRANCH" "(1 updated)") || die "S5 export PR '(1 updated)' never appeared"
echo "  re-export PR E3 = #$E3"
BODY_E3=$(pr_body "$E3")
UPD_SEC3=$(section "$BODY_E3" "Updated:" "Export files:")
check_eq       "S5 E3 title '(1 updated)'"           "chore: LFX export for $TERM (1 updated)" "$(pr_title "$E3")"
check_absent   "S5 E3 body has NO Newly added"       "$BODY_E3" "Newly added:"
check_contains "S5 E3 Updated lists #$A"             "$UPD_SEC3" "#$A"
check_absent   "S5 E3 Updated excludes #$B"          "$UPD_SEC3" "#$B"
# Wait for the WHOLE export run (notify step included) to finish, THEN assert that
# neither issue gained a notification -- an empty notify set pings nobody.
wait_export_run_after "$PREV_RUN" || die "S5 export run never completed (cannot soundly assert 'notify nobody')"
check_eq       "S5 A NOT notified (count unchanged)" "$NOTIF_A" "$(notif_count "$A")"
check_eq       "S5 B NOT notified (count unchanged)" "$NOTIF_B" "$(notif_count "$B")"
gh pr merge "$E3" -R "$REPO" --merge --delete-branch || die "merge E3 failed"
c_pass "S5 E3 merged (updated-only lifecycle)"

e2e_summary
