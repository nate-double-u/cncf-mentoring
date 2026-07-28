#!/usr/bin/env bash
#
# Scenario: /lfx-url "batch-only list" (#150). A /lfx-url PR must list only the
# URLs THIS run changes vs the export on main, with a correctly pluralized title,
# and must not re-reference issues already merged.
#
#   S1 create + approve A and B.
#   S2 export [A,B] and MERGE -> A,B on main with empty URLs.
#   S3 /lfx-url A            -> U1 lists ONLY #A, "(1 program)".
#   S4 MERGE U1             -> A's URL on main.
#   S5 /lfx-url B            -> U2 lists ONLY #B, "(1 program)", NOT #A (the fix).
#   S6 /lfx-url B <new url>  -> correction: still ONLY #B, url superseded.
#
# Run:  bash programs/lfx-mentorship/automation/test/e2e/scenarios/lfx-url-batch-list.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

TITLE_TAG="cleanup e2e urlbatch"
BODY_A="$HERE/../fixtures/proposal-A.md"
BODY_B="$HERE/../fixtures/proposal-B.md"
URL_A="https://mentorship.lfx.linuxfoundation.org/project/aaaaaaaa-0000-4000-8000-0000000000a1"
URL_B="https://mentorship.lfx.linuxfoundation.org/project/aaaaaaaa-0000-4000-8000-0000000000b2"
URL_B2="https://mentorship.lfx.linuxfoundation.org/project/aaaaaaaa-0000-4000-8000-0000000000b3"
E2E_PREFLIGHT_BRANCHES="$EXPORT_BRANCH $URL_BRANCH"

# count cross-reference events on issue $1 that originate from PR/issue #$2.
xref_count(){ gh api "repos/$REPO/issues/$1/timeline?per_page=100" --jq "[.[]|select(.event==\"cross-referenced\" and .source.issue.number==$2)]|length" 2>/dev/null; }

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
c_pass "S2 A+B exported and merged to main"

# ---- S3: /lfx-url A -> U1 lists ONLY A, singular title -----------------------
step "S3 /lfx-url A (#$A)"
gh issue comment "$A" -R "$REPO" --body "/lfx-url $URL_A" >/dev/null
U1=$(wait_pr_on "$URL_BRANCH") || die "URL PR U1 never appeared"
echo "  URL PR U1 = #$U1"
check_eq       "S3 U1 title '(1 program)'"   "chore: record LFX URLs for $TERM (1 program)" "$(pr_title "$U1")"
B1=$(pr_body "$U1")
check_contains "S3 U1 body lists #$A"        "$B1" "#$A"
check_contains "S3 U1 body 'Recorded in this PR'" "$B1" "Recorded in this PR"

# ---- S4: merge U1 -> A's URL now on main -------------------------------------
step "S4 merge U1 (#$U1) -> A url on main"
gh pr merge "$U1" -R "$REPO" --merge --delete-branch || die "merge U1 failed"
sleep 5
c_pass "S4 U1 merged (A recorded on main)"

# ---- S5: /lfx-url B -> U2 lists ONLY B, NOT A (the fix) ----------------------
step "S5 /lfx-url B (#$B) -> U2 must list ONLY #$B"
gh issue comment "$B" -R "$REPO" --body "/lfx-url $URL_B" >/dev/null
U2=$(wait_pr_on "$URL_BRANCH") || die "URL PR U2 never appeared"
echo "  URL PR U2 = #$U2"
B2=$(pr_body "$U2")
check_eq       "S5 title '(1 program)' (B only, not counting A)" "chore: record LFX URLs for $TERM (1 program)" "$(pr_title "$U2")"
check_contains "S5 U2 body lists #$B"        "$B2" "#$B"
check_absent   "S5 U2 body does NOT list #$A (the bug)" "$B2" "#$A"
check_contains "S5 U2 body 'Recorded in this PR'" "$B2" "Recorded in this PR"
JSON2=$(export_json_on "$URL_BRANCH")
check_contains "S5 export json has B url"    "$JSON2" "$URL_B"
sleep 5
check_eq       "S5 A NOT re-referenced by U2" "0" "$(xref_count "$A" "$U2")"

# ---- S6: correction -> /lfx-url B with a different URL -----------------------
step "S6 correction: /lfx-url B (#$B) with a different URL"
gh issue comment "$B" -R "$REPO" --body "/lfx-url $URL_B2" >/dev/null
for i in $(seq 1 "$RETRIES"); do case "$(export_json_on "$URL_BRANCH" 2>/dev/null)" in *"$URL_B2"*) break;; esac; sleep 5; done
U3=$(open_pr_on "$URL_BRANCH"); echo "  URL PR (still) = #${U3:-?}"
B3=$(pr_body "${U3:-$U2}")
JSON3=$(export_json_on "$URL_BRANCH")
check_eq       "S6 title still '(1 program)'" "chore: record LFX URLs for $TERM (1 program)" "$(pr_title "${U3:-$U2}")"
check_contains "S6 body lists #$B"           "$B3" "#$B"
check_absent   "S6 body still NOT #$A"       "$B3" "#$A"
check_contains "S6 export json has corrected url" "$JSON3" "$URL_B2"
check_absent   "S6 old B url superseded"     "$JSON3" "$URL_B"

e2e_summary
