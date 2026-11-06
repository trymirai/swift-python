"""Validate absolute paths passed to package artifact operations."""

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
