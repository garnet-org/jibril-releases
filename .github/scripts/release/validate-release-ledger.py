#!/usr/bin/env python3
"""Validate one committed Jibril public-release ledger entry.

The workflow calls this program after checking out the exact protected commit.
It validates releases/index.json, releases/<tag>/release.json, and the external
SHA256SUMS-handoff manifest.
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
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid {description} JSON: {error}")


def validate_index(index: object, label: str) -> None:
    """Validate the index without using its final checksum pointer as handoff data."""
    if (
        not isinstance(index, dict)
        or set(index) != {"schemaVersion", "releases"}
        or index["schemaVersion"] != 1
        or not isinstance(index["releases"], list)
    ):
        fail("releases/index.json has an invalid structure")

    seen: set[str] = set()
    selected: list[dict[str, object]] = []
    tags: list[str] = []

    for entry in index["releases"]:
        if not isinstance(entry, dict) or set(entry) != {
            "tag",
            "platforms",
            "release",
            "checksums",
        }:
            fail("releases/index.json contains an invalid entry")

        tag = entry["tag"]
        if not isinstance(tag, str) or not SEMVER.fullmatch(tag) or tag in seen:
            fail("releases/index.json contains an invalid or duplicate tag")
        if entry["platforms"] != ["linux-x86_64"]:
            fail("releases/index.json contains unsupported platforms")

        expected_release = f"releases/{tag}/release.json"
        accepted_checksums = {
            f"releases/{tag}/SHA256SUMS",
            f"releases/{tag}/SHA256SUMS-handoff",
        }
        if entry["release"] != expected_release:
            fail(
                f"releases/index.json entry {tag!r} has an incorrect release path: "
                f"expected {expected_release!r}, found {entry['release']!r}"
            )
        if entry["checksums"] not in accepted_checksums:
            accepted = ", ".join(sorted(repr(path) for path in accepted_checksums))
            fail(
                f"releases/index.json entry {tag!r} has an incorrect checksum path: "
                f"expected one of {accepted}, found {entry['checksums']!r}"
            )

        seen.add(tag)
        tags.append(tag)
        if tag == label:
            selected.append(entry)

    if tags != sorted(tags):
        fail("releases/index.json entries are not sorted")

    # The index checksum pointer describes the eventual public release. It may
    # therefore name SHA256SUMS while this pre-publication ledger directory
    # contains SHA256SUMS-handoff. Handoff validation deliberately reads the
    # latter file directly and does not infer it from this index field.
    expected_selected = {
        "tag": label,
        "platforms": ["linux-x86_64"],
        "release": f"releases/{label}/release.json",
    }
    if not selected:
        available = ", ".join(tags) if tags else "(none)"
        fail(
            f"releases/index.json does not contain the selected tag {label!r}; "
            f"available tags: {available}"
        )

    selected_entry = selected[0]
    mismatches = [
        f"{field}: expected {expected!r}, found {selected_entry.get(field)!r}"
        for field, expected in expected_selected.items()
        if selected_entry.get(field) != expected
    ]
    if mismatches:
        fail(
            f"releases/index.json entry for {label!r} is incorrect: "
            + "; ".join(mismatches)
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
    try:
        manifest = raw.decode("ascii")
    except UnicodeDecodeError:
        fail("SHA256SUMS-handoff must be ASCII")
    match = re.fullmatch(rf"([0-9a-f]{{64}})  {re.escape(handoff_name)}\n", manifest)
    if not match:
        fail("SHA256SUMS-handoff has an invalid canonical entry")
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
    if sorted(path.name for path in release_dir.iterdir()) != [
        "SHA256SUMS-handoff",
        "release.json",
    ]:
        fail(f"{release_dir} must contain exactly release.json and SHA256SUMS-handoff")

    # Read every committed input as a regular file; JSON and manifest parsing
    # below will reject empty or malformed content.
    release_bytes = read_regular_file(release_dir / "release.json")
    handoff_sums = read_regular_file(release_dir / "SHA256SUMS-handoff")
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
