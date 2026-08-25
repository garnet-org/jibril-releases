#!/usr/bin/env bash

# Restore a partially modified draft release to its original staging state.
#
# Required environment variables:
#   LABEL              Release tag being finalized.
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
: "${HANDOFF_NAME:?HANDOFF_NAME is required}"
: "${TAR_NAME:?TAR_NAME is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"

if ! command -v gh >/dev/null 2>&1; then
  echo "Rollback failed: GitHub CLI is unavailable." >&2
  exit 1
fi

draft_inputs_dir="$GITHUB_WORKSPACE/draft-inputs"
handoff_path="$draft_inputs_dir/$HANDOFF_NAME"
checksums_path="$draft_inputs_dir/SHA256SUMS"

# Never upload missing files or follow a replaced staging-file symlink.
for staging_path in "$handoff_path" "$checksums_path"; do
  if [[ ! -f "$staging_path" || -L "$staging_path" ]]; then
    echo "Rollback failed: invalid staging file: $staging_path" >&2
    exit 1
  fi
done

echo "Finalization failed; attempting to restore the staging draft." >&2

# A published release must never be changed by this rollback helper.
release_state="$(gh release view "$LABEL" \
  --repo "$GITHUB_REPOSITORY" \
  --json isDraft \
  --jq '.isDraft' 2>/dev/null)"
command_status=$?

if (( command_status != 0 )); then
  echo "Rollback failed: could not read the release state." >&2
  exit 1
fi

if [[ "$release_state" != "true" ]]; then
  echo "Rollback refused: the release is no longer a draft." >&2
  exit 1
fi

# Remove only the final-only assets. Missing assets are acceptable because the
# failure may have happened before either upload completed.
for asset_name in jibril "$TAR_NAME"; do
  gh release delete-asset "$LABEL" "$asset_name" \
    --repo "$GITHUB_REPOSITORY" \
    --yes >/dev/null 2>&1 || true
done

rollback_status=0

# Restore or replace the original staging assets from the validated local copy.
if ! gh release upload "$LABEL" \
  "$handoff_path" \
  "$checksums_path" \
  --repo "$GITHUB_REPOSITORY" \
  --clobber >/dev/null 2>&1; then
  echo "Rollback failed: could not restore the staging assets." >&2
  rollback_status=1
fi

# Success requires the draft to contain exactly the original two assets.
expected_assets="$(printf '%s\n' \
  "$HANDOFF_NAME" SHA256SUMS | LC_ALL=C sort)"
actual_assets="$(gh release view "$LABEL" \
  --repo "$GITHUB_REPOSITORY" \
  --json assets,isDraft \
  --jq 'select(.isDraft == true) | .assets[].name' 2>/dev/null |
  LC_ALL=C sort)"
command_status=$?

if (( command_status != 0 )) ||
  [[ "$actual_assets" != "$expected_assets" ]]; then
  echo "Rollback failed: the staging draft was not restored exactly." >&2
  rollback_status=1
fi

exit "$rollback_status"
