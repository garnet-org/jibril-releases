#!/usr/bin/env bash
#
# Verify a release that is already published (mode=verify).
#
# A previous run published this label and then died before it finished
# verifying. Nothing can be changed now, so this proves that what is public is
# exactly what the reviewed ledger describes, and leaves the three published
# assets in release-assets/ so confirm-immutable-release.sh runs against them
# unmodified, exactly as it does on the publish path.
#
# The public TAR is not byte-reproducible across runs, because every run mints
# fresh Sigstore bundles, so rebuilding it locally and comparing would always
# fail. The chain checked here is the one that matters:
#
#   published bytes -> SHA256SUMS -> TAR members -> ledger digests
#                                                -> Cosign bundles
#
# The GitHub attestation chains are checked afterwards, by
# confirm-immutable-release.sh.
#
# Required environment:
#   LABEL                             Release tag to verify.
#   TAR_NAME                          Public archive asset name.
#   EXPECTED_BINARY_SHA256            Ledger digest of jibril.
#   EXPECTED_INNER_CHECKSUMS_SHA256   Ledger digest of jibril-checksums.txt.
#   EXPECTED_RELEASE_JSON_SHA256      Ledger digest of release.json.
#   EXPECTED_CERTIFICATE_IDENTITY     Cosign identity expectation.
#   EXPECTED_CERTIFICATE_OIDC_ISSUER  Cosign issuer expectation.
#   GITHUB_REPOSITORY, GITHUB_SHA, GITHUB_REF, GITHUB_WORKFLOW
#   GITHUB_WORKSPACE                  Checked-out repository root.
#   GITHUB_OUTPUT                     GitHub Actions step-output file.
#   GH_TOKEN                          Token used by the GitHub CLI.

set -euo pipefail

: "${LABEL:?LABEL is required}"
: "${TAR_NAME:?TAR_NAME is required}"
: "${EXPECTED_BINARY_SHA256:?EXPECTED_BINARY_SHA256 is required}"
: "${EXPECTED_INNER_CHECKSUMS_SHA256:?EXPECTED_INNER_CHECKSUMS_SHA256 is required}"
: "${EXPECTED_RELEASE_JSON_SHA256:?EXPECTED_RELEASE_JSON_SHA256 is required}"
: "${EXPECTED_CERTIFICATE_IDENTITY:?EXPECTED_CERTIFICATE_IDENTITY is required}"
: "${EXPECTED_CERTIFICATE_OIDC_ISSUER:?EXPECTED_CERTIFICATE_OIDC_ISSUER is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_REF:?GITHUB_REF is required}"
: "${GITHUB_WORKFLOW:?GITHUB_WORKFLOW is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

# shellcheck source=.github/scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$GITHUB_WORKSPACE"

log_section "Verifying an already-published release"
log_field "release" "$LABEL"
log_field "repository" "$GITHUB_REPOSITORY"
log_field "ledger commit" "$GITHUB_SHA"
log_field "archive asset" "$TAR_NAME"
log_field "ledger jibril sha256" "$EXPECTED_BINARY_SHA256"
log_field "ledger checksums sha256" "$EXPECTED_INNER_CHECKSUMS_SHA256"
log_field "ledger release.json sha256" "$EXPECTED_RELEASE_JSON_SHA256"

# Check the tag binding first. Everything below, including the Cosign policy,
# assumes the run that published these assets ran at this exact commit, because
# each run binds the tag to its own GITHUB_SHA and refuses to continue
# otherwise. If the default branch has moved on since publication that
# assumption is broken, and saying so here is far clearer than the certificate
# mismatch it would otherwise surface as.
log_section "Tag binding"
tag_commit="$(gh_retry gh api \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/${GITHUB_REPOSITORY}/commits/${LABEL}" \
  --jq '.sha')"
