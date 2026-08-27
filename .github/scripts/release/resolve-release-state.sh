#!/usr/bin/env bash
#
# Decide what this release run is: promote a staged draft, or verify a release
# that is already published.
#
# The answer is written to GITHUB_OUTPUT as:
#
#   mode        publish | verify
#   releaseId   numeric release ID the rest of the run operates on
#   tagExists   true when refs/tags/<label> is already present
#
# mode=publish is the normal path. mode=verify exists because publication makes
# a GitHub release immutable: once the publish call lands there is nothing left
# to change, nothing a maintainer could delete and redo, and the only correct
# thing a re-run can do is prove that what is public matches the reviewed
# ledger. Without it a run that died in the post-publication attestation poll
# could never reach a green state again, because the draft lookup below only
# considers releases with draft == true and there is no longer a draft.
#
# Required environment:
#   LABEL                     Release tag being published.
#   HANDOFF_NAME              Handoff archive asset name.
#   EXPECTED_DRAFT_AUTHOR_ID  Numeric user ID that must own the draft.
#   GITHUB_REPOSITORY         Target repository in OWNER/REPO form.
#   GITHUB_SHA                Reviewed ledger commit this run is pinned to.
#   GITHUB_OUTPUT             GitHub Actions step-output file.
#   GH_TOKEN                  Token used by the GitHub CLI.

set -euo pipefail

: "${LABEL:?LABEL is required}"
: "${HANDOFF_NAME:?HANDOFF_NAME is required}"
: "${EXPECTED_DRAFT_AUTHOR_ID:?EXPECTED_DRAFT_AUTHOR_ID is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

# shellcheck source=.github/scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# mode=verify
#
# The release-by-tag endpoint never returns drafts, so a hit here is
# unambiguously a published release.
published_lookup=0
published_json="$(gh_api_optional \
  "repos/${GITHUB_REPOSITORY}/releases/tags/${LABEL}")" || published_lookup=$?
if (( published_lookup == 1 )); then
  echo "Could not determine whether $LABEL is already published." >&2
  exit 1
fi

if (( published_lookup == 0 )); then
  published_id="$(jq -r '.id' <<<"$published_json")"
  if [[ ! "$published_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "The published release for $LABEL has an invalid release ID." >&2
    exit 1
  fi
  echo "Release $LABEL is already published (id $published_id)."
  echo "Nothing can be changed on an immutable release; verifying it instead."
  {
    echo "mode=verify"
    echo "releaseId=$published_id"
    echo "tagExists=true"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

# mode=publish: promote the draft staged by the private repository.
if ! release_pages="$(gh_retry gh api \
    --paginate \
    --slurp \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/${GITHUB_REPOSITORY}/releases?per_page=100")"; then
  echo "Failed to list releases in $GITHUB_REPOSITORY." >&2
  exit 1
fi

draft_matches="$(jq -c --arg label "$LABEL" \
  '[.[][] | select(.draft == true and .tag_name == $label)]' \
  <<<"$release_pages")"
draft_count="$(jq -r 'length' <<<"$draft_matches")"
if [[ "$draft_count" -eq 0 ]]; then
  echo "No authenticated draft release has tag_name '$LABEL'." >&2
  exit 1
fi
if [[ "$draft_count" -ne 1 ]]; then
  echo "Expected one draft for '$LABEL', found $draft_count." >&2
  exit 1
fi

release_json="$(jq -c '.[0]' <<<"$draft_matches")"
release_id="$(jq -r '.id' <<<"$release_json")"
if [[ ! "$release_id" =~ ^[1-9][0-9]*$ ]]; then
  echo "The selected draft has an invalid release ID." >&2
  exit 1
fi

if [[ "$(jq -r '.draft' <<<"$release_json")" != "true" ||
  "$(jq -r '.tag_name' <<<"$release_json")" != "$LABEL" ]]; then
  echo "Release $LABEL is not the expected draft." >&2
  exit 1
fi

draft_author_id="$(jq -r '.author.id' <<<"$release_json")"
if [[ "$draft_author_id" != "$EXPECTED_DRAFT_AUTHOR_ID" ]]; then
  echo "The draft was not created by the trusted private-release owner." >&2
  exit 1
fi

# The draft must be exactly as the private repository staged it.
#
# This workflow deliberately does not repair a draft it finds in some other
# shape. Recovery is a human decision: delete the draft and re-stage it, so
# that every run starts from a draft the trusted dispatcher created. The
# message below is the runbook, printed at the moment it is needed.
expected_assets="$(printf '%s\n' \
  "$HANDOFF_NAME" \
  "$HANDOFF_NAME.SHA256SUM" | LC_ALL=C sort)"
actual_assets="$(jq -r '.assets[].name' \
  <<<"$release_json" | LC_ALL=C sort)"
if [[ "$actual_assets" != "$expected_assets" ]]; then
  echo "The draft must contain exactly the handoff and its staging sidecar." >&2
  diff -u \
    <(printf '%s\n' "$expected_assets") \
    <(printf '%s\n' "$actual_assets") || true
  echo >&2
  echo "This draft holds leftovers from an interrupted run. To recover:" >&2
  echo "  1. Save the handoff if it is still attached, so the private repository" >&2
  echo "     does not have to rebuild it:" >&2
  echo "       gh release download '$LABEL' --repo '$GITHUB_REPOSITORY' --pattern '$HANDOFF_NAME'" >&2
  echo "  2. Delete the draft and the tag this workflow may have created:" >&2
  echo "       gh release delete '$LABEL' --repo '$GITHUB_REPOSITORY' --yes" >&2
  echo "       gh api --method DELETE repos/$GITHUB_REPOSITORY/git/refs/tags/$LABEL" >&2
  echo "  3. Re-stage the draft from the private release workflow, then run this again." >&2
  exit 1
fi

# Accept an existing tag only when it already names this exact reviewed
# ledger commit; otherwise the tag is created later in the run.
tag_lookup=0
gh_api_optional \
  "repos/${GITHUB_REPOSITORY}/git/ref/tags/${LABEL}" \
  >/dev/null || tag_lookup=$?
if (( tag_lookup == 1 )); then
  echo "Could not determine whether tag $LABEL already exists." >&2
  exit 1
fi

tag_exists=false
if (( tag_lookup == 0 )); then
  tag_exists=true
  tag_commit="$(gh_retry gh api \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/${GITHUB_REPOSITORY}/commits/${LABEL}" \
    --jq '.sha')"
  if [[ "$tag_commit" != "$GITHUB_SHA" ]]; then
    echo "Error: existing tag $LABEL does not point to the reviewed ledger commit." >&2
    echo "Expected $GITHUB_SHA, found $tag_commit." >&2
    echo "If a previous failed run left this tag behind, delete it and run again:" >&2
    echo "  gh api --method DELETE repos/${GITHUB_REPOSITORY}/git/refs/tags/${LABEL}" >&2
    exit 1
  fi
fi

{
  echo "mode=publish"
  echo "releaseId=$release_id"
  echo "tagExists=$tag_exists"
} >> "$GITHUB_OUTPUT"
