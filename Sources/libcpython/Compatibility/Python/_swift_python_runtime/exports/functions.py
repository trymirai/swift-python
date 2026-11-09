"""Generate Python callables with Swift argument defaults and async bridging."""

import keyword
import linecache
from inspect import Parameter, Signature
from types import ModuleType

from ..async_support import wait_for_pipe


class _SwiftDefault:
    def __repr__(self) -> str:
        return "<Swift default>"


_DEFAULT = _SwiftDefault()


def identifier(name: str) -> str:
    if not name.isidentifier() or keyword.iskeyword(name) or name.startswith("__swift_"):
        raise ValueError(f"Invalid Python name {name!r}")

    return name


def is_reserved_member(name: str) -> bool:
    return name.startswith("__") or name in ("_swift_peer", "_swift_fields")


def require_free_name(module: ModuleType, name: str) -> None:
    if name in module.__dict__:
        raise ValueError(f"Python name {module.__name__}.{name} already exists")


def cache_source(filename: str, source: str) -> None:
    linecache.cache[filename] = (len(source), None, source.splitlines(keepends=True), filename)


def _bind_parameters(parameters, native: bool) -> tuple[str, str, list, list[Parameter]]:
    names = []
    declarations = []
    defaults = []

    visible = []

    for parameter, annotation, has_default, default in parameters:
        parameter = identifier(parameter)
        names.append(parameter)
        declaration = f"{parameter}: {annotation!r}" if annotation else parameter
        bound_default = _DEFAULT if native else default

        # Swift permits a default before a required parameter. Bind with a
        # sentinel and let the native binder check every required argument
        # before evaluating any Swift default expression.
        if native or has_default:
            declaration += f"=__swift_defaults[{len(defaults)}]"
            defaults.append(bound_default)

        declarations.append(declaration)
        visible.append(
            Parameter(
                parameter,
                Parameter.POSITIONAL_OR_KEYWORD,
                default=bound_default if has_default else Parameter.empty,
                annotation=annotation if annotation else Parameter.empty,
            )
        )

    arguments = ", ".join(names) + ("," if names else "")
    return arguments, ", ".join(declarations), defaults, visible


class FunctionFactory:
    def __init__(self, invoke) -> None:
        self._invoke = invoke

    def create(self, record, module: ModuleType, *, member: bool = False):
        name, documentation, returns, asynchronous, parameters, native, index = record
        name = identifier(name)
        if member and is_reserved_member(name):
            raise ValueError("Native classes do not export Python special methods")

        arguments, declarations, defaults, visible = _bind_parameters(parameters, native)

        expression = (
            f"await __swift_call({index}, ({arguments}))"
            if asynchronous
            else f"__swift_invoke('call', {index}, ({arguments}))"
        )
        filename = f"<swift:{module.__name__}.{name}>"
        source = (
            f"{'async ' if asynchronous else ''}def {name}({declarations})"
            f"{f' -> {returns!r}' if returns else ''}:\n"
            f"    {documentation!r}\n    return {expression}\n"
        )
        scope = {
            "__name__": module.__name__,
            "__swift_defaults": defaults,
            "__swift_call": self.call,
            "__swift_invoke": self._invoke,
        }

        cache_source(filename, source)
        exec(compile(source, filename, "exec"), scope)

        result = scope[name]
        del scope["__swift_defaults"]
        result.__signature__ = Signature(
            visible, return_annotation=returns or Signature.empty, __validate_parameters__=False
        )

        return result

    async def call(self, index: int, arguments: tuple):
        descriptor, ticket = self._invoke("start", index, arguments)

        try:
            await wait_for_pipe(descriptor)
            return self._invoke("take", ticket)
        finally:
            self._invoke("cancel", ticket)
