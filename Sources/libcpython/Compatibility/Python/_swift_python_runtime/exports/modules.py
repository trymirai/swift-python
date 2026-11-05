"""Declare the selected module graph, install exports and execute module sources."""

import linecache
import sys
from importlib.machinery import ModuleSpec
from types import ModuleType

from .classes import NativeClasses
from .functions import FunctionFactory, identifier


def install(modules, invoke) -> None:
    functions = FunctionFactory(invoke)
    classes = NativeClasses(invoke, functions)
    installed = {}
    declared = set()
    pending = []

    for name, doc, _, records, class_records in modules:
        if name in declared:
            raise ValueError(f"Swift module {name!r} was declared twice")

        module = _declare(name, doc, installed)
        declared.add(name)
        for record in records:
            value = functions.create(record, module)
            if value.__name__ in module.__dict__:
                raise ValueError(f"Python name {name}.{value.__name__} already exists")

            setattr(module, value.__name__, value)

        pending.extend(classes.prepare(record, module) for record in class_records)

    classes.install(pending)
    _execute_sources(modules, installed)


def _declare(name: str, doc: str | None, installed: dict[str, ModuleType]) -> ModuleType:
    parts = [identifier(part) for part in name.split(".")]
    parent = None
    for depth, part in enumerate(parts, 1):
        path = ".".join(parts[:depth])
        if path not in installed:
            if path in sys.modules:
                raise ValueError(f"Python module {path!r} already exists")

            module = ModuleType(path)
            module.__package__ = path.rpartition(".")[0]
            module.__spec__ = ModuleSpec(path, loader=None)
            installed[path] = module
            sys.modules[path] = module
            if parent is not None:
                if part in parent.__dict__:
                    raise ValueError(f"Python name {path!r} already exists")

                parent.__path__ = []
                parent.__package__ = parent.__name__
                parent.__spec__.submodule_search_locations = parent.__path__
                setattr(parent, part, module)

        parent = installed[path]

    module = installed[name]
    module.__doc__, module.__file__ = doc, f"<swift:{name}>"
    return module


def _execute_sources(modules, installed: dict[str, ModuleType]) -> None:
    for name, _, source, _, _ in modules:
        if source is None:
            continue

        module = installed[name]
        filename = f"<swift:{name}:source>"
        module.__file__ = filename
        linecache.cache[filename] = (len(source), None, source.splitlines(keepends=True), filename)
        exec(compile(source, filename, "exec"), module.__dict__)
