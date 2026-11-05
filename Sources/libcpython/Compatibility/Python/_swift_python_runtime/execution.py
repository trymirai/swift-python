"""Evaluate interactive blocks in an embedded interpreter."""

import ast
import importlib
import linecache
import sys
import traceback
import weakref
from types import CodeType

from .async_support import await_block
from .imports import update_imports
from .streams import capture
from .streams import install as install_streams


def _record_traceback(exception: BaseException, diagnostic) -> str:
    text = "".join(
        traceback.format_exception(type(exception), exception, exception.__traceback__.tb_next)
    )
    data = text.encode("utf-8", "backslashreplace")
    if diagnostic is not None:
        diagnostic.write(data)
    return data.decode("utf-8")


def configure(paths: list[str]) -> None:
    global evaluate, initialize, run_script, current_namespace

    update_imports((paths, []))
    install_streams()

    namespace = sys.modules["__main__"].__dict__
    sources = {}
    block = 0

    def current_namespace() -> dict:
        return namespace

    def remember(code: CodeType, source: str, filename: str) -> None:
        entry = (len(source), None, source.splitlines(keepends=True), filename)
        references = []
        live = 0

        def released(reference) -> None:
            nonlocal live
            live -= 1
            if live == 0:
                sources.pop(filename, None)
                if linecache.cache.get(filename) is entry:
                    linecache.cache.pop(filename, None)

        work = [code]

        while work:
            current = work.pop()
            work.extend(value for value in current.co_consts if isinstance(value, CodeType))
            references.append(weakref.ref(current, released))
            live += 1

        sources[filename] = references
        linecache.cache[filename] = entry

    def initialize(request: dict, unused, control) -> tuple[str, str, str]:
        nonlocal namespace

        with capture(control) as (stdout, stderr, diagnostic):
            failure = ""
            try:
                if "module" in request:
                    module = importlib.import_module(request["module"])
                    # Functions and later assignments share the package's actual globals.
                    namespace = module.__dict__
                else:
                    source = request["source"]
                    filename = "<startup>"
                    code = compile(
                        source,
                        filename,
                        "exec",
                        flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT,
                        dont_inherit=True,
                    )
                    remember(code, source, filename)
                    result = eval(code, namespace)
                    if result is not None:
                        import asyncio

                        asyncio.run(await_block(result, control))
            except BaseException as exception:
                failure = _record_traceback(exception, diagnostic)

            return stdout.result(), stderr.result(), failure

    def execute(
        source: str,
        filename: str | None,
        control,
        arguments: list[str] | None = None,
    ) -> tuple[str, str, str]:
        nonlocal block
        block += 1
        if filename is None:
            filename = f"<python-{block}>"

        while filename in sources:
            filename = f"{filename}#{block}"

        with capture(control) as (stdout, stderr, diagnostic):
            previous_argv = sys.argv
            failure = ""

            try:
                if arguments is None:
                    tree = ast.parse(source, filename, "exec")
                    code = compile(
                        ast.Interactive(body=tree.body),
                        filename,
                        "single",
                        flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT,
                        dont_inherit=True,
                    )
                else:
                    namespace["__name__"] = "__main__"
                    namespace["__file__"] = filename
                    sys.argv = [filename, *arguments]
                    code = compile(source, filename, "exec", dont_inherit=True)

                remember(code, source, filename)
                result = eval(code, namespace)
                if result is not None:
                    import asyncio

                    asyncio.run(await_block(result, control))
            except BaseException as exception:
                successful_exit = (
                    arguments is not None
                    and isinstance(exception, SystemExit)
                    and (
                        exception.code is None
                        or (isinstance(exception.code, int) and int.__index__(exception.code) == 0)
                    )
                )

                if not successful_exit:
                    failure = _record_traceback(exception, diagnostic)
            finally:
                sys.argv = previous_argv

            return stdout.result(), stderr.result(), failure

    def evaluate(source: str, filename: str | None, control) -> tuple[str, str, str]:
        return execute(source, filename, control)

    def run_script(request: dict, filename: str | None, control) -> tuple[str, str, str]:
        return execute(request["source"], filename, control, request["arguments"])
