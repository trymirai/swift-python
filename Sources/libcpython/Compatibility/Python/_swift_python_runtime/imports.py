"""Maintain one interpreter's managed import paths and loaded modules."""

import importlib
import os
import sys
from importlib.machinery import ModuleSpec, PathFinder
from types import ModuleType

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
    # Evict children first so their bindings can still be removed from their parents.
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


class _ModuleLoader:
    def __init__(self, loader, source: str, filename: str, execute) -> None:
        self.loader = loader
        self.source = source
        self.filename = filename
        self.execute = execute

    def create_module(self, spec):
        return self.loader.create_module(spec)

    def exec_module(self, module) -> None:
        # Keep the original loader visible to resources, inspection and invalidation.
        module.__loader__ = module.__spec__.loader = self.loader
        self.execute(self.source, self.filename, module.__dict__)


class _ModuleFinder:
    def __init__(self, name: str, execute) -> None:
        self.name = name
        self.execute = execute

    def find_spec(self, fullname: str, path=None, target=None) -> ModuleSpec | None:
        if fullname != self.name:
            return None

        for finder in sys.meta_path:
            if finder is self:
                continue
            spec = finder.find_spec(fullname, path, target)
            if spec is not None:
                source = getattr(spec.loader, "get_source", None)
                filename = getattr(spec.loader, "get_filename", None)
                if source is not None and filename is not None:
                    text = source(fullname)
                    if text is not None:
                        spec.loader = _ModuleLoader(spec.loader, text, filename(fullname), self.execute)
                return spec
        return None


def import_module(name: str, execute) -> ModuleType:
    finder = _ModuleFinder(name, execute)
    sys.meta_path.insert(0, finder)
    try:
        return importlib.import_module(name)
    finally:
        if finder in sys.meta_path:
            sys.meta_path.remove(finder)


class _ProjectFinder:
    def __init__(self, directory: str, name: str, import_paths: list[str]) -> None:
        self.directory = directory
        self.name = name

        self.search_paths = [directory]
        self.search_paths.extend(path for path in import_paths if self._contains(path))

    def _contains(self, path: object) -> bool:
        if not isinstance(path, str) or not os.path.isabs(path):
            return False

        relative = os.path.relpath(path, self.directory)
        return relative != os.pardir and not relative.startswith(os.pardir + os.sep)

    def _missing(self) -> ModuleNotFoundError:
        # Preserve the project diagnostic for names shared with the standard library.
        return ModuleNotFoundError(
            f"Startup module {self.name!r} was not found in project {self.directory!r}."
        )

    def check_loaded(self) -> None:
        # Python consults sys.modules before any finder, including for parent packages.
        fullname = self.name
        while fullname:
            if fullname in sys.modules:
                spec = getattr(sys.modules[fullname], "__spec__", None)
                if spec is None:
                    raise self._missing()
                paths = (spec.origin,) if spec.origin else spec.submodule_search_locations or ()
                if not any(self._contains(path) for path in paths):
                    raise self._missing()
            fullname = fullname.rpartition(".")[0]

    def find_spec(self, fullname: str, path=None, target=None) -> ModuleSpec | None:
        if fullname != self.name and not self.name.startswith(fullname + "."):
            return None

        paths = (
            self.search_paths
            if path is None
            else [entry for entry in path if self._contains(entry)]
        )

        spec = PathFinder.find_spec(fullname, paths, target)
        if spec is None:
            raise self._missing()
        return spec


def import_project(directory: str, name: str | None, import_paths: list[str], execute) -> ModuleType:
    if name is None:
        with os.scandir(directory) as entries:
            packages = (
                entry.name
                for entry in entries
                if entry.name.isidentifier()
                and entry.is_dir(follow_symlinks=False)
                and os.path.isfile(os.path.join(entry.path, "__init__.py"))
            )
            name = min(packages, default=None)

        if name is None:
            raise ModuleNotFoundError(
                f"No startup package in project {directory!r}. "
                "Add a package with __init__.py or specify a module."
            )
    elif not all(part.isidentifier() for part in name.split(".")):
        raise ValueError(f"Invalid startup module name {name!r}.")

    # Limit only the startup module and its parents. Dependencies use the usual import paths.
    finder = _ProjectFinder(directory, name, import_paths)
    finder.check_loaded()
    sys.meta_path.insert(0, finder)
    try:
        return import_module(name, execute)
    finally:
        if finder in sys.meta_path:
            sys.meta_path.remove(finder)
