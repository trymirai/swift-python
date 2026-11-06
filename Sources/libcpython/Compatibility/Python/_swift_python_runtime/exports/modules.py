"""Declare the selected module graph, install exports and execute module sources."""

import sys
from importlib.machinery import ModuleSpec
from types import ModuleType

from .classes import NativeClasses
from .functions import FunctionFactory, cache_source, identifier, require_free_name


def install(modules, invoke) -> None:
    functions = FunctionFactory(invoke)
    classes = NativeClasses(invoke, functions)

    # Declaring a submodule also installs any implicit parents.
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
            require_free_name(module, value.__name__)
            setattr(module, value.__name__, value)

        pending.extend(classes.prepare(record, module) for record in class_records)

    classes.install(pending)
    _execute_sources(modules, installed)


def _link_submodule(parent: ModuleType, name: str, child: ModuleType) -> None:
    if name in parent.__dict__:
        raise ValueError(f"Python name {child.__name__!r} already exists")

    parent.__path__ = []
    parent.__package__ = parent.__name__
    parent.__spec__.submodule_search_locations = parent.__path__
    setattr(parent, name, child)


def _install_module(path: str, installed: dict[str, ModuleType]) -> ModuleType:
    if path in sys.modules:
        raise ValueError(f"Python module {path!r} already exists")

    module = ModuleType(path)
    module.__package__ = path.rpartition(".")[0]
    module.__spec__ = ModuleSpec(path, loader=None)

    installed[path] = module
    sys.modules[path] = module
    return module


def _declare(name: str, doc: str | None, installed: dict[str, ModuleType]) -> ModuleType:
    parts = [identifier(part) for part in name.split(".")]
    parent = None
    path = ""

    for part in parts:
        path = f"{path}.{part}" if path else part
        module = installed.get(path)
        if module is None:
            module = _install_module(path, installed)
            if parent is not None:
                _link_submodule(parent, part, module)

        parent = module

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
        cache_source(filename, source)
        exec(compile(source, filename, "exec"), module.__dict__)
