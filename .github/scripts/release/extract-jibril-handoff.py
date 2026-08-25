#!/usr/bin/env python3
"""Safely extract the authenticated files from a Jibril handoff TAR.

The SHA256SUMS is verified by the workflow before this program runs.

The program intentionally uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import tarfile
from pathlib import Path


EXPECTED_MEMBERS = {"jibril", "jibril-checksums.txt", "release.json"}
COPY_BUFFER_BYTES = 1024 * 1024


def parse_arguments() -> argparse.Namespace:
    """Define the small, explicit interface used by the workflow."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path, help="authenticated handoff TAR")
    parser.add_argument(
        "--destination",
        required=True,
        type=Path,
        help="existing empty extraction directory",
    )
    return parser.parse_args()


def fail(message: str) -> None:
    """Stop with a concise validation error."""
    raise SystemExit(message)


def require_regular_archive(path: Path) -> None:
    """Reject missing archives, links, directories, and special files."""
    try:
        information = path.lstat()
    except OSError as error:
        fail(f"cannot stat handoff archive: {error}")
    if not stat.S_ISREG(information.st_mode) or information.st_size <= 0:
        fail("handoff archive must be a non-empty regular file")


def require_empty_destination(path: Path) -> None:
    """Require an already-created real directory with no existing entries."""
    if not path.is_dir() or path.is_symlink():
        fail("handoff destination must be a real directory")
    try:
        if any(path.iterdir()):
            fail("handoff destination must be empty")
    except OSError as error:
        fail(f"cannot inspect handoff destination: {error}")


def validate_members(members: list[tarfile.TarInfo]) -> None:
    """Validate the exact member set, regular-file types, and root-level paths."""
    names = [member.name for member in members]
    if len(names) != 3 or set(names) != EXPECTED_MEMBERS:
        fail(
            "handoff must contain exactly jibril, "
            "jibril-checksums.txt, and release.json"
        )

    for member in members:
        if not member.isfile() or "/" in member.name or member.name in {".", ".."}:
            fail(f"unsafe handoff member: {member.name}")
        if member.size <= 0:
            fail(f"empty handoff member: {member.name}")


def extract_members(
    archive: tarfile.TarFile,
    members: list[tarfile.TarInfo],
    destination: Path,
) -> None:
    """Copy validated regular-file members without using tarfile.extract()."""
    for member in members:
        source = archive.extractfile(member)
        if source is None:
            fail(f"cannot extract handoff member: {member.name}")
        target = destination / member.name
        try:
            with source, target.open("xb") as output:
                shutil.copyfileobj(source, output, COPY_BUFFER_BYTES)
            if target.stat().st_size != member.size:
                fail(f"truncated handoff member: {member.name}")
        except OSError as error:
            fail(f"cannot extract handoff member {member.name}: {error}")


def main() -> None:
    """Run the archive validation and extraction procedure in safe order."""
    arguments = parse_arguments()
    require_regular_archive(arguments.archive)
    require_empty_destination(arguments.destination)

    try:
        with tarfile.open(arguments.archive, mode="r:gz") as archive:
            # Read at most four headers so an archive with extra members fails early.
            members: list[tarfile.TarInfo] = []
            for member in archive:
                members.append(member)
                if len(members) > 3:
                    fail("handoff contains more than three members")

            validate_members(members)
            extract_members(archive, members, arguments.destination)
    except (tarfile.TarError, OSError) as error:
        fail(f"invalid handoff archive: {error}")

    # Ignore archive ownership and permissions; publish known-safe local modes.
    os.chmod(arguments.destination / "jibril", 0o755)
    os.chmod(arguments.destination / "jibril-checksums.txt", 0o644)
    os.chmod(arguments.destination / "release.json", 0o644)
    print("Safely extracted the three authenticated handoff files")


if __name__ == "__main__":
    main()
