#!/usr/bin/env bash
#
# Shared harness for the LFX Mentorship intake e2e suite. SOURCE this from a
# scenario in test/e2e/scenarios/; it defines helpers and config defaults but NO
# side effects on its own (no cd, no trap, no gh calls), so the pure helpers can
# be unit-tested by lib.test.sh without touching GitHub.
#
# Most I/O helpers are extracted verbatim from the original scratch/e2e-*.sh
# scripts (deduplicated here). The novel part is the self-clean framework
# (e2e_init / e2e_preflight / e2e_cleanup / e2e_summary): a scenario tracks only
# the artifacts IT creates, tears down exactly those on any exit, and preflight
# asserts a clean slate rather than sweeping other tests' leftovers.
#
# A scenario's shape:
#   set -uo pipefail
#   source "$(dirname "$0")/../lib.sh"
#   TITLE_TAG="cleanup e2e <unique>"      # required: this test's disposable tag
#   PROPOSAL_BODY="$(dirname "$0")/../fixtures/<x>.md"
#   e2e_init                              # cd repo root, preflight, install trap
#   ... S1..Sn using check_*/wait_*/approve_proposal, e2e_track_issue "$N" ...
#   e2e_summary                           # prints result, exits non-zero on fail

# ---- config defaults (override via env or by setting before source) ----------
: "${REPO:=nate-double-u/mentoring}"                 # DEV fork; never a prod repo
# LFX_TERM, not TERM: the shell pre-sets TERM to the terminal type (e.g.
# xterm-256color), so a `${TERM:=...}` default would never apply.
: "${LFX_TERM:=2026 Term 3 (Sep-Nov)}"
: "${DEMO_PROJECT:=PVT_kwHOAEP2W84BXacI}"            # DEMO board (user project #7)
: "${STATUS_FIELD:=}"                                # required only by set_card
: "${EXPORT_BRANCH:=automation/lfx-export-2026-03-Sep-Nov}"
: "${URL_BRANCH:=automation/lfx-urls-2026-03-Sep-Nov}"
: "${EXPORT_JSON:=programs/lfx-mentorship/2026/03-Sep-Nov/lfx-export.json}"
: "${RETRIES:=${E2E_RETRIES:-90}}"                   # poll attempts, x5s each
: "${KEEP:=${E2E_KEEP:-}}"                            # E2E_KEEP=1 preserves artifacts
: "${FAILED:=0}"                                      # assertion failure counter
: "${E2E_ISSUES:=}"                                   # issues created this run
: "${E2E_BRANCHES:=}"                                 # PR head branches created this run
: "${E2E_PREFLIGHT_BRANCHES:=}"                       # branches preflight must find clean
: "${E2E_SNAP_DIR:=}"                                 # tmp dir holding the pre-scenario export snapshot
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

# ---- assertion framework (PURE; unit-tested by lib.test.sh) ------------------
c_pass(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; }
c_fail(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
step(){ printf '\n\033[1m== %s ==\033[0m \033[2m[%s]\033[0m\n' "$1" "$(date +%H:%M:%S)"; }
die(){ printf '\033[31mFATAL:\033[0m %s\n' "$1" >&2; exit 1; }
check_contains(){ case "$2" in *"$3"*) c_pass "$1";; *) c_fail "$1 (missing: $3)";; esac; }
check_absent(){ case "$2" in *"$3"*) c_fail "$1 (should NOT contain: $3)";; *) c_pass "$1";; esac; }
check_eq(){ [ "$2" = "$3" ] && c_pass "$1" || c_fail "$1 (want '$2' got '$3')"; }
# Lines strictly between a start and end marker (for PR-body section checks).
section(){ awk -v s="$2" -v e="$3" 'index($0,s){f=1;next} index($0,e){f=0} f' <<<"$1"; }

# ---- label helpers -----------------------------------------------------------
labels(){ gh issue view "$1" -R "$REPO" --json labels -q '.labels[].name'; }
has_label(){ labels "$1" | grep -Fxq "$2"; }
wait_label(){ local i; for i in $(seq 1 "$RETRIES"); do has_label "$1" "$2" && return 0; sleep 5; done; return 1; }
wait_no_label(){ local i; for i in $(seq 1 "$RETRIES"); do has_label "$1" "$2" || return 0; sleep 5; done; return 1; }

