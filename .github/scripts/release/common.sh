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
# Only wrap commands that converge when run twice:
#   * reads             - `gh api` GET, `gh release download`
#   * converging writes - `gh release upload --clobber`, `gh release delete-asset`
#
# Never wrap a non-converging write, such as the publish PATCH or the tag
# create-ref. If the first attempt succeeded but its response was lost, a
# retry would either act on state it created itself or act twice. Those call
# sites re-read remote state and decide, instead of retrying blindly.
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
  local api_path="$1"
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
