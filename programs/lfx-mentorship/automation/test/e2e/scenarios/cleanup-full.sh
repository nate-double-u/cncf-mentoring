#!/usr/bin/env bash
#
# Scenario: LFX automation cleanup (PR #136 class) - a broad lifecycle sweep.
# Exercises export authorship, the merge-notification copy, the no-op export,
# delta notifications, and /lfx-url next-steps + batch/clobber behavior in one
# run. All proposals stay approved throughout (sticky carry-forward is exercised
# separately by export-added-updated and the sticky scenario).
#
#   S1 approve A. S2 export E1 [A] (bot-authored, no Assisted-by). S3 merge E1
#   (A notified "created on LFX", once). S4 no-change export -> NO PR. S5 approve
#   B. S6 export E2 [A,B]. S7 merge E2 (B newly notified, A not re-notified).
#   S8 /lfx-url A -> URL PR U lists #A, next-steps posted. S9 /lfx-url B with U
#   open -> U accumulates both #A and #B (clobber fix).
#
# Run:  bash programs/lfx-mentorship/automation/test/e2e/scenarios/cleanup-full.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

TITLE_TAG="cleanup e2e full"
BODY_A="$HERE/../fixtures/proposal-A.md"
BODY_B="$HERE/../fixtures/proposal-B.md"
URL_A="https://mentorship.lfx.linuxfoundation.org/project/aaaaaaaa-0000-4000-8000-0000000000a1"
URL_B="https://mentorship.lfx.linuxfoundation.org/project/aaaaaaaa-0000-4000-8000-0000000000b2"
E2E_PREFLIGHT_BRANCHES="$EXPORT_BRANCH $URL_BRANCH"

for f in "$BODY_A" "$BODY_B"; do [ -f "$f" ] || die "missing proposal body: $f"; done
e2e_init
assert_no_open_approved
e2e_track_branch "$EXPORT_BRANCH"
e2e_track_branch "$URL_BRANCH"