# ---- PR helpers --------------------------------------------------------------
open_pr_on(){ gh pr list -R "$REPO" --head "$1" --state open --json number -q '.[0].number' 2>/dev/null; }
wait_pr_on(){ local i n; for i in $(seq 1 "$RETRIES"); do n=$(open_pr_on "$1"); [ -n "$n" ] && { echo "$n"; return 0; }; sleep 5; done; return 1; }
wait_pr_title(){ local i n t; for i in $(seq 1 "$RETRIES"); do n=$(open_pr_on "$1"); if [ -n "$n" ]; then t=$(gh pr view "$n" -R "$REPO" --json title -q .title); case "$t" in *"$2"*) echo "$n"; return 0;; esac; fi; sleep 5; done; return 1; }
pr_title(){ gh pr view "$1" -R "$REPO" --json title -q .title; }
pr_body(){ gh pr view "$1" -R "$REPO" --json body -q .body; }
export_json_on(){ gh api "repos/$REPO/contents/$EXPORT_JSON?ref=$1" --jq '.content' | base64 -d; }
# The last commit on a PR, then a jq field from its full commit object (e.g.
# '.commit.author.name', '.commit.message') -- used to check PR provenance.
pr_last_commit_field(){ local sha; sha=$(gh pr view "$1" -R "$REPO" --json commits -q '.commits[-1].oid'); gh api "repos/$REPO/commits/$sha" --jq "$2"; }

# ---- workflow run helpers ----------------------------------------------------
latest_run(){ gh run list -R "$REPO" --workflow "$1" -L1 --json databaseId -q '.[0].databaseId' 2>/dev/null; }
# Wait for a run of workflow $1 NEWER than id $2 to reach 'completed'; echo its id.
# Lets a scenario assert on the effect of a dispatch without racing the notify/
# board steps (there is no positive signal to poll when a run touches nobody).
wait_new_run(){ local wf=$1 prev=$2 i now st; for i in $(seq 1 "$RETRIES"); do now=$(latest_run "$wf"); if [ -n "$now" ] && [ "$now" != "$prev" ]; then st=$(gh run view "$now" -R "$REPO" --json status -q .status 2>/dev/null); [ "$st" = completed ] && { echo "$now"; return 0; }; fi; sleep 5; done; return 1; }
# lfx-export.yml specializations of the two run helpers above.
latest_export_run(){ latest_run "lfx-export.yml"; }
wait_export_run_after(){ wait_new_run "lfx-export.yml" "$1" >/dev/null; }

# ---- comment / notification helpers ------------------------------------------
count_comments_with(){ gh issue view "$1" -R "$REPO" --json comments -q "[.comments[]|select(.body|contains(\"$2\"))]|length"; }
# Count of github-actions comments on issue $1 whose body contains substring $2.
bot_said(){ gh issue view "$1" -R "$REPO" --json comments -q "[.comments[]|select(.author.login==\"github-actions\" and (.body|contains(\"$2\")))]|length"; }
last_comment(){ gh issue view "$1" -R "$REPO" --json comments -q '.comments[-1].body'; }
# The latest comment whose body contains substring $2 (or the latest LFX
# validation comment). Pair wait_comment_with with comment_with to poll-then-read.
comment_with(){ gh issue view "$1" -R "$REPO" --json comments -q "[.comments[]|select(.body|contains(\"$2\"))][-1].body"; }
wait_comment_with(){ local i; for i in $(seq 1 "$RETRIES"); do [ "$(count_comments_with "$1" "$2")" -ge "${3:-1}" ] && return 0; sleep 5; done; return 1; }
val_comment(){ gh issue view "$1" -R "$REPO" --json comments -q '[.comments[]|select(.body|contains("LFX Proposal Validation"))][-1].body'; }
issue_body(){ gh issue view "$1" -R "$REPO" --json body -q .body; }
# Poll an issue body until it contains substring $2 (the /lfx-url body-pin edit
# is async).
wait_body_contains(){ local i b; for i in $(seq 1 "$RETRIES"); do b=$(issue_body "$1"); case "$b" in *"$2"*) return 0;; esac; sleep 5; done; return 1; }
notif_count(){ gh issue view "$1" -R "$REPO" --json comments -q '[.comments[]|select((.author.login=="github-actions") and (.body|contains("has been included in the")))]|length'; }
wait_notif_ge(){ local i c; for i in $(seq 1 "$RETRIES"); do c=$(notif_count "$1"); [ "${c:-0}" -ge "$2" ] && return 0; sleep 5; done; return 1; }

