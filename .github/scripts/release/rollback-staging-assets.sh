#!/usr/bin/env bash

# Restore a partially modified draft release to its original staging state.
#
# Required environment variables:
#   LABEL              Release tag being finalized.
#   RELEASE_ID         Numeric ID of the draft release being finalized.
#   HANDOFF_NAME       Original handoff archive asset name.
#   TAR_NAME           Final public TAR asset name.
#   GITHUB_REPOSITORY  Target repository in OWNER/REPO form.
#   GH_TOKEN           Token used by the GitHub CLI.
#   GITHUB_WORKSPACE   Checked-out repository root.

# Rollback is best-effort, so commands are checked explicitly instead of using
# errexit. This script runs in a separate Bash process and cannot change the
# workflow step's shell options.
set +e
set -uo pipefail

: "${LABEL:?LABEL is required}"
: "${RELEASE_ID:?RELEASE_ID is required}"
: "${HANDOFF_NAME:?HANDOFF_NAME is required}"
: "${TAR_NAME:?TAR_NAME is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"

if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "Rollback failed: GitHub CLI or jq is unavailable." >&2
  exit 1
fi

if [[ ! "$RELEASE_ID" =~ ^[1-9][0-9]*$ ]]; then
  echo "Rollback failed: invalid draft release ID: $RELEASE_ID" >&2
  exit 1
fi

# Re-validate the label here rather than trusting the caller.
if [[ ! "$LABEL" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
  echo "Rollback failed: invalid SemVer release label: $LABEL" >&2
  exit 1
fi

# Load helpers
release_lib="$GITHUB_WORKSPACE/.github/scripts/release/common.sh"
if [[ ! -f "$release_lib" || -L "$release_lib" ]] ||
  ! git -C "$GITHUB_WORKSPACE" ls-files --error-unmatch -- "$release_lib" >/dev/null 2>&1 ||
  ! git -C "$GITHUB_WORKSPACE" diff --quiet -- "$release_lib"; then
  echo "Rollback failed: the shared release library is missing, unsafe, or modified." >&2
  exit 1
fi
# shellcheck source=.github/scripts/release/common.sh
source "$release_lib"

draft_inputs_dir="$GITHUB_WORKSPACE/draft-inputs"
handoff_path="$draft_inputs_dir/$HANDOFF_NAME"
checksums_path="$draft_inputs_dir/$HANDOFF_NAME.SHA256SUM"

# Never upload missing files or follow a replaced staging-file symlink.
for staging_path in "$handoff_path" "$checksums_path"; do
  if [[ ! -f "$staging_path" || -L "$staging_path" ]]; then
    echo "Rollback failed: invalid staging file: $staging_path" >&2
    exit 1
  fi
done

echo "Finalization failed; attempting to restore the staging draft." >&2

# Draft releases are resolved by their numeric ID. The release-by-tag endpoint
# is for published releases.
release_json="$(gh_retry gh api \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}")"
command_status=$?

if (( command_status != 0 )); then
  echo "Rollback failed: could not read release ID $RELEASE_ID." >&2
  exit 1
fi

if [[ "$(jq -r '.draft' <<<"$release_json")" != "true" ||
  "$(jq -r '.immutable // false' <<<"$release_json")" != "false" ||
  "$(jq -r '.tag_name' <<<"$release_json")" != "$LABEL" ]]; then
  echo "Rollback refused: release ID $RELEASE_ID is not the mutable draft for $LABEL." >&2
  exit 1
fi

# Remove only the final-only assets. Missing assets are acceptable because the
# failure may have happened before either upload completed, and gh_delete_asset
# already reports absence as success. A delete that genuinely fails must not
# abort the rollback here: the restore below still has to run, and the
# expected-asset check at the end is what decides whether it worked.
for asset_name in jibril "$TAR_NAME"; do
  gh_delete_asset "$RELEASE_ID" "$asset_name" || true
done

rollback_status=0

# Restore or replace the original staging assets from the validated local copy.
if ! gh_retry gh release upload "$LABEL" \
  "$handoff_path" \
  "$checksums_path" \
  --repo "$GITHUB_REPOSITORY" \
  --clobber >/dev/null 2>&1; then
  echo "Rollback failed: could not restore the staging assets." >&2
  rollback_status=1
fi

# Success requires the draft to contain exactly the original two assets.
expected_assets="$(printf '%s\n' \
  "$HANDOFF_NAME" "$HANDOFF_NAME.SHA256SUM" | LC_ALL=C sort)"
final_release_json="$(gh_retry gh api \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}")"
command_status=$?

if (( command_status != 0 )); then
  echo "Rollback failed: could not re-read release ID $RELEASE_ID." >&2
  rollback_status=1
else
  actual_assets="$(jq -r '.assets[].name' \
    <<<"$final_release_json" | LC_ALL=C sort)"
fi

if (( command_status == 0 )) &&
  { [[ "$(jq -r '.draft' <<<"$final_release_json")" != "true" ]] ||
    [[ "$(jq -r '.immutable // false' <<<"$final_release_json")" != "false" ]] ||
    [[ "$(jq -r '.tag_name' <<<"$final_release_json")" != "$LABEL" ]] ||
    [[ "$actual_assets" != "$expected_assets" ]]; }; then
  echo "Rollback failed: the staging draft was not restored exactly." >&2
  rollback_status=1
fi

exit "$rollback_status"
