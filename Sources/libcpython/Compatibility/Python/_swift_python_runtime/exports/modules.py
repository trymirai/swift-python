"""Declare the selected module graph, install exports and execute module sources."""

import ast
import sys
from importlib.machinery import ModuleSpec
from types import ModuleType

from .classes import NativeClasses
from .functions import (
    FunctionFactory,
    execute_source,
    import_source,
    module_parts,
    require_free_name,
)


def install(modules, invoke) -> None:
    functions = FunctionFactory(invoke)
    classes = NativeClasses(invoke, functions)

    # Track explicit declarations separately from parents created on demand.
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

    # Bases can come from other Swift modules. Resolve them before any module source runs.
    classes.install(pending)
    _execute_sources(modules, installed, functions.imports)


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
    parts = module_parts(name)
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


def _execute_sources(
    modules, installed: dict[str, ModuleType], imports: dict[str, set[str]]
) -> None:
    for name, _, source, _, _ in modules:
        dependencies = imports.pop(name, ())
        if source is None:
            continue

        module = installed[name]
        filename = f"<swift:{name}:source>"
        module.__file__ = filename

        header = import_source(
            {
                dependency: None
                for dependency in dependencies
                if dependency.partition(".")[0] not in module.__dict__
            }
        )
        if header:
            source = _insert_imports(source, header, filename)

        execute_source(source, filename, module.__dict__)


def _prologue_length(tree: ast.Module) -> int:
    # The docstring and future imports must stay ahead of regular imports.
    index = int(ast.get_docstring(tree, clean=False) is not None)
    while index < len(tree.body):
        statement = tree.body[index]
        if not isinstance(statement, ast.ImportFrom) or statement.module != "__future__":
            break
        index += 1
    return index


def _insert_imports(source: str, header: str, filename: str) -> str:
    tree = ast.parse(source, filename)
    index = _prologue_length(tree)
    if index == 0:
        return f"{header}\n\n{source}"

    prologue = tree.body[index - 1]
    next_statement = tree.body[index] if index < len(tree.body) else None

    lines = source.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    line = prologue.end_lineno
    if next_statement is not None and next_statement.lineno == line:
        before, after = _split_inline_prologue(lines[line - 1], prologue, next_statement)
        lines[line - 1 : line] = [before, header, "", after]
    else:
        lines[line:line] = [header, ""]

    return "\n".join(lines)


def _split_inline_prologue(
    line: str, prologue: ast.stmt, next_statement: ast.stmt
) -> tuple[str, str]:
    # AST column offsets count UTF-8 bytes.
    text = line.encode()
    before = text[: prologue.end_col_offset].decode()
    after = text[next_statement.col_offset :].decode()
    return before, after