# ---- project board card helpers (owner/name derived from $REPO) --------------
card_id(){ gh api graphql -f query="query{repository(owner:\"$OWNER\",name:\"$NAME\"){issue(number:$1){projectItems(first:10){nodes{id project{id}}}}}}" --jq ".data.repository.issue.projectItems.nodes[]|select(.project.id==\"$DEMO_PROJECT\")|.id" 2>/dev/null; }
card_status(){ gh api graphql -f query="query{repository(owner:\"$OWNER\",name:\"$NAME\"){issue(number:$1){projectItems(first:10){nodes{project{id} fieldValueByName(name:\"Status\"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}}}" --jq ".data.repository.issue.projectItems.nodes[]|select(.project.id==\"$DEMO_PROJECT\")|.fieldValueByName.name" 2>/dev/null; }
wait_card(){ local i; for i in $(seq 1 "$RETRIES"); do [ "$(card_status "$1")" = "$2" ] && return 0; sleep 5; done; return 1; }
set_card(){ gh api graphql -f query="mutation{updateProjectV2ItemFieldValue(input:{projectId:\"$DEMO_PROJECT\",itemId:\"$1\",fieldId:\"$STATUS_FIELD\",value:{singleSelectOptionId:\"$2\"}}){projectV2Item{id}}}" >/dev/null; }
delete_card(){ gh api graphql -f query="mutation{deleteProjectV2Item(input:{projectId:\"$DEMO_PROJECT\",itemId:\"$1\"}){deletedItemId}}" >/dev/null 2>&1; }

# ---- approval ----------------------------------------------------------------
# Drive a proposal to CNCF Approved. /approve and /cncf-approve are separate
# comments so this works whether or not the target runs multiple commands per
# comment. Idempotent enough to re-approve after a material edit.
approve_proposal(){
  local n=$1
  wait_label "$n" "Validation Passed" || die "#$n never validated"
  wait_label "$n" "Mentors Confirmed" || die "#$n mentors not auto-confirmed"
  gh issue comment "$n" -R "$REPO" --body "/approve" >/dev/null
  wait_label "$n" "Maintainer/Contribex Approved" || die "#$n not maintainer-approved"
  gh issue comment "$n" -R "$REPO" --body "/cncf-approve" >/dev/null
  wait_label "$n" "CNCF Approved" || die "#$n not CNCF-approved"
}

# ---- self-clean framework ----------------------------------------------------
e2e_track_issue(){ E2E_ISSUES="$E2E_ISSUES $1"; }
e2e_track_branch(){ E2E_BRANCHES="$E2E_BRANCHES $1"; }

# Delete an issue's DEMO board card (if any) and close the issue.
close_disposable(){
  local n=$1 card
  card=$(card_id "$n")
  [ -n "$card" ] && delete_card "$card"
  gh issue close "$n" -R "$REPO" --comment "e2e teardown." >/dev/null 2>&1
}

# Closing an issue re-triggers board-sync to re-add its card; after a settle
# window, sweep those re-added cards. Used by both teardown and preflight-reset
# so neither path leaves a lingering card. Arg: whitespace-separated issue nums.
resweep_cards(){
  [ -n "$1" ] || return 0
  sleep 8
  local n card
  for n in $1; do
    card=$(card_id "$n")
    [ -n "$card" ] && delete_card "$card" && echo "  re-swept re-added card for #$n"
  done
}

