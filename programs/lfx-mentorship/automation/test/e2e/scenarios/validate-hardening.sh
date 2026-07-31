#!/usr/bin/env bash
#
# Scenario: proposal validation hardening (cncf/mentoring#2009, #1987, #1928).
# The check logic is unit-tested in lib/validate.js + lib/parse.js; this proves
# the workflow wiring in lfx-proposal-validate.yml against the live dev fork.
#
#   Issue A — Coding Challenge URL (#2009), one issue edited in place:
#     S1  Coding Challenge checked, URL empty    -> Validation Failed (URL required)
#     S2  Coding Challenge checked, URL provided  -> Validation Passed (URL: provided)
#     S3  Coding Challenge unchecked, URL present -> Validation Failed (unchecked-with-url)
#   Issue B — mailto mentor email (#1987):
#     S4  mentor email is a Markdown mailto link  -> Validation Passed (email accepted)
#   Issue C — missing template section (#1928):
#     S5  a template section (Technologies) removed -> Validation Failed (missing section)
#
# Each issue uses a distinct Upstream Issue URL so the duplicate-upstream warning
# never fires between them (same pattern as the export scenarios).
#
# Run:  bash programs/lfx-mentorship/automation/test/e2e/scenarios/validate-hardening.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

TITLE_TAG="cleanup e2e valhard"
FX="$HERE/../fixtures"
CC_MISSING="$FX/cc-missing-url.md"
CC_URL="$FX/cc-with-url.md"
CC_UNCHECKED="$FX/cc-unchecked-with-url.md"
MAILTO="$FX/mentor-mailto.md"
MISSING="$FX/missing-section.md"
for f in "$CC_MISSING" "$CC_URL" "$CC_UNCHECKED" "$MAILTO" "$MISSING"; do
  [ -f "$f" ] || die "missing fixture: $f"
done
e2e_init

mk(){ gh issue create -R "$REPO" --title "[CNCF LFX Proposal] $TITLE_TAG (disposable test)" --body-file "$1" | grep -oE '[0-9]+$'; }

# ---- Issue A: Coding Challenge URL (#2009), edited in place ------------------
step "S1 Coding Challenge checked but URL empty (expect Validation Failed)"
A=$(mk "$CC_MISSING"); [ -n "$A" ] || die "could not create proposal A"
e2e_track_issue "$A"; echo "  proposal A = #$A"
wait_label "$A" "Validation Failed" || die "#$A never reached Validation Failed"
has_label "$A" "Validation Passed" && c_fail "S1 Validation Passed should be absent" || c_pass "S1 Validation Failed set, Passed absent"
V1=$(val_comment "$A")
check_contains "S1-MSG requires the challenge URL" "$V1" 'You selected "Coding Challenge" as a prerequisite, but the Coding Challenge URL is empty.'

step "S2 Coding Challenge checked with a valid URL (expect Validation Passed)"
gh issue edit "$A" -R "$REPO" --body-file "$CC_URL" >/dev/null || die "could not edit A to cc-with-url"
wait_label "$A" "Validation Passed" || die "#$A never flipped to Validation Passed"
has_label "$A" "Validation Failed" && c_fail "S2 Validation Failed should be cleared" || c_pass "S2 Validation Passed set, Failed cleared"
V2=$(val_comment "$A")
check_contains "S2-MSG coding challenge URL provided" "$V2" "Coding Challenge URL: provided"
check_absent   "S2-MSG no url-missing error"          "$V2" "Coding Challenge URL is empty"

step "S3 Coding Challenge unchecked but URL still filled (expect Validation Failed)"
gh issue edit "$A" -R "$REPO" --body-file "$CC_UNCHECKED" >/dev/null || die "could not edit A to cc-unchecked-with-url"
for i in $(seq 1 "$RETRIES"); do has_label "$A" "Validation Failed" && ! has_label "$A" "Validation Passed" && break; sleep 5; done
has_label "$A" "Validation Failed" || die "#$A never flipped back to Validation Failed after S3"
V3=$(val_comment "$A")
check_contains "S3-MSG flags URL with unchecked box" "$V3" "A Coding Challenge URL is filled in, but the Coding Challenge box is"

# ---- Issue B: mailto mentor email (#1987) -----------------------------------
step "S4 mentor email is a Markdown mailto autolink (expect Validation Passed)"
B=$(mk "$MAILTO"); [ -n "$B" ] || die "could not create proposal B"
e2e_track_issue "$B"; echo "  proposal B = #$B"
wait_label "$B" "Validation Passed" || die "#$B never reached Validation Passed (mailto email should be accepted)"
has_label "$B" "Validation Failed" && c_fail "S4 Validation Failed should be absent" || c_pass "S4 Validation Passed set, Failed absent"
V4=$(val_comment "$B")
check_contains "S4-MSG all checks passed"      "$V4" "All checks passed"
check_absent   "S4-MSG no email-format error"  "$V4" "doesn't look valid"

# ---- Issue C: missing template section (#1928) ------------------------------
step "S5 a template section removed (expect Validation Failed)"
C=$(mk "$MISSING"); [ -n "$C" ] || die "could not create proposal C"
e2e_track_issue "$C"; echo "  proposal C = #$C"
wait_label "$C" "Validation Failed" || die "#$C never reached Validation Failed (missing section should fail)"
V5=$(val_comment "$C")
check_contains "S5-MSG names the missing section" "$V5" "missing required template section(s): **Technologies**"
check_contains "S5-MSG advises re-submitting"     "$V5" "instead of removing sections"

e2e_summary
