#!/usr/bin/env bash
#
# Last cleanup, run from an always() step after the job has settled.
#
# This exists even though the finalization step already traps ERR, INT and
# TERM since no trap survives a job cancellation or the job timeout.
# The runner kills the step process. Those are exactly the cases that leave
# a half finalized draft behind. A step with always() still runs after a
# cancelled job, so this is the only place that can clean up after one.
#
# Best effort by design: this must never turn a clean failure into a confusing
# one, so it does not use errexit and always exits 0.
#
# Required environment:
#   LABEL              Release tag of the run that failed.
#   RELEASE_ID         Numeric release ID, when the run got far enough to know.
#   MODE               publish | verify, when the run got far enough to decide.
#   HANDOFF_NAME       Handoff archive asset name (also read by the rollback).
#   TAR_NAME           Public archive asset name (also read by the rollback).
#   TAG_CREATED        true when this run created refs/tags/<label>.
#   JOB_STATUS         GitHub's job.status for this run.
#   GITHUB_REPOSITORY, GITHUB_WORKSPACE, RUNNER_TEMP
#   GH_TOKEN           Token used by the GitHub CLI.

set -uo pipefail

: "${JOB_STATUS:?JOB_STATUS is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

# Every variable below may legitimately be empty or unset: the run can fail
# before the steps that set them, and this script still has to reach a
# decision rather than abort under `set -u`.
LABEL="${LABEL:-}"
RELEASE_ID="${RELEASE_ID:-}"
MODE="${MODE:-}"
TAG_CREATED="${TAG_CREATED:-}"
# Read by rollback-staging-assets.sh from the environment, and by the recovery
# message below.
HANDOFF_NAME="${HANDOFF_NAME:-}"
TAR_NAME="${TAR_NAME:-}"

script_dir="$(dirname "${BASH_SOURCE[0]}")"

if [[ "$JOB_STATUS" == "success" ]]; then
  exit 0
fi

# Verify-only runs never mutate anything.
if [[ "$MODE" != "publish" ]]; then
  exit 0
fi

# This run leaves behind at most two things, and they are created at different
# points, so they are undone independently:
#
# 1. Draft edits when replacing the staging assets.
# 2. Created tag label
if [[ ! -f "$RUNNER_TEMP/finalization-started" && "$TAG_CREATED" != "true" ]]; then
  echo "This run neither modified the draft nor created a tag; nothing to undo."
  exit 0
fi

# If the release already went out there is nothing to roll back and nothing to
# delete: publication is irreversible, and the tag is part of what was
# published. The run failed somewhere in the post-publication verification, so
# the recovery is to run the workflow again, which resolves mode=verify and
# re-checks the public artifacts.
current_release="$(gh api \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}" 2>/dev/null)"
if [[ -n "$current_release" &&
  "$(jq -r '.draft' <<<"$current_release")" == "false" ]]; then
  echo "Release $LABEL is already published and cannot be rolled back."
  echo "Re-run this workflow for $LABEL: it will verify the published release."
  exit 0
fi

# 1. Undo the draft edits, if this run got as far as making any.
#
# Running the rollback twice is harmless: it deletes the final-only assets if
# present and re-uploads the staging pair with --clobber, so it converges
# whether or not the in-step trap already ran. It also refuses outright if the
# release is no longer a mutable draft.
if [[ -f "$RUNNER_TEMP/finalization-started" ]]; then
  if bash "$script_dir/rollback-staging-assets.sh"; then
    echo "The original staging draft was restored."
  else
    echo "The staging rollback failed. Recover by hand:" >&2
    echo "  gh release download '$LABEL' --repo '$GITHUB_REPOSITORY' --pattern '$HANDOFF_NAME'" >&2
    echo "  gh release delete '$LABEL' --repo '$GITHUB_REPOSITORY' --yes" >&2
    echo "  gh api --method DELETE repos/$GITHUB_REPOSITORY/git/refs/tags/$LABEL" >&2
    echo "Then re-stage the draft from the private release workflow." >&2
  fi
else
  echo "The draft was never modified by this run; nothing to restore."
fi

# 2. Remove a tag this run created but never published.
#
# Deliberately not conditional on the rollback having succeeded. The tag and
# the draft are separate pieces of leftover state, and a failed rollback is a
# reason to remove the tag too, not a reason to keep it: the by-hand runbook
# printed above ends with exactly this delete. The only thing that must stop
# it is the release having been published, which the .draft re-read below
# checks against the current state rather than the state read earlier.
if [[ "$TAG_CREATED" == "true" ]]; then
  release_json="$(gh api \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}" 2>/dev/null)"
  if [[ -z "$release_json" ]]; then
    echo "Could not read release $RELEASE_ID; leaving the tag $LABEL in place." >&2
    echo "Delete it before releasing a corrected ledger commit:" >&2
    echo "  gh api --method DELETE repos/$GITHUB_REPOSITORY/git/refs/tags/$LABEL" >&2
  elif [[ "$(jq -r '.draft' <<<"$release_json")" != "true" ]]; then
    echo "Release $LABEL is no longer a draft; keeping the tag."
  elif gh api \
    --method DELETE \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/${GITHUB_REPOSITORY}/git/refs/tags/${LABEL}" \
    >/dev/null 2>&1; then
    echo "Removed the tag $LABEL that this run created."
  else
    echo "Could not remove the tag $LABEL that this run created." >&2
    echo "Delete it before releasing a corrected ledger commit:" >&2
    echo "  gh api --method DELETE repos/$GITHUB_REPOSITORY/git/refs/tags/$LABEL" >&2
  fi
fi

exit 0
