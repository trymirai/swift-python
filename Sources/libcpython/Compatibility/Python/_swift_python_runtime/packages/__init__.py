"""Mount immutable application archives and the pinned installer libraries."""

import io
import sys

from .archive import Archive, Reader
from .finder import MetadataFinder, PathFinder


def _archive_hook(archives, *, at_root: bool = False):
    def find(path: str) -> PathFinder:
        for archive in archives:
            if not archive.contains_path(path):
                continue

            relative = "" if at_root else path[len(archive.root) :].strip("/")
            return PathFinder(archive, relative)

        raise ImportError

    return find


def install(sources: list[dict], read) -> list[str]:
    """Install one session's explicitly selected application package sources."""
    archives = []
    paths = []

    for index, source in enumerate(sources):
        if "directory" in source:
            paths.append(source["directory"])
            continue

        root = f"embedded:/packages/{index}"
        reader = (
            source["archive"]
            if "archive" in source
            else Reader(source["size"], lambda offset, size, i=index: read(i, offset, size))
        )
        archives.append(Archive(root, reader))
        paths.append(root)

    sys.path_hooks.insert(0, _archive_hook(archives))
    sys.meta_path.append(MetadataFinder(archives))

    for path in paths:
        sys.path_importer_cache.pop(path, None)

    return paths


def installation_tools() -> None:
    """Load the pinned installer libraries only in the service interpreter."""
    import _swift_python

    paths = []

    for name in _swift_python.children("_swift_python_packages"):
        if not name.endswith(".whl"):
            continue

        data = _swift_python.read("_swift_python_packages/" + name)
        root = "embedded:/installer/" + name
        archive = Archive(root, io.BytesIO(data))

        sys.path_hooks.insert(0, _archive_hook((archive,), at_root=True))
        paths.append(root)

    sys.path[:0] = paths
