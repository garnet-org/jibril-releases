#!/usr/bin/env python3
"""Validate one committed Jibril public-release ledger entry.

The workflow calls this program after checking out the exact protected commit.
It validates releases/index.json, releases/<tag>/release.json, and the external
<handoff archive name>.SHA256SUM manifest.
On success this program appends trusted digest values to the GitHub Actions
output file supplied with --github-output.

The program intentionally uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
from datetime import datetime, timedelta
from pathlib import Path


SEMVER = re.compile(
    r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\."
    r"(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+"
    r"(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+"
    r"(?:\.[0-9A-Za-z-]+)*)?$"
)
SHA256 = re.compile(r"^[0-9a-f]{64}$")
GIT_OBJECT_ID = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
UTC_TIMESTAMP = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"
    r"(?:\.\d+)?(?:Z|\+00:00)$"
)
INDEX_SCHEMA_VERSION = 2


def parse_arguments() -> argparse.Namespace:
    """Define the small, explicit interface used by the workflow."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True, help="release tag, for example v2.17.0")
    parser.add_argument("--handoff-name", required=True, help="expected handoff filename")
    parser.add_argument(
        "--releases-dir",
        required=True,
        type=Path,
        help="repository release-ledger directory",
    )
    parser.add_argument(
        "--github-output",
        required=True,
        type=Path,
        help="GitHub Actions output file",
    )
    return parser.parse_args()


def fail(message: str) -> None:
    """Stop with a concise validation error."""
    raise SystemExit(message)


def read_regular_file(path: Path) -> bytes:
    """Read one regular file while rejecting links and special files."""
    try:
        information = path.lstat()
    except OSError as error:
        fail(f"cannot stat {path}: {error}")
    if not stat.S_ISREG(information.st_mode):
        fail(f"{path} must be a regular file")
    try:
        return path.read_bytes()
    except OSError as error:
        fail(f"cannot read {path}: {error}")


def parse_json(raw: bytes, description: str) -> object:
    """Decode strict UTF-8 JSON with a useful error message."""
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        fail(f"invalid {description} JSON: {error}")


def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    """Refuse documents where a later duplicate key would silently win."""
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key {key!r}")
        result[key] = value
    return result


def precedence_key(tag: str) -> tuple:
    """Return the semantic-version precedence key for a v-prefixed tag."""
    body = tag[1:].split("+", 1)[0]
    core, _, prerelease = body.partition("-")
    major, minor, patch = (int(part) for part in core.split("."))
    if not prerelease:
        return (major, minor, patch, 1, ())

    identifiers = tuple(
        (0, int(identifier), "") if identifier.isdigit() else (1, 0, identifier)
        for identifier in prerelease.split(".")
    )
    return (major, minor, patch, 0, identifiers)


def handoff_sidecar_name(tag: str) -> str:
    """Return the committed sidecar filename for one release tag."""
    return f"jibril-{tag}-linux-x86_64.handoff.tar.gz.SHA256SUM"


def validate_index(index: object, label: str) -> None:
    """Validate the tag-keyed index of release directories."""
    if (
        not isinstance(index, dict)
        or set(index) != {"schemaVersion", "releases"}
        or index["schemaVersion"] != INDEX_SCHEMA_VERSION
        or not isinstance(index["releases"], dict)
    ):
        fail("releases/index.json has an invalid structure")

    # Duplicate keys were already rejected while parsing, so the key sequence
    # below is exactly the sequence in the committed bytes.
    tags = list(index["releases"])

    for tag in tags:
        entry = index["releases"][tag]
        if not isinstance(entry, dict) or set(entry) != {"platforms", "release"}:
            fail(f"releases/index.json entry {tag!r} has unexpected fields")

        if not SEMVER.fullmatch(tag):
            fail(f"releases/index.json contains an invalid tag: {tag!r}")
        if entry["platforms"] != ["linux-x86_64"]:
            fail("releases/index.json contains unsupported platforms")

        expected_release = f"releases/{tag}"
        if entry["release"] != expected_release:
            fail(
                f"releases/index.json entry {tag!r} has an incorrect release path: "
                f"expected {expected_release!r}, found {entry['release']!r}"
            )

    expected_order = sorted(tags, key=precedence_key, reverse=True)
    if tags != expected_order:
        fail(
            "releases/index.json keys are not ordered newest first: "
            f"expected {', '.join(expected_order)}"
        )

    if label not in index["releases"]:
        available = ", ".join(tags) if tags else "(none)"
        fail(
            f"releases/index.json does not contain the selected tag {label!r}; "
            f"available tags: {available}"
        )


def validate_source_metadata(release: dict[str, object]) -> None:
    """Validate optional source provenance fields when the extended schema is used."""
    source_sha = release["source_sha"]
    source_date = release["source_sha_date"]
    if not isinstance(source_sha, str) or not GIT_OBJECT_ID.fullmatch(source_sha):
        fail("release.json source_sha is invalid")
    if not isinstance(source_date, str):
        fail("release.json source_sha_date must be a string")
    if not source_date:
        return
    if not UTC_TIMESTAMP.fullmatch(source_date):
        fail("release.json source_sha_date must be UTC RFC 3339")

    normalized = source_date[:-1] + "+00:00" if source_date.endswith("Z") else source_date
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        fail(f"release.json source_sha_date is invalid: {error}")
    if parsed.utcoffset() != timedelta(0):
        fail("release.json source_sha_date must use UTC")