# ---- S1: create + approve proposal A -----------------------------------------
step "S1 create + approve proposal A"
A=$(gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG A (disposable test)" --body-file "$BODY_A" | grep -oE '[0-9]+$')
[ -n "$A" ] || die "could not create A"
e2e_track_issue "$A"
echo "  proposal A = #$A"; approve_proposal "$A"; c_pass "A (#$A) is CNCF Approved"

# ---- S2: export #1 -> E1 [A]; authorship checks ------------------------------
step "S2 export #1 (term=[A])"
gh workflow run lfx-export.yml -R "$REPO" -f term="$LFX_TERM" || die "dispatch failed"
E1=$(wait_pr_on "$EXPORT_BRANCH") || die "export PR E1 never appeared"
echo "  export PR E1 = #$E1"
check_eq   "T-AUTH author = bot"    "github-actions[bot]" "$(pr_last_commit_field "$E1" '.commit.author.name')"
check_eq   "T-AUTH committer = bot" "github-actions[bot]" "$(pr_last_commit_field "$E1" '.commit.committer.name')"
MSG=$(pr_last_commit_field "$E1" '.commit.message')
check_contains "T-AUTH signed-off by bot" "$MSG" "Signed-off-by: github-actions[bot]"
check_absent   "T-AUTH no Assisted-by"    "$MSG" "Assisted-by"
check_contains "E1 body lists #$A"        "$(pr_body "$E1")" "#$A"

# ---- S3: merge E1; merge-notification copy -----------------------------------
step "S3 merge E1 (#$E1)"
gh pr merge "$E1" -R "$REPO" --merge --delete-branch || die "merge E1 failed"
wait_comment_with "$A" "has been merged" || die "A never got its merge notification"
NOTE_A=$(comment_with "$A" "has been merged")
check_contains "T-NOTIFY-COPY says created" "$NOTE_A" "created on LFX"
check_absent   "T-NOTIFY-COPY not 'live'"   "$NOTE_A" "live on LFX"
check_absent   "T-NOTIFY-COPY no 'post to LFX platform'" "$NOTE_A" "post to LFX platform"
check_eq       "T-NOTIFY A notified once"   "1" "$(count_comments_with "$A" "has been merged")"

# ---- S4: export #2 no-op -> NO PR --------------------------------------------
step "S4 export #2 (no changes) -> expect NO PR"
PREV=$(latest_export_run)
gh workflow run lfx-export.yml -R "$REPO" -f term="$LFX_TERM" || die "dispatch failed"
wait_export_run_after "$PREV" || die "no-op export run never completed"
sleep 5
check_eq "T-NOOP no export PR opened" "" "$(open_pr_on "$EXPORT_BRANCH")"

# ---- S5: create + approve proposal B -----------------------------------------
step "S5 create + approve proposal B"
B=$(gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG B (disposable test)" --body-file "$BODY_B" | grep -oE '[0-9]+$')
[ -n "$B" ] || die "could not create B"
e2e_track_issue "$B"
echo "  proposal B = #$B"; approve_proposal "$B"; c_pass "B (#$B) is CNCF Approved"

# ---- S6: export #3 -> E2 [A,B] -----------------------------------------------
step "S6 export #3 (term=[A,B])"
gh workflow run lfx-export.yml -R "$REPO" -f term="$LFX_TERM" || die "dispatch failed"
E2=$(wait_pr_on "$EXPORT_BRANCH") || die "export PR E2 never appeared"
echo "  export PR E2 = #$E2"
BODY2=$(pr_body "$E2")
check_contains "E2 body lists #$A" "$BODY2" "#$A"
check_contains "E2 body lists #$B" "$BODY2" "#$B"

# ---- S7: merge E2; delta notification ----------------------------------------
step "S7 merge E2 (#$E2)"
gh pr merge "$E2" -R "$REPO" --merge --delete-branch || die "merge E2 failed"
wait_comment_with "$B" "has been merged" || die "B never got its merge notification"
sleep 5
check_eq "T-NOTIFY-DELTA B newly notified (once)"    "1" "$(count_comments_with "$B" "has been merged")"
check_eq "T-NOTIFY-DELTA A NOT re-notified (still 1)" "1" "$(count_comments_with "$A" "has been merged")"

# ---- S8: /lfx-url on A (do NOT merge U) -> next-steps + batch list ------------
step "S8 /lfx-url on A (#$A)"
gh issue comment "$A" -R "$REPO" --body "/lfx-url $URL_A" >/dev/null
U=$(wait_pr_title "$URL_BRANCH" "(1 programs)") || die "URL PR (1 programs) never appeared"
echo "  URL PR U = #$U"
wait_comment_with "$A" "LFX URL recorded" || die "A never got its recorded-URL note"
NOTE_URL_A=$(comment_with "$A" "LFX URL recorded")
check_contains "T-URL-NEXT recorded line"  "$NOTE_URL_A" "LFX URL recorded"
check_contains "T-URL-NEXT Next on LFX"     "$NOTE_URL_A" "Next on LFX"
check_contains "T-URL-NEXT step 1 approve"  "$NOTE_URL_A" "An LFX admin approves the program"
check_contains "T-URL-NEXT step 2 mentors"  "$NOTE_URL_A" "CNCF admins add the mentors"
check_eq       "T-URL-TITLE (1 programs)"   "chore: record LFX URLs for $LFX_TERM (1 programs)" "$(pr_title "$U")"
UBODY=$(pr_body "$U")
check_contains "T-URL-LINKS recorded-so-far" "$UBODY" "Recorded so far"
check_contains "T-URL-LINKS lists #$A"       "$UBODY" "#$A"
check_contains "T-AUTOGEN line"              "$(pr_last_commit_field "$U" '.commit.message')" "Auto-generated by lfx-proposal-approvals workflow."
check_eq       "T-AUTH (URL PR) author=bot"  "github-actions[bot]" "$(pr_last_commit_field "$U" '.commit.author.name')"

# ---- S9: /lfx-url on B WITHOUT merging U -> clobber fix -----------------------
step "S9 /lfx-url on B (#$B), U still open"
gh issue comment "$B" -R "$REPO" --body "/lfx-url $URL_B" >/dev/null
U2=$(wait_pr_title "$URL_BRANCH" "(2 programs)") || die "URL PR never reached (2 programs) -- possible clobber regression"
UBODY2=$(pr_body "$U2")
JSON=$(export_json_on "$URL_BRANCH")
check_contains "T-CLOBBER body lists #$A" "$UBODY2" "#$A"
check_contains "T-CLOBBER body lists #$B" "$UBODY2" "#$B"
check_contains "T-CLOBBER json has A url" "$JSON" "$URL_A"
check_contains "T-CLOBBER json has B url" "$JSON" "$URL_B"

e2e_summary
