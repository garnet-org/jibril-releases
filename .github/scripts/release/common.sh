#!/usr/bin/env bash
#
# Shared helpers for the public Jibril release workflow.
#
# Workflow steps source this file. The calling step owns
# `set -euo pipefail` and the semantics that go with it.
#

# gh_retry <command...>
#
# Run an idempotent command, retrying transient failures with linear backoff
# (3s, 6s, 9s, 12s; five attempts, ~30s worst case).
#
# Only wrap commands that converge when run twice in state *and* in exit
# status:
#   * reads             - `gh api` GET, `gh release download`
#   * converging writes - `gh release upload --clobber`
#
# Never wrap a non-converging write, such as the publish PATCH or the tag
# create-ref. If the first attempt succeeded but its response was lost, a
# retry would either act on state it created itself or act twice. Those call
# sites re-read remote state and decide, instead of retrying blindly.
#
# `gh release delete-asset` is deliberately absent from the list above. It
# converges in state but not in exit status: once the asset is gone the call
# 404s, so a retry after a successful-but-unacknowledged delete reports
# failure for work that actually landed. Use gh_delete_asset instead.
gh_retry() {
  local attempt status

  for attempt in 1 2 3 4 5; do
    "$@" && return 0
    status=$?

    if (( attempt == 5 )); then
      echo "gh_retry: giving up on '$*' after 5 attempts (status $status)." >&2
      return "$status"
    fi

    echo "gh_retry: '$*' failed with status $status; retrying in $(( attempt * 3 ))s." >&2
    sleep $(( attempt * 3 ))
  done
}

# gh_api_optional <api-path>
#
# GET an endpoint that is allowed to be absent. Prints the response body and
# returns 0 when it exists, 2 when GitHub definitively answers 404, and 1 when
# the answer could not be determined after retries.
#
# Why this exists: the idiom `gh api ... >/dev/null 2>&1 || absent=true`
# cannot tell "this release does not exist" apart from "GitHub was briefly
# unavailable". Both look like a non-zero exit. Collapsing them means a
# transient blip is silently promoted into a wrong conclusion about the state
# of a release or a tag, which is precisely the class of failure this workflow
# must never make. Callers that receive 1 abort instead of guessing.
gh_api_optional() {
  local api_path="${1:?gh_api_optional: api path is required}"
  local attempt output error_file

  error_file="$(mktemp)"

  for attempt in 1 2 3 4 5; do
    if output="$(gh api \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2026-03-10' \
      "$api_path" 2>"$error_file")"; then
      rm -f "$error_file"
      printf '%s' "$output"
      return 0
    fi

    # A 404 is an answer, not a failure, so report the error.
    if grep -q 'HTTP 404' "$error_file"; then
      rm -f "$error_file"
      return 2
    fi

    if (( attempt < 5 )); then
      sleep $(( attempt * 3 ))
    fi
  done

  cat "$error_file" >&2
  rm -f "$error_file"
  return 1
}

# gh_delete_asset <release-id> <asset-name>
#
# Detach an asset from a release, treating "already absent" as success.
# Returns 0 once no asset with that name is attached, and 1 when that could
# not be established.
gh_delete_asset() {
  local release_id="${1:?gh_delete_asset: release-id is required}"
  local asset_name="${2:?gh_delete_asset: asset_name is required}"
  local attempt release_json asset_id status

  for attempt in 1 2 3 4 5; do
    status=0
    release_json="$(gh_api_optional \
      "repos/${GITHUB_REPOSITORY}/releases/${release_id}")" || status=$?

    if (( status != 0 )); then
      echo "gh_delete_asset: could not read release ID $release_id (status $status)." >&2
      return 1
    fi

    asset_id="$(jq -r --arg name "$asset_name" \
      'first(.assets[] | select(.name == $name) | .id) // empty' \
      <<<"$release_json")"

    if [[ -z "$asset_id" ]]; then
      return 0
    fi

    if gh api \
      --method DELETE \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2026-03-10' \
      "repos/${GITHUB_REPOSITORY}/releases/assets/${asset_id}" >/dev/null; then
      return 0
    fi

    if (( attempt < 5 )); then
      echo "gh_delete_asset: could not delete '$asset_name'; retrying in $(( attempt * 3 ))s." >&2
      sleep $(( attempt * 3 ))
    fi
  done

  echo "gh_delete_asset: giving up on '$asset_name' after 5 attempts." >&2
  return 1
}

# log_section <title>
#
# Start a block of related checks. The leading blank line is what makes the
# log skimmable in the web UI, where every line is otherwise the same weight.
log_section() {
  printf '\n=== %s ===\n' "${1:?log_section: title is required}"
}

# log_field <name> <value>
#
# Report a value the run observed or is about to check against. Aligned so a
# column of digests can be compared by eye.
log_field() {
  printf '  %-34s %s\n' "${1:?log_field: name is required}:" "${2-}"
}

# log_ok <message>
#
# Report a check that passed. Say what was proven, not that a command ran.
log_ok() {
  printf '  [ok] %s\n' "${1:?log_ok: message is required}"
}

# log_note <message>
#
# Report an indented free-form line: list members, retry progress, closing
# summaries.
log_note() {
  printf '  %s\n' "${1-}"
}
