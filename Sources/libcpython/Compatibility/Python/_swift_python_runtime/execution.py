"""Evaluate interactive blocks in an embedded interpreter."""

import ast
import importlib
import linecache
import sys
import traceback
import weakref
from contextlib import suppress
from types import CodeType

from .async_support import await_block
from .imports import update_imports
from .streams import capture
from .streams import install as install_streams


def _report_exception(exception: BaseException, stderr, control) -> str:
    # The first frame is the evaluator that compiled and ran this block.
    text = "".join(
        traceback.format_exception(type(exception), exception, exception.__traceback__.tb_next)
    )
    text = text.encode("utf-8", "backslashreplace").decode("utf-8")
    if not control("interrupted"):
        try:
            stderr.write(text)
        except OSError, ValueError:
            # Close here so a failed flush cannot mask the original exception during cleanup.
            with suppress(OSError, ValueError):
                stderr.close()
    return text


def _successful_script_exit(exception: BaseException) -> bool:
    return isinstance(exception, SystemExit) and (
        exception.code is None
        or (isinstance(exception.code, int) and int.__index__(exception.code) == 0)
    )


class _SourceCache:
    # Functions can outlive their execution block. Keep source until their code is released.
    def __init__(self) -> None:
        self._sources = {}
        self._block = 0

    def block_filename(self, requested: str | None) -> str:
        self._block += 1
        filename = requested if requested is not None else f"<python-{self._block}>"
        while filename in self._sources:
            filename = f"{filename}#{self._block}"
        return filename

    def remember(self, code: CodeType, source: str, filename: str) -> None:
        entry = (len(source), None, source.splitlines(keepends=True), filename)

        references = []
        live = 0

        def released(_) -> None:
            nonlocal live
            live -= 1
            if live == 0:
                self._sources.pop(filename, None)
                if linecache.cache.get(filename) is entry:
                    linecache.cache.pop(filename, None)

        # Any nested function can still appear in a traceback after this block returns.
        pending = [code]
        while pending:
            child = pending.pop()
            pending.extend(value for value in child.co_consts if isinstance(value, CodeType))
            references.append(weakref.ref(child, released))
            live += 1

        self._sources[filename] = references
        linecache.cache[filename] = entry


def configure(paths: list[str]) -> None:
    global evaluate, initialize, run_script, current_namespace

    update_imports((paths, []))
    install_streams()

    namespace = sys.modules["__main__"].__dict__
    sources = _SourceCache()

    def current_namespace() -> dict:
        return namespace

    def initialize(request: dict, unused, control) -> tuple[str, str, str]:
        nonlocal namespace

        with capture(control) as (stdout, stderr):
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

                    sources.remember(code, source, filename)
                    result = eval(code, namespace)
                    if result is not None:
                        import asyncio

                        asyncio.run(await_block(result, control))
            except BaseException as exception:
                failure = _report_exception(exception, stderr, control)

            return stdout.result(), stderr.result(), failure

    def execute(
        source: str,
        filename: str | None,
        control,
        arguments: list[str] | None = None,
    ) -> tuple[str, str, str]:
        filename = sources.block_filename(filename)

        with capture(control) as (stdout, stderr):
            # Interactive code can also replace sys.argv.
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

                sources.remember(code, source, filename)
                result = eval(code, namespace)
                if result is not None:
                    import asyncio

                    asyncio.run(await_block(result, control))
            except BaseException as exception:
                if arguments is None or not _successful_script_exit(exception):
                    failure = _report_exception(exception, stderr, control)
            finally:
                sys.argv = previous_argv

            return stdout.result(), stderr.result(), failure

    def evaluate(source: str, filename: str | None, control) -> tuple[str, str, str]:
        return execute(source, filename, control)

    def run_script(request: dict, filename: str | None, control) -> tuple[str, str, str]:
        return execute(request["source"], filename, control, request["arguments"])
