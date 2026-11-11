"""Evaluate interactive blocks in an embedded interpreter."""

import ast
import importlib
import linecache
import os
import site
import sys
import traceback
import weakref
from contextlib import suppress
from types import CodeType

from .async_support import await_block
from .imports import import_project, update_imports
from .streams import capture
from .streams import install as install_streams


def _report_exception(exception: BaseException, stderr, control) -> str:
    # Skip the outer frame that catches the block's exception.
    text = "".join(
        traceback.format_exception(type(exception), exception, exception.__traceback__.tb_next)
    )
    text = text.encode("utf-8", "backslashreplace").decode("utf-8")

    if control("interrupted"):
        return text

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

        # A function defined by the block can outlive the outer code object.
        pending = [code]
        while pending:
            child = pending.pop()
            pending.extend(value for value in child.co_consts if isinstance(value, CodeType))
            references.append(weakref.ref(child, released))
            live += 1

        self._sources[filename] = references
        linecache.cache[filename] = entry


def configure(paths: list[str], package_paths: list[str]) -> None:
    global evaluate, initialize, run_script, current_namespace

    from .async_support import configure_restricted_loop

    update_imports((paths, []))
    install_streams()
    configure_restricted_loop()

    # Directory package sources support site startup files. Embedded archives use a virtual path.
    for path in package_paths:
        if os.path.isabs(path):
            site.addsitedir(path)
    site.setquit()
    site.setcopyright()
    site.sethelper()

    namespace = sys.modules["__main__"].__dict__
    sources = _SourceCache()

    def run_code(code: CodeType, source: str, filename: str, control) -> None:
        sources.remember(code, source, filename)
        result = eval(code, namespace)
        if result is not None:
            import asyncio

            asyncio.run(await_block(result, control))

    def current_namespace() -> dict:
        return namespace

    def initialize(request: dict, unused, control, streams: dict[str, int]) -> tuple[str, str, str]:
        nonlocal namespace

        with capture(control, streams) as (stdout, stderr):
            failure = ""

            try:
                if "source" in request:
                    source = request["source"]
                    filename = "<startup>"
                    code = compile(
                        source,
                        filename,
                        "exec",
                        flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT,
                        dont_inherit=True,
                    )
                    run_code(code, source, filename, control)
                else:
                    if "project" in request:
                        module = import_project(
                            request["project"], request["module"], request["import_paths"]
                        )
                    else:
                        module = importlib.import_module(request["module"])

                    # Functions and later assignments share the startup module's globals.
                    namespace = module.__dict__
            except BaseException as exception:
                failure = _report_exception(exception, stderr, control)

            return stdout.result(), stderr.result(), failure

    def execute(
        source: str,
        filename: str | None,
        control,
        streams: dict[str, int],
        arguments: list[str] | None = None,
    ) -> tuple[str, str, str]:
        filename = sources.block_filename(filename)

        with capture(control, streams) as (stdout, stderr):
            # Restore argv even if interactive code rebinds it.
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

                run_code(code, source, filename, control)
            except BaseException as exception:
                if arguments is None or not _successful_script_exit(exception):
                    failure = _report_exception(exception, stderr, control)
            finally:
                sys.argv = previous_argv

            return stdout.result(), stderr.result(), failure

    def evaluate(
        source: str, filename: str | None, control, streams: dict[str, int]
    ) -> tuple[str, str, str]:
        return execute(source, filename, control, streams)

    def run_script(
        request: dict, filename: str | None, control, streams: dict[str, int]
    ) -> tuple[str, str, str]:
        return execute(request["source"], filename, control, streams, request["arguments"])
