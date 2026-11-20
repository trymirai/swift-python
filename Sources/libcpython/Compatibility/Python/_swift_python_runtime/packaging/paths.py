"""Filesystem and archive operations shared by package preparation."""

import errno
import os
from collections.abc import Iterator
from pathlib import Path


def absolute_path(path: str) -> Path:
    if not isinstance(path, str) or not os.path.isabs(path) or "\0" in path:
        raise ValueError(f"Expected an absolute environment path: {path!r}")

    return Path(path)


def walk_files(root: Path) -> Iterator[Path]:
    for directory, _, names in os.walk(root):
        for name in names:
            yield Path(directory, name)


def archive_entries(archive, size_error: str):
    entries = archive.infolist()
    if sum(info.file_size for info in entries) > 1024**3:
        raise ValueError(size_error)

    return entries


def archive_member_path(name: str) -> Path | None:
    path = Path(name)
    if path.is_absolute() or ".." in path.parts:
        return None

    return path


def publish_directory(stage: Path, target: Path) -> None:
    try:
        os.rename(stage, target)
    except OSError as error:
        # A concurrent installer may already have published the same digest.
        if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or not target.is_dir():
            raise
