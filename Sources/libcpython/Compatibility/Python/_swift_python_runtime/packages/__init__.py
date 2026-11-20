"""Select installed package sources and mount Python archives."""

import io
import os
import sys
from importlib.machinery import PathFinder as ImportPathFinder

from .archive import Archive, normalize_name
from .finder import FilteredFinder, MetadataFinder, PathFinder, directory_distributions


def _named_distributions(path: str):
    names = set()
    for distribution in directory_distributions(path):
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


def select_distributions(paths):
    selected = {}
    shadowed = {}

    for path in paths:
        for name, distribution in _named_distributions(path):
            if name in selected:
                shadowed.setdefault(path, []).append(distribution)
            else:
                selected[name] = (path, distribution)
    return selected, shadowed


def distribution_files(distribution):
    return {str(path) for path in distribution.files or ()}


def _shadowed_files(selected, shadowed) -> dict[str, set[str]]:
    hidden = {}
    for path, distributions in shadowed.items():
        hidden[path] = {
            file for distribution in distributions for file in distribution_files(distribution)
        }

    # A file can be listed by both a shadowed and a selected distribution in the same root.
    for path, distribution in selected.values():
        files = hidden.get(path)
        if files is not None:
            files.difference_update(distribution_files(distribution))

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


def install(paths: list[str]) -> None:
    if not paths:
        return

    selected, shadowed = select_distributions(paths)
    _hide_shadowed_modules(selected, shadowed)

    sys.meta_path[sys.meta_path.index(ImportPathFinder)] = MetadataFinder(paths, selected)
    for path in paths:
        sys.path_importer_cache.pop(path, None)


def installation_tools() -> None:
    """Load the pinned installer libraries only in the service interpreter."""
    import _swift_python

    archives = []
    for name in _swift_python.children("_swift_python_packages"):
        if not name.endswith(".whl"):
            continue

        data = _swift_python.read("_swift_python_packages/" + name)
        root = "embedded:/installer/" + name
        archives.append(Archive(root, io.BytesIO(data)))

    if archives:
        sys.path_hooks.insert(0, _archive_hook(tuple(archives)))

    sys.path[:0] = [archive.root for archive in archives]


def _archive_hook(archives):
    def find(path: str) -> PathFinder:
        for archive in archives:
            if not archive.contains_path(path):
                continue

            relative = path[len(archive.root) :].strip("/")
            return PathFinder(archive, relative)

        raise ImportError

    return find
