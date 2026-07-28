#!/usr/bin/env bash
#
# Scenario: /lfx-url pins the program link into the issue BODY (lfx-url-in-body).
# After /lfx-url on an exported + CNCF-approved proposal, the OP body gains a
# marker-delimited block at the bottom (under a rule) carrying the linked program
# title; a second /lfx-url with a different URL updates the block in place.
#
#   S1 create + approve A.
#   S2 export [A] and MERGE -> A on main (empty URL baseline).
#   S3 /lfx-url A (URL_A)   -> body gains the block (bottom, under ---, linked
#                             title = program_name_full, contains URL_A).
#   S4 /lfx-url A (URL_A2)  -> block updated in place: one block, URL_A2, no URL_A.
#
# Run:  bash programs/lfx-mentorship/automation/test/e2e/scenarios/lfx-url-body.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

TITLE_TAG="cleanup e2e urlbody"
PROPOSAL_BODY="$HERE/../fixtures/proposal-A.md"
URL_A="https://mentorship.lfx.linuxfoundation.org/project/aaaaaaaa-0000-4000-8000-0000000000a1"
URL_A2="https://mentorship.lfx.linuxfoundation.org/project/aaaaaaaa-0000-4000-8000-0000000000a2"
# The full LFX title the export composes for A (CNCF - <proj>: <name> (<token>)),
# i.e. the fixture's CNCF Project + Program Name. This is the body block's link text.
TITLE_FULL="CNCF - Backstage: cleanup e2e proposal A (2026 Term 3)"
E2E_PREFLIGHT_BRANCHES="$EXPORT_BRANCH $URL_BRANCH"

[ -f "$PROPOSAL_BODY" ] || die "missing proposal body: $PROPOSAL_BODY"
e2e_init
assert_no_open_approved
e2e_track_branch "$URL_BRANCH"

# ---- S1: create + approve A --------------------------------------------------
step "S1 create + approve proposal A"
A=$(gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG A (disposable test)" --body-file "$PROPOSAL_BODY" | grep -oE '[0-9]+$')
[ -n "$A" ] || die "could not create A"
e2e_track_issue "$A"
echo "  proposal A = #$A"; approve_proposal "$A"; c_pass "A (#$A) is CNCF Approved"

# ---- S2: export [A] and merge -> A on main -----------------------------------
step "S2 export [A] and merge (A on main, no URL yet)"
gh workflow run lfx-export.yml -R "$REPO" -f term="$TERM" || die "dispatch failed"
E=$(wait_pr_on "$EXPORT_BRANCH") || die "export PR never appeared"
echo "  export PR E = #$E"
gh pr merge "$E" -R "$REPO" --merge --delete-branch || die "merge E failed"
wait_label "$A" "Exported" || die "A never got Exported"
sleep 5
c_pass "S2 A exported and merged to main"

# ---- S3: /lfx-url A -> body gains the block ----------------------------------
step "S3 /lfx-url A (#$A) -> pin the link into the issue body"
gh issue comment "$A" -R "$REPO" --body "/lfx-url $URL_A" >/dev/null
wait_body_contains "$A" "<!-- lfx-url:start -->" || die "A body never gained the lfx-url block"
BODY=$(issue_body "$A")
check_contains "S3 body has start marker"        "$BODY" "<!-- lfx-url:start -->"
check_contains "S3 body has end marker"          "$BODY" "<!-- lfx-url:end -->"
check_contains "S3 body has linked full title"   "$BODY" "**LFX program:** [$TITLE_FULL]($URL_A)"
check_contains "S3 body has the horizontal rule" "$BODY" "---"
# The block must sit at the BOTTOM: trailing whitespace removed, body ends with
# the end marker.
TRIMMED=$(printf '%s' "$BODY" | sed -e 's/[[:space:]]*$//')
case "$TRIMMED" in
  *"<!-- lfx-url:end -->") c_pass "S3 block is at the bottom of the body";;
  *) c_fail "S3 block is NOT at the bottom (body does not end with end marker)";;
esac
check_contains "S3 original proposal content preserved" "$BODY" "### CNCF Project"

# ---- S4: /lfx-url A again with a different URL -> update in place -------------
step "S4 /lfx-url A (#$A) with a new URL -> update block in place (no duplicate)"
gh issue comment "$A" -R "$REPO" --body "/lfx-url $URL_A2" >/dev/null
wait_body_contains "$A" "$URL_A2" || die "A body never updated to the new URL"
BODY2=$(issue_body "$A")
COUNT=$(printf '%s' "$BODY2" | grep -c "<!-- lfx-url:start -->")
check_eq       "S4 exactly one block (no duplicate)" "1" "$COUNT"
check_contains "S4 body has the NEW url"             "$BODY2" "$URL_A2"
check_absent   "S4 body no longer has the OLD url"   "$BODY2" "$URL_A"
check_contains "S4 linked title still present"       "$BODY2" "**LFX program:** [$TITLE_FULL]($URL_A2)"

e2e_summary
