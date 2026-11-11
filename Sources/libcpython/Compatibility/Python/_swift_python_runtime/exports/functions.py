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


def module_parts(name: str) -> list[str]:
    return [identifier(part) for part in name.split(".")]


def is_reserved_member(name: str) -> bool:
    return name.startswith("__") or name in ("_swift_peer", "_swift_fields")


def require_free_name(module: ModuleType, name: str) -> None:
    if name in module.__dict__:
        raise ValueError(f"Python name {module.__name__}.{name} already exists")


def execute_source(source: str, filename: str, namespace: dict) -> None:
    # inspect and tracebacks need the generated source even if compilation fails.
    linecache.cache[filename] = (len(source), None, source.splitlines(keepends=True), filename)
    exec(compile(source, filename, "exec"), namespace)


def import_source(imports: dict[str, str | None]) -> str:
    return "\n".join(
        f"lazy import {name} as {alias}" if alias else f"lazy import {name}"
        for name, alias in sorted(imports.items())
    )


def _annotation(
    value, imports: dict[str, str | None], function_name: str
) -> tuple[str | None, str | None]:
    if value is None or not value[0]:
        return None, None

    text, names = value
    expression = text if names else repr(text)

    for module, name in names:
        identifier(name)
        root = module_parts(module)[0]

        # These names already have a meaning in the generated function's globals.
        needs_alias = root in (function_name, "__name__", "list", "dict")
        alias = f"__swift_import_{len(imports)}" if needs_alias else None
        alias = imports.setdefault(module, alias)
        if alias:
            expression = expression.replace(f"{module}.{name}", f"{alias}.{name}")

    return text, expression


def _bind_parameters(
    parameters, native: bool, imports: dict[str, str | None], function_name: str
) -> tuple[str, str, list, list[Parameter]]:
    names = []
    declarations = []

    defaults = []
    visible = []

    for parameter, annotation, has_default, default in parameters:
        parameter = identifier(parameter)
        names.append(parameter)

        display_annotation, expression = _annotation(annotation, imports, function_name)
        declaration = f"{parameter}: {expression}" if expression else parameter
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
                annotation=display_annotation or Parameter.empty,
            )
        )

    arguments = ", ".join(names) + ("," if names else "")
    return arguments, ", ".join(declarations), defaults, visible


class FunctionFactory:
    def __init__(self, invoke) -> None:
        self._invoke = invoke
        self.imports: dict[str, set[str]] = {}

    def create(self, record, module: ModuleType, *, member: bool = False):
        name, documentation, returns, asynchronous, parameters, native, index = record
        name = identifier(name)

        if member and is_reserved_member(name):
            raise ValueError("Native classes do not export Python special methods")

        imports = {}
        arguments, declarations, defaults, visible = _bind_parameters(
            parameters, native, imports, name
        )
        return_annotation, return_expression = _annotation(returns, imports, name)

        def function_source() -> str:
            call = (
                f"await __swift_call({index}, ({arguments}))"
                if asynchronous
                else f"__swift_invoke('call', {index}, ({arguments}))"
            )
            prefix = "async " if asynchronous else ""
            return_clause = f" -> {return_expression}" if return_expression else ""
            source = (
                f"{prefix}def {name}({declarations}){return_clause}:\n"
                f"    {documentation!r}\n    return {call}\n"
            )
            if imports:
                source = f"{import_source(imports)}\n\n{source}"

            return source

        source = function_source()
        if imports:
            self.imports.setdefault(module.__name__, set()).update(imports)

        scope = {
            "__name__": module.__name__,
            "__swift_defaults": defaults,
            "__swift_call": self.call,
            "__swift_invoke": self._invoke,
        }

        filename = f"<swift:{module.__name__}.{name}:{index}>"
        execute_source(source, filename, scope)

        result = scope.pop(name)
        del scope["__swift_defaults"]

        # The generated defaults accept any Swift parameter order. Show the original signature.
        result.__signature__ = Signature(
            visible,
            return_annotation=return_annotation or Signature.empty,
            __validate_parameters__=False,
        )

        return result

    async def call(self, index: int, arguments: tuple):
        import asyncio

        tasks = {}

        async def call_method(request):
            try:
                result = await request("call")
                request("return", result)
            except asyncio.CancelledError:
                request("cancel")
                raise
            except BaseException as error:
                request("raise", error)

        def dispatch_methods(requests):
            for request, task in tuple(tasks.items()):
                if not request("pending"):
                    task.cancel()

            for request in requests:
                if request("pending"):
                    task = asyncio.create_task(call_method(request))
                    tasks[request] = task
                    task.add_done_callback(lambda _, request=request: tasks.pop(request, None))

        async def cancel_methods():
            if tasks:
                for task in tasks.values():
                    task.cancel()
                await asyncio.gather(*tasks.values(), return_exceptions=True)

        descriptor, ticket = self._invoke("start", index, arguments)
        try:
            while True:
                await wait_for_pipe(descriptor)
                requests = self._invoke("poll", ticket)
                if requests is None:
                    return self._invoke("take", ticket)

                dispatch_methods(requests)
        finally:
            self._invoke("cancel", ticket)
            await cancel_methods()