log_field "tag $LABEL names" "$tag_commit"
log_field "this run is at" "$GITHUB_SHA"
if [[ "$tag_commit" != "$GITHUB_SHA" ]]; then
  echo "Tag $LABEL names $tag_commit but this run is at $GITHUB_SHA." >&2
  echo "Verify-only mode requires the run to sit on the published ledger commit." >&2
  echo "Re-run the original run rather than dispatching a new one." >&2
  exit 1
fi
log_ok "The published tag names the ledger commit this run is pinned to."

log_section "Downloading the published assets"
rm -rf release-assets
mkdir -m 0700 release-assets
for asset_name in jibril "$TAR_NAME" SHA256SUMS; do
  gh_retry gh release download "$LABEL" \
    --repo "$GITHUB_REPOSITORY" \
    --pattern "$asset_name" \
    --dir release-assets \
    --clobber
  test -s "release-assets/$asset_name"
  log_field "$asset_name" \
    "$(sha256sum "release-assets/$asset_name" | cut -d' ' -f1) ($(stat -c '%s' "release-assets/$asset_name") bytes)"
done
log_ok "All three published assets downloaded and non-empty."

log_section "Published SHA256SUMS manifest"
while IFS= read -r manifest_line || [[ -n "$manifest_line" ]]; do
  log_note "$manifest_line"
done < release-assets/SHA256SUMS

expected_manifest="$(printf '%s  jibril\n%s  %s' \
  "$(sha256sum release-assets/jibril | cut -d' ' -f1)" \
  "$(sha256sum "release-assets/$TAR_NAME" | cut -d' ' -f1)" \
  "$TAR_NAME")"
if [[ "$(wc -l < release-assets/SHA256SUMS)" -ne 2 ||
  "$(cat release-assets/SHA256SUMS)" != "$expected_manifest" ]]; then
  echo "The published SHA256SUMS is not canonical." >&2
  diff -u \
    <(printf '%s\n' "$expected_manifest") \
    release-assets/SHA256SUMS >&2 || true
  exit 1
fi
log_ok "The manifest is the canonical two-line manifest for the downloaded bytes."
(
  cd release-assets
  sha256sum --check --strict SHA256SUMS
)
log_ok "Every published byte matches the manifest it is distributed with."

# Unpack the published TAR and check it against the reviewed ledger.
log_section "Published archive contents"
package_files=(
  jibril
  jibril-checksums.txt
  release.json
  jibril.sigstore.json
  jibril-checksums.txt.sigstore.json
  release.json.sigstore.json
)
expected_contents="$(printf '%s\n' \
  "${package_files[@]}" | LC_ALL=C sort)"
actual_contents="$(tar -tzf \
  "release-assets/$TAR_NAME" | LC_ALL=C sort)"
while IFS= read -r member; do
  log_note "$member"
done <<<"$actual_contents"
if [[ "$actual_contents" != "$expected_contents" ]]; then
  echo "The published TAR has unexpected contents." >&2
  diff -u \
    <(printf '%s\n' "$expected_contents") \
    <(printf '%s\n' "$actual_contents") >&2 || true
  exit 1
fi
log_ok "The archive holds exactly the ${#package_files[@]} expected members."

published_package="$RUNNER_TEMP/published-package"
rm -rf "$published_package"
mkdir -m 0700 "$published_package"
tar \
  --extract \
  --gzip \
  --file "release-assets/$TAR_NAME" \
  --directory "$published_package" \
  --no-same-owner \
  --no-same-permissions

log_section "Published payloads against the reviewed ledger"
if ! cmp --silent \
  "$published_package/release.json" \
  "releases/$LABEL/release.json"; then
  echo "The published release.json differs from releases/$LABEL/release.json." >&2
  diff -u \
    "releases/$LABEL/release.json" \
    "$published_package/release.json" >&2 || true
  exit 1
fi
log_ok "release.json is byte-identical to the copy in the reviewed ledger."

actual_binary_sha256="$(sha256sum \
  "$published_package/jibril" | cut -d' ' -f1)"
