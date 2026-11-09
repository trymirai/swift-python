"""Expose frozen stdlib code, source inspection and resources in each interpreter.

The C catalogs own immutable process-wide bytes. Loaders, code objects and resource
wrappers belong to the current interpreter; this module never caches Python objects
globally in C. Structural loader protocols avoid importing importlib.abc while the
import system itself is still being installed.
"""

import _imp
import _swift_python
import os
import sys
from _frozen_importlib import FrozenImporter
from _frozen_importlib_external import SourceLoader, spec_from_file_location

_ROOT = "embedded:/stdlib"


def _is_embedded_path(path) -> bool:
    return isinstance(path, str) and (path == _ROOT or path.startswith(_ROOT + "/"))


class _Resource:
    """A read-only Traversable over the embedded resource catalog."""

    def __init__(self, path: str) -> None:
        self._path = path

    @property
    def name(self) -> str:
        return self._path.rsplit("/", 1)[-1]

    def iterdir(self):
        for name in _swift_python.children(self._path):
            yield self.joinpath(name)

    def is_dir(self) -> bool:
        return _swift_python.is_directory(self._path)

    def is_file(self) -> bool:
        return _swift_python.is_file(self._path)

    def joinpath(self, *descendants: str) -> "_Resource":
        parts = self._path.split("/") if self._path else []

        for descendant in descendants:
            for part in str(descendant).split("/"):
                if part == "..":
                    raise ValueError("Embedded resource paths cannot contain '..'")

                if part and part != ".":
                    parts.append(part)

        return _Resource("/".join(parts))

    def __truediv__(self, child: str) -> "_Resource":
        return self.joinpath(child)

    def open(self, mode: str = "r", *args, **kwargs):
        import io

        if mode not in ("r", "rt", "rb"):
            raise ValueError("Embedded resources are read-only")

        stream = io.BytesIO(self.read_bytes())
        return stream if mode == "rb" else io.TextIOWrapper(stream, *args, **kwargs)

    def read_bytes(self) -> bytes:
        return _swift_python.read(self._path)

    def read_text(self, encoding: str = "utf-8", errors: str = "strict") -> str:
        return self.read_bytes().decode(encoding, errors)

    def __str__(self) -> str:
        return _ROOT + "/" + self._path


class _Resources:
    """Bridge legacy resource readers and the current files() protocol."""

    def __init__(self, path: str) -> None:
        self._path = path

    def files(self) -> _Resource:
        return _Resource(self._path)

    def open_resource(self, resource: str):
        return self.files().joinpath(resource).open("rb")

    def resource_path(self, resource: str) -> str:
        raise FileNotFoundError("This resource is embedded in the executable")

    def is_resource(self, resource: str) -> bool:
        return self.files().joinpath(resource).is_file()

    def contents(self):
        return (entry.name for entry in self.files().iterdir())


class _Loader(SourceLoader):
    """Execute frozen code while exposing its source at a virtual path."""

    def __init__(self, path: str, package: bool) -> None:
        self.path = path
        self._package = package

    def get_code(self, fullname: str):
        code = _imp.get_frozen_object(fullname)
        _imp._fix_co_filename(code, self.get_filename(fullname))
        return code

    def get_filename(self, fullname: str) -> str:
        return _ROOT + "/" + self.path

    def get_data(self, path: str) -> bytes:
        prefix = _ROOT + "/"
        if not path.startswith(prefix):
            raise FileNotFoundError(path)

        return _swift_python.read(path[len(prefix) :])

    def is_package(self, fullname: str) -> bool:
        return self._package

    def get_resource_reader(self, fullname: str) -> _Resources | None:
        if not self._package:
            return None

        return _Resources(self.path.rsplit("/", 1)[0])


def _spec(fullname: str, filename: str, package: bool):
    loader = _Loader(filename, package)
    return spec_from_file_location(fullname, loader=loader)


class _PathFinder:
    """Resolve and enumerate modules within one embedded search path."""

    def __init__(self, path: str) -> None:
        self._path = path[len(_ROOT) :].strip("/")

    def find_spec(self, fullname: str, target=None):
        info = _swift_python.module(fullname)
        if info is None:
            return None

        filename, package = info
        entry = filename.removesuffix("/__init__.py") if package else filename
        if entry.rpartition("/")[0] == self._path:
            return _spec(fullname, filename, package)

        return None

    def iter_modules(self, prefix: str = ""):
        parent = self._path.replace("/", ".")

        for child in _swift_python.children(self._path):
            if child == "__init__.py":
                continue

            name = child.removesuffix(".py")
            fullname = parent + "." + name if parent else name
            info = _swift_python.module(fullname)
            if info is not None:
                yield prefix + name, bool(info[1])


def _path_hook(path: str) -> _PathFinder:
    if _is_embedded_path(path):
        return _PathFinder(path)

    raise ImportError


_FUNCTION_TYPE = type(lambda: None)


def _fix_functions(values, module_name: str, filename: str) -> None:
    # Imports required during Py_Initialize ran before our loader was installed.
    # Give their existing code objects the same virtual filename as later imports.
    for value in values:
        if type(value) is not _FUNCTION_TYPE:
            if isinstance(value, (staticmethod, classmethod)):
                value = value.__func__
            elif isinstance(value, property):
                _fix_functions((value.fget, value.fset, value.fdel), module_name, filename)
                continue

        if type(value) is _FUNCTION_TYPE and value.__module__ == module_name:
            _imp._fix_co_filename(value.__code__, filename)


def _rebind_module(name: str, module, spec) -> None:
    module.__loader__ = spec.loader
    module.__spec__ = spec
    module.__file__ = spec.origin

    values = tuple(vars(module).values())
    _fix_functions(values, name, spec.origin)
    for value in values:
        if isinstance(value, type) and value.__module__ == name:
            _fix_functions(tuple(vars(value).values()), name, spec.origin)

    if spec.submodule_search_locations is not None:
        module.__path__ = spec.submodule_search_locations


def _rebind_bootstrap_modules() -> None:
    for name, module in tuple(sys.modules.items()):
        if getattr(module, "__loader__", None) is not FrozenImporter:
            continue

        # Bootstrap aliases retain their original import machinery identity.
        if name in ("importlib._bootstrap", "importlib._bootstrap_external"):
            continue

        info = _swift_python.module(name)
        if info is not None:
            _rebind_module(name, module, _spec(name, *info))


def install() -> None:
    """Install idempotently while holding this interpreter's thread state."""
    if _path_hook in sys.path_hooks:
        return

    # site makes relative search entries absolute before our path hook is available.
    normalized_root = os.path.abspath(_ROOT)
    sys.path[:] = [_ROOT if path == normalized_root else path for path in sys.path]
    sys.path_hooks.insert(0, _path_hook)

    # Let sys.path choose between embedded modules and host-supplied overrides.
    if FrozenImporter in sys.meta_path:
        sys.meta_path.remove(FrozenImporter)

    _rebind_bootstrap_modules()

    for path in tuple(sys.path_importer_cache):
        if _is_embedded_path(path):
            del sys.path_importer_cache[path]


install()
