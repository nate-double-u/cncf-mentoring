#!/usr/bin/env bash
#
# Scenario: "Mentors listed" board column (ADMIN_OWNED protection). The guard
# logic (shouldSkipExport / shouldSkipSync) is unit-tested; this proves the
# workflow wiring and the exact board column name: a card parked in "Mentors
# listed" is not pulled back to "Exported" by either automation path.
#
#   S1  create + approve A.
#   S2  export [A] + merge -> A card advances to "Exported".
#   S3  move A's card to "Mentors listed" (simulate the admin advancing it).
#   S4  re-export [A,B] (shouldSkipExport) -> A stays "Mentors listed", B -> Exported.
#   S5  fire board-sync on A via a label toggle (shouldSkipSync) -> A stays put.
#
# Requires the ADMIN_OWNED change on dev main and a "Mentors listed" column on the
# DEMO board.
#
# Run:  bash programs/lfx-mentorship/automation/test/e2e/scenarios/mentors-listed.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

TITLE_TAG="cleanup e2e mentors"
STATUS_FIELD="PVTSSF_lAHOAEP2W84BXacIzhSnctg"        # DEMO board "Status" field
OPT_MENTORS_LISTED="1cde052a"                        # "Mentors listed" option id
TOGGLE_LABEL="administration"                        # benign label; fires board-sync only
BODY_A="$HERE/../fixtures/proposal-A.md"
BODY_B="$HERE/../fixtures/proposal-B.md"
E2E_PREFLIGHT_BRANCHES="$EXPORT_BRANCH"

for f in "$BODY_A" "$BODY_B"; do [ -f "$f" ] || die "missing proposal body: $f"; done
e2e_init
assert_no_open_approved
# The board column must exist by the exact name the code expects.
[ -n "$(gh api graphql -f query='query{node(id:"'"$DEMO_PROJECT"'"){... on ProjectV2{field(name:"Status"){... on ProjectV2SingleSelectField{options{name}}}}}}' --jq '.data.node.field.options[]|select(.name=="Mentors listed")|.name')" ] \
  && c_pass "DEMO board has a 'Mentors listed' column" || die "DEMO board has no 'Mentors listed' column (add it first)"
# The S4 re-export opens a PR on EXPORT_BRANCH that this test intentionally leaves
# unmerged; track the branch so teardown closes it.
e2e_track_branch "$EXPORT_BRANCH"

# ---- S1: create + approve A --------------------------------------------------
step "S1 create + approve proposal A"
A=$(gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG A (disposable test)" --body-file "$BODY_A" | grep -oE '[0-9]+$')
[ -n "$A" ] || die "could not create A"
e2e_track_issue "$A"
echo "  proposal A = #$A"; approve_proposal "$A"; c_pass "A (#$A) is CNCF Approved"

# ---- S2: export [A] + merge; A card -> Exported ------------------------------
step "S2 export [A] + merge -> A card advances to Exported"
gh workflow run lfx-export.yml -R "$REPO" -f term="$TERM" || die "dispatch failed"
E=$(wait_pr_on "$EXPORT_BRANCH") || die "export PR never appeared"
echo "  export PR E = #$E"
gh pr merge "$E" -R "$REPO" --merge --delete-branch || die "merge E failed"
wait_label "$A" "Exported" || die "A never got Exported label"
wait_card "$A" "Exported" || die "A card never reached Exported (got '$(card_status "$A")')"
c_pass "S2 A exported; card at Exported"

# ---- S3: move A's card to "Mentors listed" (simulate the admin) --------------
step "S3 move A (#$A) card to 'Mentors listed'"
ITEM_A=$(card_id "$A"); [ -n "$ITEM_A" ] || die "no board card for A"
set_card "$ITEM_A" "$OPT_MENTORS_LISTED"
wait_card "$A" "Mentors listed" || die "could not set A card to 'Mentors listed' (got '$(card_status "$A")')"
c_pass "S3 A card is 'Mentors listed'"

# ---- S4: re-export path (shouldSkipExport) -----------------------------------
step "S4 re-export [A,B] -> A must STAY 'Mentors listed', B -> Exported"
B=$(gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG B (disposable test)" --body-file "$BODY_B" | grep -oE '[0-9]+$')
[ -n "$B" ] || die "could not create B"
e2e_track_issue "$B"
echo "  proposal B = #$B"; approve_proposal "$B"
PREV_EXPORT=$(latest_run "lfx-export.yml")
gh workflow run lfx-export.yml -R "$REPO" -f term="$TERM" || die "dispatch failed"
RUN=$(wait_new_run "lfx-export.yml" "$PREV_EXPORT") || die "re-export run never completed"
echo "  re-export run = $RUN (completed)"
sleep 5
check_eq "T-EXPORT-PROTECT A stays 'Mentors listed'" "Mentors listed" "$(card_status "$A")"
check_eq "T-EXPORT B advanced to 'Exported'"          "Exported"       "$(card_status "$B")"

# ---- S5: board-sync path (shouldSkipSync) via a label toggle -----------------
step "S5 fire board-sync on A (label toggle) -> A must STAY 'Mentors listed'"
PREV_SYNC=$(latest_run "lfx-proposal-board-sync.yml")
gh issue edit "$A" -R "$REPO" --add-label "$TOGGLE_LABEL" >/dev/null || die "could not add label"
RUN2=$(wait_new_run "lfx-proposal-board-sync.yml" "$PREV_SYNC") || die "board-sync run never completed after label add"
echo "  board-sync run = $RUN2 (completed)"
sleep 5
check_eq "T-SYNC-PROTECT A stays 'Mentors listed' after board-sync" "Mentors listed" "$(card_status "$A")"
gh issue edit "$A" -R "$REPO" --remove-label "$TOGGLE_LABEL" >/dev/null 2>&1   # tidy up

e2e_summary
