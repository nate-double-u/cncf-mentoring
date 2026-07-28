#!/usr/bin/env bash
#
# Scenario: /lfx-url "accumulate before merge" (batch-list, #150). The URL PR must
# list only what THIS PR changes vs main, but when neither URL PR has merged both
# programs still differ from the (empty-URL) main baseline, so both must list -
# i.e. the batch-list filter must not over-filter and regress the display.
#
#   S1 create + approve A and B.
#   S2 export [A,B] and MERGE -> both on main with empty URLs (the baseline).
#   S3 /lfx-url A (do NOT merge) -> U lists ONLY #A, "(1 program)".
#   S4 /lfx-url B (U still open)  -> SAME U accumulates to "(2 programs)", lists
#      both #A and #B, JSON carries both URLs.
#
# Run:  bash programs/lfx-mentorship/automation/test/e2e/scenarios/lfx-url-accumulate.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

TITLE_TAG="cleanup e2e urlaccum"
BODY_A="$HERE/../fixtures/proposal-A.md"
BODY_B="$HERE/../fixtures/proposal-B.md"
URL_A="https://mentorship.lfx.linuxfoundation.org/project/aaaaaaaa-0000-4000-8000-0000000000a1"
URL_B="https://mentorship.lfx.linuxfoundation.org/project/aaaaaaaa-0000-4000-8000-0000000000b2"
E2E_PREFLIGHT_BRANCHES="$EXPORT_BRANCH $URL_BRANCH"

for f in "$BODY_A" "$BODY_B"; do [ -f "$f" ] || die "missing proposal body: $f"; done
e2e_init
assert_no_open_approved
e2e_track_branch "$URL_BRANCH"

# ---- S1: create + approve A and B --------------------------------------------
step "S1 create + approve proposals A and B"
A=$(gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG A (disposable test)" --body-file "$BODY_A" | grep -oE '[0-9]+$')
[ -n "$A" ] || die "could not create A"
e2e_track_issue "$A"
echo "  proposal A = #$A"; approve_proposal "$A"; c_pass "A (#$A) is CNCF Approved"
B=$(gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG B (disposable test)" --body-file "$BODY_B" | grep -oE '[0-9]+$')
[ -n "$B" ] || die "could not create B"
e2e_track_issue "$B"
echo "  proposal B = #$B"; approve_proposal "$B"; c_pass "B (#$B) is CNCF Approved"

# ---- S2: export [A,B] and merge -> both on main with empty URLs --------------
step "S2 export [A,B] and merge (A,B on main, no URLs yet)"
gh workflow run lfx-export.yml -R "$REPO" -f term="$TERM" || die "dispatch failed"
E=$(wait_pr_on "$EXPORT_BRANCH") || die "export PR never appeared"
echo "  export PR E = #$E"
gh pr merge "$E" -R "$REPO" --merge --delete-branch || die "merge E failed"
wait_label "$A" "Exported" || die "A never got Exported"
wait_label "$B" "Exported" || die "B never got Exported"
sleep 5
c_pass "S2 A+B exported and merged to main (empty URLs = baseline)"

# ---- S3: /lfx-url A, DO NOT merge -> U lists ONLY A --------------------------
step "S3 /lfx-url A (#$A), leave U open"
gh issue comment "$A" -R "$REPO" --body "/lfx-url $URL_A" >/dev/null
U=$(wait_pr_title "$URL_BRANCH" "(1 program)") || die "URL PR (1 program) never appeared"
echo "  URL PR U = #$U"
BODY_UA=$(pr_body "$U")
check_eq       "S3 title '(1 program)'"         "chore: record LFX URLs for $TERM (1 program)" "$(pr_title "$U")"
check_contains "S3 body lists #$A"              "$BODY_UA" "#$A"
check_absent   "S3 body does NOT list #$B yet"  "$BODY_UA" "#$B"
check_contains "S3 body 'Recorded in this PR'"  "$BODY_UA" "Recorded in this PR"

# ---- S4: /lfx-url B with U STILL OPEN -> accumulate to 2 programs -------------
step "S4 /lfx-url B (#$B) with U (#$U) still open -> must accumulate to BOTH"
gh issue comment "$B" -R "$REPO" --body "/lfx-url $URL_B" >/dev/null
U2=$(wait_pr_title "$URL_BRANCH" "(2 programs)") || die "URL PR never reached (2 programs) -- over-filter/clobber-display regression"
echo "  URL PR (accumulated) = #$U2"
check_eq       "S4 same PR (updated U, not a new PR)" "$U" "$U2"
BODY_UAB=$(pr_body "$U2")
check_eq       "S4 title '(2 programs)'"        "chore: record LFX URLs for $TERM (2 programs)" "$(pr_title "$U2")"
check_contains "S4 body lists #$A"              "$BODY_UAB" "#$A"
check_contains "S4 body lists #$B"              "$BODY_UAB" "#$B"
check_contains "S4 body 'Recorded in this PR'"  "$BODY_UAB" "Recorded in this PR"
JSON=$(export_json_on "$URL_BRANCH")
check_contains "S4 export json has A url"        "$JSON" "$URL_A"
check_contains "S4 export json has B url"        "$JSON" "$URL_B"

e2e_summary
