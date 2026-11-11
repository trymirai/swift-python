"""Render export metadata and static Python declarations as interface files."""

from ..exports.functions import module_parts
from .modules import Module


def generate(records) -> dict[str, str]:
    """Return relative interface paths and contents without importing user modules."""
    bindings, fields = _class_metadata(records)
    modules = {}

    for record in records:
        name = record[0]
        if name in modules:
            raise ValueError(f"Python module {name!r} was declared twice")
        modules[name] = Module(record, bindings, fields)

    _declare_parents(modules, bindings, fields)

    result = {}
    for name, module in sorted(modules.items()):
        path = name.replace(".", "/")
        path += "/__init__.pyi" if module.is_package else ".pyi"
        result[path] = module.render()

    return result


def _class_metadata(records) -> tuple[dict, dict]:
    bindings = {}
    fields = {}

    for module, _, _, _, classes in records:
        for key, _, name, _, _, _, properties in classes:
            bindings[key] = (module, name)
            fields[f"{module}.{name}"] = {
                name: getter[2][0] if getter[2] is not None else "object"
                for name, _, getter, _ in properties
            }

    return bindings, fields


def _declare_parents(modules: dict[str, Module], bindings: dict, fields: dict) -> None:
    for name in tuple(modules):
        parts = module_parts(name)
        for index in range(1, len(parts)):
            parent = ".".join(parts[:index])
            if parent not in modules:
                modules[parent] = Module((parent, None, None, [], []), bindings, fields)
            modules[parent].children.add(parts[index])
            modules[parent].is_package = True
