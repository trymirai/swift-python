"""Maintain one interpreter's managed import paths and loaded modules."""

import sys

_import_paths = []


def restore_imports(change: tuple[list[str], list[str]]) -> None:
    global _import_paths

    paths, discarded = change
    excluded = set(_import_paths) | set(paths) | set(discarded)
    remaining = [path for path in sys.path if path not in excluded]

    sys.path[:] = paths + remaining
    _import_paths = paths


def update_imports(change: tuple[list[str], list[str]], unused=None, control=None) -> None:
    import importlib
    from importlib.machinery import SourceFileLoader

    paths, names = change
    loaded = []

    for name in sorted(set(names), key=lambda name: name.count("."), reverse=True):
        module = sys.modules.get(name)
        if module is None:
            continue

        spec = getattr(module, "__spec__", None)
        if spec is None or not isinstance(spec.loader, SourceFileLoader):
            raise ImportError(f"Reset the session before replacing {name!r}")

        loaded.append((name, module))

    importlib.invalidate_caches()
    restore_imports((paths, []))

    for name, module in loaded:
        sys.modules.pop(name, None)
        parent_name, _, binding = name.rpartition(".")
        parent = sys.modules.get(parent_name)
        if parent is not None and parent.__dict__.get(binding) is module:
            del parent.__dict__[binding]


def loaded_modules(change: dict, unused, control) -> list[str]:
    from types import ModuleType

    files = set(change["files"])
    roots = [path.rstrip("/") + "/" for path in change["roots"]]

    def relative(path) -> str | None:
        if isinstance(path, str):
            for root in roots:
                if path.startswith(root):
                    return path[len(root) :]

        return None

    loaded = []

    for name, module in tuple(sys.modules.items()):
        if not isinstance(module, ModuleType):
            continue

        if relative(module.__dict__.get("__file__")) in files:
            loaded.append(name)
            continue

        # Existing packages can retain __path__ entries from earlier generations.
        # A newly installed child must not be published behind those stale paths.
        for path in module.__dict__.get("__path__", ()):
            package = relative(path)
            if package is not None and any(
                file.startswith(package.rstrip("/") + "/") for file in files
            ):
                loaded.append(name)
                break

    return sorted(loaded)
