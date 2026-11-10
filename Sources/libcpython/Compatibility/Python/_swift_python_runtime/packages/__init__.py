"""Select installed package sources and mount Python archives."""

import io
import os
import sys
from importlib.machinery import PathFinder as ImportPathFinder

from .archive import Archive, Reader, normalize_name
from .finder import FilteredFinder, MetadataFinder, PathFinder, directory_distributions


def _archive_hook(archives):
    def find(path: str) -> PathFinder:
        for archive in archives:
            if not archive.contains_path(path):
                continue

            relative = path[len(archive.root) :].strip("/")
            return PathFinder(archive, relative)

        raise ImportError

    return find


def load_sources(sources: list[dict], read) -> dict[str, Archive | None]:
    paths = {}

    for index, source in enumerate(sources):
        if "directory" in source:
            paths[source["directory"]] = None
            continue

        root = f"embedded:/packages/{index}"
        reader = (
            source["archive"]
            if "archive" in source
            else Reader(source["size"], lambda offset, size, i=index: read(i, offset, size))
        )
        paths[root] = Archive(root, reader)

    return paths


def _named_distributions(path: str, archive: Archive | None):
    distributions = directory_distributions(path) if archive is None else archive.distributions()
    names = set()

    for distribution in distributions:
        name = distribution.metadata["Name"]
        if not name:
            raise ValueError(f"Missing distribution name in {path}")

        name = normalize_name(name)
        if name in names:
            raise ValueError(
                f"Package source {path} contains multiple distributions named {name!r}"
            )
        names.add(name)
        yield name, distribution


def select_distributions(sources: dict[str, Archive | None]):
    selected = {}
    shadowed = {}

    for path, archive in sources.items():
        for name, distribution in _named_distributions(path, archive):
            if name in selected:
                shadowed.setdefault(path, []).append(distribution)
            else:
                selected[name] = (path, distribution)
    return selected, shadowed


def distribution_files(distribution):
    return {str(path) for path in distribution.files or ()}


def _shadowed_files(selected, shadowed) -> dict[str, set[str]]:
    hidden = {
        path: {file for distribution in distributions for file in distribution_files(distribution)}
        for path, distributions in shadowed.items()
    }

    # A file can be listed by both a shadowed and a selected distribution in the same root.
    for path, distribution in selected.values():
        if path in hidden:
            hidden[path].difference_update(distribution_files(distribution))
    return {
        path: {os.path.normpath(path + "/" + file) for file in files}
        for path, files in hidden.items()
        if files
    }


def _hide_shadowed_modules(selected, shadowed) -> None:
    hidden = _shadowed_files(selected, shadowed)
    if not hidden:
        return

    hooks = tuple(sys.path_hooks)

    def find(path: str):
        for root, files in hidden.items():
            if path != root and not path.startswith(root + "/"):
                continue

            for hook in hooks:
                try:
                    return FilteredFinder(hook(path), files)
                except ImportError:
                    continue
        raise ImportError

    sys.path_hooks.insert(0, find)


def install(sources: list[dict], read) -> list[str]:
    paths = load_sources(sources, read)
    if not paths:
        return []

    selected, shadowed = select_distributions(paths)
    archives = tuple(archive for archive in paths.values() if archive is not None)
    if archives:
        sys.path_hooks.insert(0, _archive_hook(archives))
    _hide_shadowed_modules(selected, shadowed)

    sys.meta_path[sys.meta_path.index(ImportPathFinder)] = MetadataFinder(paths, selected)
    for path in paths:
        sys.path_importer_cache.pop(path, None)

    return list(paths)


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

        sys.path_hooks.insert(0, _archive_hook((archive,)))
        paths.append(root)

    sys.path[:0] = paths