# Assert this scenario left no footprint: no open issue carries its TITLE_TAG and
# no declared branch has an open PR. Fails LOUD if dirty so a human investigates;
# we never sweep other tests' leftovers. E2E_RESET=1 force-clears THIS test's own
# footprint instead of failing (escape hatch after a crashed run of this test).
e2e_preflight(){
  local leftover b pr dirty=""
  leftover=$(gh issue list -R "$REPO" --state open --search "\"$TITLE_TAG\" in:title" \
    --json number,title -q '.[]|select(.title|contains("'"$TITLE_TAG"'"))|.number')
  [ -n "$leftover" ] && dirty="$dirty issues:$(echo "$leftover" | tr '\n' ',')"
  for b in $E2E_PREFLIGHT_BRANCHES; do
    pr=$(open_pr_on "$b"); [ -n "$pr" ] && dirty="$dirty PR#$pr($b)"
  done
  [ -z "$dirty" ] && { c_pass "preflight: clean slate for '$TITLE_TAG'"; return 0; }
  if [ -n "${E2E_RESET:-}" ]; then
    step "Preflight RESET (E2E_RESET set): clearing THIS test's own leftovers"
    for b in $E2E_PREFLIGHT_BRANCHES; do pr=$(open_pr_on "$b"); [ -n "$pr" ] && gh pr close "$pr" -R "$REPO" --delete-branch >/dev/null 2>&1; done
    for pr in $leftover; do echo "  closing leftover #$pr"; close_disposable "$pr"; done
    resweep_cards "$leftover"
    c_pass "preflight: reset clean slate for '$TITLE_TAG'"
    return 0
  fi
  die "preflight: dirty slate for '$TITLE_TAG':$dirty  (clean up by hand, or re-run with E2E_RESET=1)"
}

# ---- export-file baseline snapshot/restore (isolation) -----------------------
# The term export never drops programs (#2015) and scenarios share one term, so a
# scenario's merged programs -- and their recorded-URL comments -- would leak into
# the next scenario's /lfx-url run. Snapshot the term's export files from main at
# preflight; restore them at teardown so main returns to its pre-scenario baseline.
# Uses the Contents API (a direct commit to main, no PR): only lfx-automation-tests
# reacts to a push, and merely re-runs unit tests.
e2e_snapshot_exports(){
  local dir="${EXPORT_JSON%/*}" name f b64
  E2E_SNAP_DIR=$(mktemp -d)
  for name in lfx-export.json README.md lfx-tracking.csv; do
    f="$dir/$name"
    if b64=$(gh api "repos/$REPO/contents/$f" -q '.content' 2>/dev/null); then
      printf '%s' "$b64" | base64 -d > "$E2E_SNAP_DIR/$name" 2>/dev/null || : > "$E2E_SNAP_DIR/$name"
    else
      : > "$E2E_SNAP_DIR/$name.absent"
    fi
  done
}

e2e_restore_exports(){
  [ -n "${E2E_SNAP_DIR:-}" ] && [ -d "$E2E_SNAP_DIR" ] || return 0
  # Request bodies are built with jq --rawfile + gh api --input (never a shell
  # arg), so a large lfx-export.json can't blow ARG_MAX.
  local dir="${EXPORT_JSON%/*}" name f resp cur_sha
  local cur="$E2E_SNAP_DIR/.cur" b64="$E2E_SNAP_DIR/.b64" body="$E2E_SNAP_DIR/.body"
  for name in lfx-export.json README.md lfx-tracking.csv; do
    f="$dir/$name"
    resp=$(gh api "repos/$REPO/contents/$f" 2>/dev/null) || resp=""
    cur_sha=$(printf '%s' "$resp" | jq -r '.sha // empty' 2>/dev/null)
    printf '%s' "$resp" | jq -r '.content // empty' 2>/dev/null | base64 -d > "$cur" 2>/dev/null || : > "$cur"
    if [ -f "$E2E_SNAP_DIR/$name" ]; then
      if [ -n "$cur_sha" ] && ! cmp -s "$E2E_SNAP_DIR/$name" "$cur"; then
        base64 < "$E2E_SNAP_DIR/$name" | tr -d '\n' > "$b64"
        jq -n --arg m "e2e teardown: restore $name to pre-scenario baseline" \
              --rawfile c "$b64" --arg s "$cur_sha" \
              '{message:$m, content:$c, sha:$s, branch:"main"}' > "$body"
        gh api --method PUT "repos/$REPO/contents/$f" --input "$body" >/dev/null 2>&1 \
          && echo "  restored $name to baseline"
      fi
    elif [ -f "$E2E_SNAP_DIR/$name.absent" ] && [ -n "$cur_sha" ]; then
      jq -n --arg m "e2e teardown: remove $name created during test" --arg s "$cur_sha" \
            '{message:$m, sha:$s, branch:"main"}' > "$body"
      gh api --method DELETE "repos/$REPO/contents/$f" --input "$body" >/dev/null 2>&1 \
        && echo "  removed test-created $name"
    fi
  done
  rm -f "$cur" "$b64" "$body"; rm -rf "$E2E_SNAP_DIR"; E2E_SNAP_DIR=""
}

