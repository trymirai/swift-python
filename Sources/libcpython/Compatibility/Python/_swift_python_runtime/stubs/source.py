"""Render Python declarations from their AST without retaining implementations."""

import ast
import copy

from .formatting import documentation, function, indent


def render_function(statement: ast.FunctionDef | ast.AsyncFunctionDef) -> list[str]:
    returns = (
        ast.unparse(statement.returns)
        if statement.returns is not None
        else ("None" if statement.name == "__init__" else "object")
    )
    type_parameters = getattr(statement, "type_params", [])
    name = statement.name
    if type_parameters:
        name += "[" + ", ".join(ast.unparse(p) for p in type_parameters) + "]"

    return function(
        name,
        _parameters(statement.args),
        returns,
        asynchronous=isinstance(statement, ast.AsyncFunctionDef),
        doc=ast.get_docstring(statement, clean=False),
        decorators=[ast.unparse(node) for node in statement.decorator_list if _is_decorator(node)],
    )


def _parameters(arguments: ast.arguments) -> list[str]:
    positional = [*arguments.posonlyargs, *arguments.args]
    optional = len(positional) - len(arguments.defaults)
    parameters = []

    for index, argument in enumerate(positional):
        parameters.append(_parameter(argument, index >= optional))
        if index + 1 == len(arguments.posonlyargs):
            parameters.append("/")

    if arguments.vararg is not None:
        parameters.append(_parameter(arguments.vararg, prefix="*"))
    elif arguments.kwonlyargs:
        parameters.append("*")
    parameters += [
        _parameter(argument, default is not None)
        for argument, default in zip(arguments.kwonlyargs, arguments.kw_defaults)
    ]
    if arguments.kwarg is not None:
        parameters.append(_parameter(arguments.kwarg, prefix="**"))

    return parameters


def _parameter(argument: ast.arg, default: bool = False, prefix: str = "") -> str:
    text = prefix + argument.arg
    if argument.annotation is not None or argument.arg not in ("self", "cls"):
        annotation = (
            ast.unparse(argument.annotation) if argument.annotation is not None else "object"
        )
        text += ": " + annotation

    return text + (" = ..." if default else "")


def _is_decorator(node: ast.expr) -> bool:
    if isinstance(node, ast.Name):
        return node.id in {
            "property",
            "classmethod",
            "staticmethod",
            "overload",
            "final",
            "abstractmethod",
        }
    if isinstance(node, ast.Attribute):
        return node.attr in {"setter", "deleter", "getter", "overload", "final", "abstractmethod"}

    return False


def render_class(statement: ast.ClassDef) -> list[str]:
    members = documentation(ast.get_docstring(statement, clean=False))
    for member in statement.body:
        if isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if members:
                members.append("")
            members += render_function(member)
        elif isinstance(member, ast.AnnAssign):
            members.append(ast.unparse(member.target) + ": " + ast.unparse(member.annotation))
        elif isinstance(member, ast.ClassDef):
            if members:
                members.append("")
            members += render_class(member)

    definition = copy.copy(statement)
    definition.body = [ast.Expr(value=ast.Constant(value=Ellipsis))]
    definition.decorator_list = []
    header = ast.unparse(ast.fix_missing_locations(definition)).splitlines()[0]
    return [header, *indent(members or ["..."])]
