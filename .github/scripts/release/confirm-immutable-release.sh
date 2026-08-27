#!/usr/bin/env bash
#
# Confirm that the published release is immutable, bound to the reviewed
# ledger commit, and covered by both attestation chains.
#
# This runs on both paths and is the reason mode=verify can exist at all: it
# reads only from the published release plus release-assets/, so it does not
# care whether this run published those assets or downloaded them back.
#
# Both waits below poll rather than failing immediately, because GitHub
# populates the immutable flag and the release attestation asynchronously after
# publication. Those two waits are the most likely place for a run to die, and
# the reason a re-run must be able to reach mode=verify.
#
# Required environment:
#   LABEL                  Published release tag.
#   TAR_NAME               Public archive asset name.
#   IS_PRERELEASE          true|false, derived from the label.
#   TAG_COMMIT_SHA         Commit the tag must name.
#   PUBLIC_PREDICATE_TYPE  Workflow attestation predicate type.
#   GITHUB_REPOSITORY, GITHUB_SHA
#   GITHUB_WORKSPACE       Checked-out repository root.
#   GH_TOKEN               Token used by the GitHub CLI.

set -euo pipefail

: "${LABEL:?LABEL is required}"
: "${TAR_NAME:?TAR_NAME is required}"
: "${IS_PRERELEASE:?IS_PRERELEASE is required}"
: "${TAG_COMMIT_SHA:?TAG_COMMIT_SHA is required}"
: "${PUBLIC_PREDICATE_TYPE:?PUBLIC_PREDICATE_TYPE is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

# shellcheck source=.github/scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$GITHUB_WORKSPACE"

log_section "Confirming the immutable release"
log_field "release" "$LABEL"
log_field "repository" "$GITHUB_REPOSITORY"
log_field "expected tag commit" "$TAG_COMMIT_SHA"
log_field "this run is at" "$GITHUB_SHA"
log_field "expected prerelease" "$IS_PRERELEASE"
log_field "archive asset" "$TAR_NAME"
log_field "workflow predicate type" "$PUBLIC_PREDICATE_TYPE"

# Assert immutable release
log_section "Waiting for GitHub to mark the release immutable"
immutable=false
for attempt in {1..15}; do
  release_json="$(gh_retry gh api \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/${GITHUB_REPOSITORY}/releases/tags/${LABEL}")"
  immutable="$(jq -r '.immutable // false' <<<"$release_json")"
  if [[ "$immutable" == "true" ]]; then
    log_ok "GitHub reports the release immutable (poll $attempt of 15)."
    break
  fi
  if (( attempt < 15 )); then
    log_note "Not immutable yet; retrying in 5s ($attempt/15)."
    sleep 5
  fi
done

log_field "release id" "$(jq -r '.id' <<<"$release_json")"
log_field "immutable" "$immutable"
log_field "draft" "$(jq -r '.draft' <<<"$release_json")"
log_field "prerelease" "$(jq -r '.prerelease' <<<"$release_json")"
log_field "published at" "$(jq -r '.published_at // "unknown"' <<<"$release_json")"
log_field "release url" "$(jq -r '.html_url // "unknown"' <<<"$release_json")"
if [[ "$immutable" != "true" ||
  "$(jq -r '.draft' <<<"$release_json")" != "false" ||
  "$(jq -r '.prerelease' <<<"$release_json")" != "$IS_PRERELEASE" ]]; then
  echo "The published release did not reach the expected immutable state." >&2
  echo "  expected immutable=true draft=false prerelease=$IS_PRERELEASE" >&2
  echo "  found    immutable=$immutable" \
    "draft=$(jq -r '.draft' <<<"$release_json")" \
    "prerelease=$(jq -r '.prerelease' <<<"$release_json")" >&2
  exit 1
fi
log_ok "The release is immutable, published, and correctly flagged."

log_section "Immutable release asset set"
expected_assets="$(printf '%s\n' \
  jibril "$TAR_NAME" SHA256SUMS | LC_ALL=C sort)"
actual_assets="$(jq -r '.assets[].name' \
  <<<"$release_json" | LC_ALL=C sort)"
while IFS= read -r asset_line; do
  log_note "$asset_line"
done <<<"$actual_assets"
if [[ "$actual_assets" != "$expected_assets" ]]; then
  echo "The immutable release has an unexpected asset set." >&2
  diff -u \
    <(printf '%s\n' "$expected_assets") \
    <(printf '%s\n' "$actual_assets") >&2 || true
  exit 1
fi
log_ok "The release carries exactly the three expected assets."

# Assert the immutable tag references the ledger commit.
log_section "Tag binding"
tag_commit="$(gh_retry gh api \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/${GITHUB_REPOSITORY}/commits/${LABEL}" \
  --jq '.sha')"
log_field "tag $LABEL names" "$tag_commit"
log_field "tag step bound it to" "$TAG_COMMIT_SHA"
log_field "this run is at" "$GITHUB_SHA"
# Both comparisons are deliberate: the tag must equal the commit the run bound
# it to *and* the commit the run itself is pinned to. shellcheck reads an ||
# between two != tests as always-true, which it would be for two unrelated
# values; here the point is to reject the case where those two are not the same
# commit, so the disjunction is what is wanted.
# shellcheck disable=SC2055
if [[ "$tag_commit" != "$TAG_COMMIT_SHA" ||
  "$tag_commit" != "$GITHUB_SHA" ]]; then
  echo "The immutable tag does not name the reviewed ledger commit." >&2
  exit 1
fi
log_ok "The immutable tag, the tag binding, and this run all name one commit."

# Assert assets against GitHub's automatic immutable-release attestation.
log_section "GitHub immutable-release attestation"
verified=false
for attempt in {1..30}; do
  assets_verified=true
  if ! gh release verify "$LABEL" --repo "$GITHUB_REPOSITORY"; then
    assets_verified=false
  else
    for asset_name in jibril "$TAR_NAME" SHA256SUMS; do
      if ! gh release verify-asset "$LABEL" \
        "release-assets/$asset_name" \
        --repo "$GITHUB_REPOSITORY"; then
        assets_verified=false
        log_note "Asset $asset_name is not attested yet."
        break
      fi
    done
  fi

  if [[ "$assets_verified" == "true" ]]; then
    verified=true
    log_ok "Release and all three assets verified against GitHub's immutable-release attestation (poll $attempt of 30)."
    break
  fi
  if (( attempt < 30 )); then
    log_note "Attestation is not ready; retrying in 10s ($attempt/30)."
    sleep 10
  fi
done
if [[ "$verified" != "true" ]]; then
  echo "The immutable release or one of its assets could not be verified." >&2
  exit 1
fi

# Assert that every release asset is attested by the workflow.
log_section "Workflow attestation"
log_field "predicate type" "$PUBLIC_PREDICATE_TYPE"
for subject in \
  release-assets/jibril \
  "release-assets/$TAR_NAME" \
  release-assets/SHA256SUMS; do
  gh attestation verify "$subject" \
    --repo "$GITHUB_REPOSITORY" \
    --predicate-type "$PUBLIC_PREDICATE_TYPE"
  log_ok "$subject is attested by this workflow."
done

log_section "Immutable release confirmed"
log_field "release" "$LABEL"
log_field "ledger commit" "$tag_commit"
log_field "prerelease" "$IS_PRERELEASE"
log_field "assets" "jibril, $TAR_NAME, SHA256SUMS"
log_note "Both attestation chains verified: GitHub's immutable-release"
log_note "attestation and this workflow's $PUBLIC_PREDICATE_TYPE predicate."
