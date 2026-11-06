"""Maintain one interpreter's managed import paths and loaded modules."""

import sys

_import_paths = []


def _set_import_paths(paths: list[str]) -> None:
    global _import_paths

    excluded = set(_import_paths) | set(paths)
    remaining = [path for path in sys.path if path not in excluded]

    sys.path[:] = paths + remaining
    _import_paths = paths


def _loaded_source_modules(names: list[str]) -> list[tuple]:
    from importlib.machinery import SourceFileLoader

    loaded = []
    for name in sorted(set(names), key=lambda name: name.count("."), reverse=True):
        module = sys.modules.get(name)
        if module is None:
            continue

        spec = getattr(module, "__spec__", None)
        if spec is None or not isinstance(spec.loader, SourceFileLoader):
            raise ImportError(f"Reset the session before replacing {name!r}")

        loaded.append((name, module))
    return loaded


def update_imports(change: tuple[list[str], list[str]], unused=None, control=None) -> None:
    import importlib

    paths, names = change
    # Validate the entire batch before changing import roots or evicting modules.
    loaded = _loaded_source_modules(names)

    importlib.invalidate_caches()
    _set_import_paths(paths)

    for name, module in loaded:
        sys.modules.pop(name, None)

        parent_name, _, binding = name.rpartition(".")
        parent = sys.modules.get(parent_name)
        if parent is not None and parent.__dict__.get(binding) is module:
            del parent.__dict__[binding]