# Tear down exactly what THIS run created, on any exit (success/failure/interrupt).
# Closes tracked PRs+branches, closes tracked issues and deletes their board
# cards, then re-sweeps the cards that board-sync re-adds on close.
e2e_cleanup(){
  [ -n "$KEEP" ] && { printf '\n\033[1m== Teardown skipped (E2E_KEEP set) ==\033[0m\n  issues:%s branches:%s\n' "$E2E_ISSUES" "$E2E_BRANCHES"; [ -n "${E2E_SNAP_DIR:-}" ] && rm -rf "$E2E_SNAP_DIR"; return; }
  printf '\n\033[1m== Teardown (this run only) ==\033[0m\n'
  local n b pr card
  for b in $E2E_BRANCHES; do
    pr=$(open_pr_on "$b"); [ -n "$pr" ] && { echo "  closing PR #$pr ($b)"; gh pr close "$pr" -R "$REPO" --delete-branch >/dev/null 2>&1; }
  done
  for n in $E2E_ISSUES; do echo "  tearing down #$n"; close_disposable "$n"; done
  resweep_cards "$E2E_ISSUES"
  e2e_restore_exports
  echo "  teardown complete"
}

# Fail loud if any OTHER proposal is open and CNCF-Approved, which would pollute
# an export run's program counts. Export/board scenarios call this in setup; on a
# clean dev fork there should be none.
assert_no_open_approved(){
  local stray
  stray=$(gh issue list -R "$REPO" --state open --label "CNCF Approved" --json number -q '.[].number' | tr '\n' ' ')
  [ -z "$stray" ] && { c_pass "no stray open CNCF-Approved proposals"; return 0; }
  die "preflight: unexpected open CNCF-Approved proposal(s): $stray -- investigate before running"
}

# cd to the repo root, assert a clean slate, and arm the teardown trap. Call once
# at the top of a scenario, after setting TITLE_TAG.
e2e_init(){
  [ -n "${TITLE_TAG:-}" ] || die "e2e_init: scenario must set TITLE_TAG before calling e2e_init"
  case "$REPO" in
    cncf/*) die "refusing to run e2e against prod repo '$REPO' -- REPO must be the dev fork";;
  esac
  cd "$(git -C "$(dirname "${BASH_SOURCE[1]}")" rev-parse --show-toplevel)" || die "not in a git repo"
  step "Phase 0 preflight"
  e2e_preflight
  e2e_snapshot_exports
  trap e2e_cleanup EXIT
}

# Print the run summary and exit non-zero if any check failed.
e2e_summary(){
  step "SUMMARY"
  echo "  issues this run:${E2E_ISSUES:-  none}  branches:${E2E_BRANCHES:-  none}"
  echo "  the EXIT trap tears them down (set E2E_KEEP=1 to keep)"
  if [ "$FAILED" -eq 0 ]; then printf '\033[32mALL CHECKS PASSED\033[0m\n'; else printf '\033[31mSOME CHECKS FAILED\033[0m\n'; exit 1; fi
}