def validate_release(document: object, label: str, handoff_name: str) -> list[dict[str, str]]:
    """Validate release.json and return its ordered subject records."""
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion",
        "release",
        "handoff",
        "subjects",
    }:
        fail("release.json has unexpected top-level fields")
    if document["schemaVersion"] != 1:
        fail("unsupported release.json schemaVersion")

    release = document["release"]
    if not isinstance(release, dict):
        fail("release.json release must be an object")
    legacy_fields = {"tag", "platforms"}
    source_fields = {"tag", "source_sha", "source_sha_date", "platforms"}
    if set(release) not in (legacy_fields, source_fields):
        fail("release.json release has unexpected fields")
    if release["tag"] != label or release["platforms"] != ["linux-x86_64"]:
        fail("release.json does not match the selected release")
    if set(release) == source_fields:
        validate_source_metadata(release)

    if document["handoff"] != {"name": handoff_name}:
        fail("release.json contains an unexpected handoff")

    subjects = document["subjects"]
    if (
        not isinstance(subjects, list)
        or len(subjects) != 2
        or [item.get("name") for item in subjects if isinstance(item, dict)]
        != ["jibril", "jibril-checksums.txt"]
    ):
        fail("release.json contains unexpected subjects")
    for subject in subjects:
        if (
            not isinstance(subject, dict)
            or set(subject) != {"name", "sha256"}
            or not isinstance(subject["sha256"], str)
            or not SHA256.fullmatch(subject["sha256"])
        ):
            fail("release.json contains an invalid subject")
    return subjects


def validate_handoff_manifest(raw: bytes, handoff_name: str) -> str:
    """Validate the canonical one-line outer checksum and return its digest."""
    sidecar_name = f"{handoff_name}.SHA256SUM"
    try:
        manifest = raw.decode("ascii")
    except UnicodeDecodeError:
        fail(f"{sidecar_name} must be ASCII")
    match = re.fullmatch(rf"([0-9a-f]{{64}})  {re.escape(handoff_name)}\n", manifest)
    if not match:
        fail(f"{sidecar_name} has an invalid canonical entry")
    return match.group(1)


def append_outputs(path: Path, values: dict[str, str]) -> None:
    """Append validated values using GitHub Actions' key=value output format."""
    try:
        with path.open("a", encoding="utf-8") as output:
            for key, value in values.items():
                output.write(f"{key}={value}\n")
    except OSError as error:
        fail(f"cannot write GitHub Actions outputs: {error}")


def main() -> None:
    """Run the ledger validation procedure in trust-check order."""
    arguments = parse_arguments()
    label = arguments.label
    handoff_name = arguments.handoff_name

    # Validate path-forming inputs before using them as directory components.
    if not SEMVER.fullmatch(label):
        fail(f"invalid release label: {label}")
    expected_handoff_name = f"jibril-{label}-linux-x86_64.handoff.tar.gz"
    if handoff_name != expected_handoff_name:
        fail(f"unexpected handoff filename: {handoff_name}")

    releases_dir = arguments.releases_dir
    release_dir = releases_dir / label
    if not releases_dir.is_dir() or releases_dir.is_symlink():
        fail("releases must be a real directory")
    if not release_dir.is_dir() or release_dir.is_symlink():
        fail(f"missing or unsafe committed release directory: {release_dir}")
    # The sidecar is committed under the handoff archive's own name.
    sidecar_name = handoff_sidecar_name(label)
    present = sorted(path.name for path in release_dir.iterdir())
    if present != sorted(["release.json", sidecar_name]):
        fail(
            f"{release_dir} must contain exactly release.json and {sidecar_name}, "
            f"found: {', '.join(present) or '(nothing)'}"
        )

    # Read every committed input as a regular file; JSON and manifest parsing
    # below will reject empty or malformed content.
    release_bytes = read_regular_file(release_dir / "release.json")
    handoff_sums = read_regular_file(release_dir / sidecar_name)
    index_bytes = read_regular_file(releases_dir / "index.json")

    # Validate the index, metadata schema, subject digests, and handoff digest.
    validate_index(parse_json(index_bytes, "committed index"), label)
    subjects = validate_release(
        parse_json(release_bytes, "committed release"), label, handoff_name
    )
    handoff_sha256 = validate_handoff_manifest(handoff_sums, handoff_name)

    append_outputs(
        arguments.github_output,
        {
            "handoffSha256": handoff_sha256,
            "releaseJsonSha256": hashlib.sha256(release_bytes).hexdigest(),
            "binarySha256": subjects[0]["sha256"],
            "innerChecksumsSha256": subjects[1]["sha256"],
        },
    )
    print(f"Validated committed ledger entry for {label}")


if __name__ == "__main__":
    main()
