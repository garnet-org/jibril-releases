#!/usr/bin/env python3
"""Record one Jibril handoff archive in the committed release ledger.

A maintainer, a trusted AI or an automated workflow runs this locally, before
committing, against the handoff archive produced by the private build.

The program verifies the archive against its sidecar checksum file,
extracts it into a private temporary directory, and then writes the two
committed ledger files into releases/<tag>/:

    release.json                             taken from inside the archive
    <archive name>.SHA256SUM                 the sidecar, copied verbatim

It finally rewrites releases/index.json so that every release is keyed by its
tag, points at its release directory, and the keys are ordered newest first by
semantic-version precedence.

Nothing here replaces .github/scripts/release/validate-release-ledger.py. That
program remains the authoritative check and runs again in the workflow, against
the protected commit. This one only has to make the commit it validates easy to
produce and hard to get subtly wrong.

The program intentionally uses only the Python standard library.

Example
-------
Record the v2.17.0 handoff produced by the private build, from the root of a
clone of this repository:

    python3 -I -B scripts/update-release-ledger.py \\
      --archive ~/builds/jibril-v2.17.0-linux-x86_64.handoff.tar.gz

That reads ~/builds/jibril-v2.17.0-linux-x86_64.handoff.tar.gz.SHA256SUM beside
the archive, writes releases/v2.17.0/release.json and
releases/v2.17.0/jibril-v2.17.0-linux-x86_64.handoff.tar.gz.SHA256SUM, and adds
v2.17.0 to releases/index.json. Before returning, it runs
.github/scripts/release/validate-release-ledger.py over the result, so anything
it writes is already known to satisfy the workflow. Review and commit:

    git add releases/
    git diff --cached
    git commit -m "Record the v2.17.0 release ledger entry"

That same check can be repeated by hand at any time:

    python3 -I -B .github/scripts/release/validate-release-ledger.py \\
      --label v2.17.0 \\
      --handoff-name jibril-v2.17.0-linux-x86_64.handoff.tar.gz \\
      --releases-dir releases \\
      --github-output /dev/null

Useful variations:

    --label v2.17.0     refuse to record anything but this tag
    --checksum PATH     read the sidecar from somewhere other than beside the archive
    --releases-dir PATH write into a ledger outside this checkout
    --force             replace committed files of a release already recorded
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


SEMVER = re.compile(
    r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\."
    r"(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+"
    r"(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+"
    r"(?:\.[0-9A-Za-z-]+)*)?$"
)
INDEX_SCHEMA_VERSION = 2
PLATFORMS = ["linux-x86_64"]
READ_BUFFER_BYTES = 1024 * 1024
REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
EXTRACTOR = REPOSITORY_ROOT / ".github/scripts/release/extract-jibril-handoff.py"
VALIDATOR = REPOSITORY_ROOT / ".github/scripts/release/validate-release-ledger.py"


def parse_arguments() -> argparse.Namespace:
    """Define the small, explicit interface a maintainer drives by hand."""
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--archive",
        required=True,
        type=Path,
        help="handoff TAR, for example jibril-v2.17.0-linux-x86_64.handoff.tar.gz",
    )
    parser.add_argument(
        "--checksum",
        type=Path,
        help="sidecar checksum file (default: <archive>.SHA256SUM)",
    )
    parser.add_argument(
        "--releases-dir",
        type=Path,
        default=REPOSITORY_ROOT / "releases",
        help="repository release-ledger directory (default: ./releases)",
    )
    parser.add_argument(
        "--label",
        help="expected release tag; defaults to the tag inside release.json",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="replace committed ledger files that already exist with other content",
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


def sha256_file(path: Path) -> str:
    """Hash a file in bounded chunks so a large archive stays out of memory."""
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(READ_BUFFER_BYTES), b""):
                digest.update(chunk)
    except OSError as error:
        fail(f"cannot read {path}: {error}")
    return digest.hexdigest()


def verify_archive(archive: Path, checksum: Path) -> bytes:
    """Authenticate the archive against its sidecar and return the sidecar bytes.

    The sidecar must already hold the canonical one-line entry that
    validate-release-ledger.py will demand later, because it is committed
    verbatim. Rejecting a different spelling here fails the release now instead
    of in the workflow.
    """
    try:
        information = archive.lstat()
    except OSError as error:
        fail(f"cannot stat handoff archive: {error}")
    if not stat.S_ISREG(information.st_mode) or information.st_size <= 0:
        fail("handoff archive must be a non-empty regular file")

    raw = read_regular_file(checksum)
    try:
        manifest = raw.decode("ascii")
    except UnicodeDecodeError:
        fail(f"{checksum} must be ASCII")

    match = re.fullmatch(rf"([0-9a-f]{{64}})  {re.escape(archive.name)}\n", manifest)
    if not match:
        fail(
            f"{checksum} must hold exactly one canonical line: "
            f"'<sha256>  {archive.name}' followed by a newline"
        )

    expected = match.group(1)
    actual = sha256_file(archive)
    if not hmac.compare_digest(expected, actual):
        fail(
            f"handoff archive does not match its checksum: "
            f"expected {expected}, computed {actual}"
        )
    return raw


def extract_handoff(archive: Path, destination: Path) -> None:
    """Reuse the reviewed extractor so archive-safety rules live in one place."""
    if not EXTRACTOR.is_file() or EXTRACTOR.is_symlink():
        fail(f"missing or unsafe handoff extractor: {EXTRACTOR}")

    completed = subprocess.run(
        [
            sys.executable,
            "-I",
            "-B",
            str(EXTRACTOR),
            "--archive",
            str(archive),
            "--destination",
            str(destination),
        ],
        check=False,
    )
    if completed.returncode != 0:
        fail("handoff extraction failed")


def validate_staged_ledger(
    tag: str,
    archive_name: str,
    release_bytes: bytes,
    checksum_bytes: bytes,
    index_bytes: bytes,
) -> None:
    """Assemble the prospective entry in a temporary ledger and validate it there.

    The checks elsewhere in this file are only deep enough to key the ledger by
    its tag; validate-release-ledger.py owns the full schema. Running it here
    means a maintainer learns that an entry is unacceptable now, while the fix
    is a local edit, instead of from a failed release run, and keeps the two
    programs from drifting apart unnoticed.

    It runs against a copy rather than the repository because a rejected
    release must leave nothing behind: no half-written release directory, and
    no index entry for a release that was never recorded.
    """
    if not VALIDATOR.is_file() or VALIDATOR.is_symlink():
        fail(f"missing or unsafe ledger validator: {VALIDATOR}")

    workspace = Path(tempfile.mkdtemp(prefix="jibril-ledger-"))
    try:
        staged = workspace / "releases"
        staged_release_dir = staged / tag
        staged_release_dir.mkdir(parents=True)
        (staged_release_dir / "release.json").write_bytes(release_bytes)
        (staged_release_dir / f"{archive_name}.SHA256SUM").write_bytes(checksum_bytes)
        (staged / "index.json").write_bytes(index_bytes)

        completed = subprocess.run(
            [
                sys.executable,
                "-I",
                "-B",
                str(VALIDATOR),
                "--label",
                tag,
                "--handoff-name",
                archive_name,
                "--releases-dir",
                str(staged),
                # The digests belong to the workflow; here only the exit status
                # matters, so they are collected and thrown away.
                "--github-output",
                str(workspace / "outputs"),
            ],
            check=False,
        )
    except OSError as error:
        fail(f"cannot stage the ledger entry: {error}")
    finally:
        shutil.rmtree(workspace, ignore_errors=True)

    if completed.returncode != 0:
        fail(f"the prospective ledger entry does not pass {VALIDATOR.name}")


def read_release_document(path: Path, archive_name: str, label: str | None) -> str:
    """Check the extracted release.json far enough to key the ledger by its tag."""
    document = parse_json(read_regular_file(path), "extracted release")
    if not isinstance(document, dict) or document.get("schemaVersion") != 1:
        fail("release.json has an unsupported schemaVersion")

    release = document.get("release")
    if not isinstance(release, dict):
        fail("release.json release must be an object")

    tag = release.get("tag")
    if not isinstance(tag, str) or not SEMVER.fullmatch(tag):
        fail(f"release.json contains an invalid tag: {tag!r}")
    if label is not None and tag != label:
        fail(f"release.json tag {tag!r} does not match the requested label {label!r}")
    if release.get("platforms") != PLATFORMS:
        fail("release.json contains unsupported platforms")

    handoff = document.get("handoff")
    if not isinstance(handoff, dict) or handoff.get("name") != archive_name:
        fail(f"release.json does not name the handoff archive {archive_name!r}")

    # The workflow rebuilds this filename from the tag, so a name the workflow
    # would not recognise has to fail here rather than at release time.
    expected_name = f"jibril-{tag}-linux-x86_64.handoff.tar.gz"
    if archive_name != expected_name:
        fail(f"unexpected handoff filename: expected {expected_name!r}, found {archive_name!r}")
    return tag


def write_file(path: Path, data: bytes) -> None:
    """Replace a file in one step so an interrupted run leaves no half-written ledger."""
    temporary = path.with_name(f".{path.name}.new")
    try:
        with temporary.open("wb") as handle:
            handle.write(data)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except OSError as error:
        temporary.unlink(missing_ok=True)
        fail(f"cannot write {path}: {error}")


def ledger_file_state(target: Path, data: bytes, force: bool) -> str:
    """Decide what writing one committed ledger file would do, without writing it.

    Both files of a release are decided before either is written, so a refusal
    over the second one cannot leave the first one already replaced.
    """
    if target.is_symlink():
        fail(f"{target} must not be a symbolic link")
    if not target.exists():
        return "created"
    if read_regular_file(target) == data:
        return "unchanged"
    if not force:
        fail(f"{target} already exists with different content; pass --force to replace it")
    return "replaced"


def entry_platforms(tag: str, entry: object) -> list[str]:
    """Return the platforms recorded for one existing entry, however it was written.

    A missing platforms list is filled in, because older layouts are normalised
    here. A malformed entry is not: rewriting corruption into a well-formed
    index would hide it rather than report it.
    """
    if not isinstance(entry, dict):
        fail(f"releases/index.json entry {tag!r} is not an object")
    platforms = entry.get("platforms", PLATFORMS)
    if not isinstance(platforms, list) or not all(
        isinstance(platform, str) for platform in platforms
    ):
        fail(f"releases/index.json entry {tag!r} has invalid platforms")
    return list(platforms)


def load_index(path: Path) -> dict[str, list[str]]:
    """Load the ledger index as a tag-to-platforms mapping.

    Only the tag and its platforms survive: every other field is derived from
    the tag when the index is rewritten, so an entry written under an older
    layout is normalised on the next run rather than carried forward.
    """
    if not path.exists():
        return {}

    document = parse_json(read_regular_file(path), "release index")
    if not isinstance(document, dict) or set(document) != {"schemaVersion", "releases"}:
        fail("releases/index.json has an invalid structure")

    version = document["schemaVersion"]
    releases = document["releases"]

    if version == INDEX_SCHEMA_VERSION and isinstance(releases, dict):
        return {tag: entry_platforms(tag, entry) for tag, entry in releases.items()}

    if version == 1 and isinstance(releases, list):
        # Migrate the old array of entries, each carrying its own "tag" field,
        # into the tag-keyed mapping this program maintains.
        migrated: dict[str, list[str]] = {}
        for entry in releases:
            if not isinstance(entry, dict) or not isinstance(entry.get("tag"), str):
                fail("releases/index.json contains an invalid v1 entry")
            tag = entry["tag"]
            if tag in migrated:
                fail(f"releases/index.json contains the duplicate tag {tag!r}")
            migrated[tag] = entry_platforms(tag, entry)
        return migrated

    fail(f"unsupported releases/index.json schemaVersion: {version!r}")


def render_index(entries: dict[str, list[str]]) -> bytes:
    """Serialize the index with its keys ordered newest first.

    JSON objects carry no inherent order, so the ordering is a property of the
    committed bytes. validate-release-ledger.py re-checks that key sequence.

    Each entry only points at the release directory. The files inside it are
    named by a fixed convention, so listing any of them here would be a second
    copy of that convention to keep in step with the workflow.
    """
    for tag in entries:
        if not SEMVER.fullmatch(tag):
            fail(f"releases/index.json contains an invalid tag: {tag!r}")

    ordered = {
        tag: {"platforms": entries[tag], "release": f"releases/{tag}"}
        for tag in sorted(entries, key=precedence_key, reverse=True)
    }
    document = {"schemaVersion": INDEX_SCHEMA_VERSION, "releases": ordered}
    return (json.dumps(document, indent=2) + "\n").encode("utf-8")


def main() -> None:
    """Verify one handoff archive and record it in the committed ledger."""
    arguments = parse_arguments()
    archive = arguments.archive
    checksum = arguments.checksum or archive.with_name(f"{archive.name}.SHA256SUM")
    label = arguments.label

    if label is not None and not SEMVER.fullmatch(label):
        fail(f"invalid release label: {label}")

    releases_dir = arguments.releases_dir
    if releases_dir.is_symlink():
        fail("releases must be a real directory")

    # Authenticate before unpacking, so nothing downstream ever sees an archive
    # that failed its checksum.
    checksum_bytes = verify_archive(archive, checksum)

    # mkdtemp gives a unique 0700 directory, so the unpacked payload is never
    # readable by other local users and never collides with a parallel run.
    workspace = Path(tempfile.mkdtemp(prefix="jibril-handoff-"))
    try:
        extract_handoff(archive, workspace)
        tag = read_release_document(workspace / "release.json", archive.name, label)
        release_bytes = read_regular_file(workspace / "release.json")
    finally:
        shutil.rmtree(workspace, ignore_errors=True)

    release_dir = releases_dir / tag
    release_path = release_dir / "release.json"
    checksum_path = release_dir / f"{archive.name}.SHA256SUM"
    if release_dir.is_symlink():
        fail(f"{release_dir} must not be a symbolic link")

    entries = load_index(releases_dir / "index.json")
    entries[tag] = list(PLATFORMS)
    index_bytes = render_index(entries)

    # Decide every write, then prove the result acceptable, and only then touch
    # the repository. Until this point nothing under releases/ has changed.
    release_state = ledger_file_state(release_path, release_bytes, arguments.force)
    checksum_state = ledger_file_state(checksum_path, checksum_bytes, arguments.force)
    validate_staged_ledger(
        tag, archive.name, release_bytes, checksum_bytes, index_bytes
    )

    try:
        release_dir.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        fail(f"cannot create {release_dir}: {error}")
    if release_state != "unchanged":
        write_file(release_path, release_bytes)
    if checksum_state != "unchanged":
        write_file(checksum_path, checksum_bytes)
    write_file(releases_dir / "index.json", index_bytes)

    print(f"Recorded {tag} in the release ledger")
    print(f"  {release_path} ({release_state})")
    print(f"  {checksum_path} ({checksum_state})")
    print(f"  {releases_dir / 'index.json'} (updated, {len(entries)} releases)")


if __name__ == "__main__":
    main()