actual_inner_checksums_sha256="$(sha256sum \
  "$published_package/jibril-checksums.txt" | cut -d' ' -f1)"
actual_release_json_sha256="$(sha256sum \
  "$published_package/release.json" | cut -d' ' -f1)"
log_field "jibril sha256" "$actual_binary_sha256"
log_field "jibril-checksums.txt sha256" "$actual_inner_checksums_sha256"
log_field "release.json sha256" "$actual_release_json_sha256"
if [[ "$actual_binary_sha256" != "$EXPECTED_BINARY_SHA256" ||
  "$actual_inner_checksums_sha256" != "$EXPECTED_INNER_CHECKSUMS_SHA256" ||
  "$actual_release_json_sha256" != "$EXPECTED_RELEASE_JSON_SHA256" ]]; then
  echo "The published payload digests do not match the reviewed ledger." >&2
  echo "  jibril:               ledger $EXPECTED_BINARY_SHA256, published $actual_binary_sha256" >&2
  echo "  jibril-checksums.txt: ledger $EXPECTED_INNER_CHECKSUMS_SHA256, published $actual_inner_checksums_sha256" >&2
  echo "  release.json:         ledger $EXPECTED_RELEASE_JSON_SHA256, published $actual_release_json_sha256" >&2
  exit 1
fi
log_ok "All three payload digests match the reviewed ledger."

# The direct binary and the one inside the TAR must be the same file.
if ! cmp --silent "$published_package/jibril" release-assets/jibril; then
  echo "The published jibril asset is not the binary inside $TAR_NAME." >&2
  exit 1
fi
log_ok "The direct jibril asset is byte-identical to the archived one."

# Verify the published Cosign bundles under the same policy the signing step
# applies on the publish path. The workflow-sha constraint holds because of the
# tag check at the top of this script.
log_section "Cosign bundles against the signing policy"
verification_policy=(
  --certificate-identity "$EXPECTED_CERTIFICATE_IDENTITY"
  --certificate-oidc-issuer "$EXPECTED_CERTIFICATE_OIDC_ISSUER"
  --certificate-github-workflow-name "$GITHUB_WORKFLOW"
  --certificate-github-workflow-repository "$GITHUB_REPOSITORY"
  --certificate-github-workflow-ref "$GITHUB_REF"
  --certificate-github-workflow-sha "$GITHUB_SHA"
  --certificate-github-workflow-trigger workflow_dispatch
)
log_field "certificate identity" "$EXPECTED_CERTIFICATE_IDENTITY"
log_field "certificate OIDC issuer" "$EXPECTED_CERTIFICATE_OIDC_ISSUER"
log_field "workflow name" "$GITHUB_WORKFLOW"
log_field "workflow repository" "$GITHUB_REPOSITORY"
log_field "workflow ref" "$GITHUB_REF"
log_field "workflow commit" "$GITHUB_SHA"
log_field "workflow trigger" "workflow_dispatch"
for payload in jibril jibril-checksums.txt release.json; do
  cosign verify-blob \
    "${verification_policy[@]}" \
    --bundle "$published_package/${payload}.sigstore.json" \
    "$published_package/$payload"
  log_ok "${payload}.sigstore.json verified under the policy above."
done

log_section "Verification result"
log_note "Release $LABEL is published and matches the reviewed ledger."
log_field "ledger commit" "$GITHUB_SHA"
log_field "tag commit" "$tag_commit"
log_field "verified assets" "jibril, $TAR_NAME, SHA256SUMS"
log_note "Proven chain: published bytes -> SHA256SUMS -> archive members ->"
log_note "ledger digests -> Cosign bundles."
log_note "Both GitHub attestation chains are checked next, by"
log_note "confirm-immutable-release.sh."

# confirm-immutable-release.sh compares the tag against this value, exactly as
# it does with the tag step's output on the publish path.
echo "tagCommitSha=$tag_commit" >> "$GITHUB_OUTPUT"
