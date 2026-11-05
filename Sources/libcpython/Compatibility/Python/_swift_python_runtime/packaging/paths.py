"""Validate absolute paths passed to package artifact operations."""

import os
from pathlib import Path


def absolute_path(path: str) -> Path:
    if not isinstance(path, str) or not os.path.isabs(path) or "\0" in path:
        raise ValueError(f"Expected an absolute environment path: {path!r}")

    return Path(path)
