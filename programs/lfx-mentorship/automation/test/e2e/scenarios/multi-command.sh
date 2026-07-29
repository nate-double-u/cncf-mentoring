#!/usr/bin/env bash
#
# Scenario: multi-command (cncf/mentoring#1977, #1978, shipped in #1993).
# A SINGLE comment carrying several slash commands must have EVERY command act,
# in document order, not just the first. Under the old parser only the first ran
# and the rest were silently dropped.
#
#   S1  create a disposable proposal whose sole mentor is the proposer, so it
#       auto-confirms -> Validation Passed + Mentors Confirmed + Awaiting Approval.
#   S2  post ONE comment: /confirm + /approve + /cncf-approve.
#   S3  assert all three acted and cascaded to CNCF Approved in one run, and that
#       each command also responded.
#
# Requires the fix on the dev fork's DEFAULT branch (issue_comment workflows run
# the workflow file from the issue repo's default branch).
#
# Run:  bash programs/lfx-mentorship/automation/test/e2e/scenarios/multi-command.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

TITLE_TAG="cleanup e2e multicmd"                     # unique to THIS test's disposables
PROPOSAL_BODY="$HERE/../fixtures/multi-command.md"

[ -f "$PROPOSAL_BODY" ] || die "missing proposal body: $PROPOSAL_BODY"
e2e_init

# ---- S1: create the disposable proposal (auto-confirms) ----------------------
step "S1 create proposal"
P=$(gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG (disposable test)" --body-file "$PROPOSAL_BODY" | grep -oE '[0-9]+$')
[ -n "$P" ] || die "could not create proposal"
e2e_track_issue "$P"
echo "  proposal = #$P"
wait_label "$P" "Validation Passed" || die "#$P never validated"
wait_label "$P" "Mentors Confirmed" || die "#$P mentors not auto-confirmed (sole mentor = proposer)"
wait_label "$P" "Awaiting Maintainer/Contribex Approval" || die "#$P not awaiting maintainer approval"
c_pass "S1 pre-state: Validation Passed + Mentors Confirmed + Awaiting Maintainer/Contribex Approval"

# ---- S2: ONE comment carrying three commands ---------------------------------
step "S2 post a single comment with /confirm + /approve + /cncf-approve"
gh issue comment "$P" -R "$REPO" --body $'/confirm\n/approve\n/cncf-approve' >/dev/null || die "could not post combined comment"
echo "  posted combined command comment on #$P"

# ---- S3: every command acted, in order, cascading within one run -------------
step "S3 assert all three commands acted"
wait_label "$P" "CNCF Approved" || die "#$P never reached CNCF Approved -- /approve and/or /cncf-approve were dropped (the bug)"
c_pass "S3 reached CNCF Approved (both /approve and /cncf-approve acted + cascaded)"
has_label "$P" "Maintainer/Contribex Approved" && c_pass "S3 Maintainer/Contribex Approved set (/approve acted)" || c_fail "S3 Maintainer/Contribex Approved missing"

# Each command also RESPONDED (respond AND act): the /approve and /cncf-approve
# replies were previously dropped with no acknowledgement.
[ "$(bot_said "$P" 'Maintainer approval recorded')" -ge 1 ] && c_pass "S3 /approve responded" || c_fail "S3 no /approve response"
[ "$(bot_said "$P" 'CNCF admin approval granted')"  -ge 1 ] && c_pass "S3 /cncf-approve responded" || c_fail "S3 no /cncf-approve response"
[ "$(bot_said "$P" 'already recorded')"             -ge 1 ] && c_pass "S3 /confirm responded" || c_fail "S3 no /confirm response"

e2e_summary
