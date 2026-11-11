"""Resolve annotation references and collect imports without name collisions."""

import ast
import copy

BUILTINS = {
    "bool",
    "bytes",
    "dict",
    "float",
    "int",
    "list",
    "object",
    "property",
    "str",
    "tuple",
    "type",
}


class Annotations:
    def __init__(self, module: str, names: set[str]) -> None:
        self.module = module
        self.names = names
        self._source_imports = []
        self._module_aliases = {}
        self._imports = {}

    def resolve(self, value) -> str:
        if value is None or not value[0]:
            return "object"

        text, bindings = value
        node = ast.parse(text, mode="eval")
        return ast.unparse(_Annotation(self, bindings).visit(node).body)

    def import_module(self, module: str, preferred: str | None = None) -> str:
        if module in self._module_aliases:
            return self._module_aliases[module]

        root = module.split(".")[0]
        if preferred is None and root not in self.names:
            self._imports[module] = None
            return module

        alias = preferred or "_" + module.replace(".", "_")
        while alias in self.names:
            alias += "_"
        self.names.add(alias)
        self._imports[module] = alias
        self._module_aliases[module] = alias
        return alias

    def read_import(self, statement: ast.Import | ast.ImportFrom) -> None:
        if isinstance(statement, ast.ImportFrom) and statement.module == "__future__":
            return

        statement = copy.deepcopy(statement)
        if hasattr(statement, "is_lazy"):
            statement.is_lazy = False
        for alias in statement.names:
            name = alias.asname or alias.name.split(".")[0]
            self.names.add(name)
            if isinstance(statement, ast.Import):
                self._module_aliases[alias.name] = alias.asname or alias.name
            if not name.startswith("_") and "." not in alias.name:
                alias.asname = name
        self._source_imports.append(ast.unparse(statement))

    def render_imports(self) -> set[str]:
        imports = set(self._source_imports)
        imports.update(
            f"import {module}" + (f" as {alias}" if alias else "")
            for module, alias in self._imports.items()
        )
        return imports


class _Annotation(ast.NodeTransformer):
    def __init__(self, annotations: Annotations, bindings) -> None:
        self.annotations = annotations
        self.bindings = {f"{name}.{member}": (name, member) for name, member in bindings}

    def visit_Attribute(self, node):
        binding = self.bindings.get(ast.unparse(node))
        if binding is not None:
            module, name = binding
            if module == self.annotations.module:
                return ast.Name(id=name, ctx=ast.Load())
            prefix = self.annotations.import_module(module)
            return ast.parse(prefix + "." + name, mode="eval").body

        return self.generic_visit(node)

    def visit_Name(self, node):
        if node.id in BUILTINS and node.id in self.annotations.names:
            prefix = self.annotations.import_module("builtins", preferred="_builtins")
            return ast.Attribute(
                value=ast.Name(id=prefix, ctx=ast.Load()), attr=node.id, ctx=ast.Load()
            )

        return node
