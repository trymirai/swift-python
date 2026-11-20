"""Capture Python streams in memory or append them to host files."""

import contextlib
import io
import sys
from _swift_python import has_operation_access

# Borrow host-opened descriptors through the original io.open even if user code replaces it.
_open = io.open


class _MemoryOutput(io.RawIOBase):
    def __init__(self) -> None:
        # Keep the bytes available when user code closes its stream.
        self.data = bytearray()

    def writable(self) -> bool:
        return True

    def write(self, data) -> int:
        with memoryview(data).cast("B") as view:
            self.data.extend(view)
            return len(view)


class _DiscardedOutput(io.RawIOBase):
    def writable(self):
        return True

    def write(self, data):
        return memoryview(data).nbytes


class _Output(io.TextIOWrapper):
    def __init__(self, descriptor: int | None, control, stream: str, *, collect: bool) -> None:
        self.memory = None
        if descriptor is not None:
            raw = _open(descriptor, "ab", buffering=0, closefd=False)
        elif collect:
            raw = self.memory = _MemoryOutput()
        else:
            raw = _DiscardedOutput()

        try:
            super().__init__(
                io.BufferedWriter(raw),
                encoding="utf-8",
                errors="backslashreplace",
                newline="\n",
                write_through=True,
            )
        except BaseException:
            raw.close()
            raise

        self.control = control
        self.stream = stream

    def write(self, text: str) -> int:
        if not isinstance(text, str) or not text:
            return super().write(text)

        # Bound encoding and Swift callback copies even for a very large print().
        chunk_size = 16 * 1024
        for index in range(0, len(text), chunk_size):
            part = text[index : index + chunk_size]
            super().write(part)
            self.flush()
            if self.control is not None:
                self.control("write", self.stream, part)

        return len(text)

    def result(self) -> str:
        if self.memory is None:
            return ""

        if not self.closed:
            self.flush()
        return self.memory.data.decode("utf-8", "replace")


class _Stream(io.TextIOBase):
    # Logging handlers retain this stream across REPL blocks as its target changes.
    encoding = "utf-8"
    errors = "backslashreplace"

    def __init__(self, fallback) -> None:
        self.target = fallback

    def writable(self) -> bool:
        return True

    def write(self, text: str) -> int:
        if self.target is None or not has_operation_access():
            return len(text)

        return self.target.write(text)

    def flush(self) -> None:
        if has_operation_access() and self.target is not None and not self.target.closed:
            self.target.flush()

    def close(self) -> None:
        if has_operation_access() and self.target is not None:
            self.target.close()

    def _attached_target(self):
        if self.target is None:
            raise io.UnsupportedOperation("No execution stream is attached")

        return self.target

    def fileno(self) -> int:
        if not has_operation_access():
            raise io.UnsupportedOperation("The execution stream is closed")

        return self._attached_target().fileno()

    @property
    def buffer(self) -> io.BufferedIOBase:
        if not has_operation_access():
            return _DiscardedOutput()

        return self._attached_target().buffer


_stdout = _Stream(sys.stdout)
_stderr = _Stream(sys.stderr)


def _input_stream(descriptor: int | None) -> io.TextIOBase:
    if descriptor is None:
        return io.TextIOWrapper(io.BytesIO(), encoding="utf-8")

    return _open(descriptor, "r", encoding="utf-8", closefd=False)


class _Input:
    def __init__(self, stream):
        self._stream = stream
        self._empty = None

    def __getattr__(self, name):
        if has_operation_access():
            return getattr(self._stream, name)

        if self._empty is None or self._empty.closed:
            self._empty = _input_stream(None)
        return getattr(self._empty, name)

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if not line:
            raise StopIteration
        return line

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def install() -> None:
    sys.stdout = sys.__stdout__ = _stdout
    sys.stderr = sys.__stderr__ = _stderr
    sys.stdin = sys.__stdin__ = _input_stream(None)


@contextlib.contextmanager
def capture(control, configuration: dict[str, int], *, collect: bool = True):
    callback = control if control("capture") else None

    with contextlib.ExitStack() as stack:

        def output(name):
            stream = _Output(configuration.get(name), callback, name, collect=collect)
            return stack.enter_context(stream)

        def bind(owner, attribute, value):
            previous = getattr(owner, attribute)
            setattr(owner, attribute, value)
            stack.callback(setattr, owner, attribute, previous)

        stdout, stderr = output("stdout"), output("stderr")
        stdin = _Input(stack.enter_context(_input_stream(configuration.get("stdin"))))

        for name, stream in (("stdin", stdin), ("stdout", _stdout), ("stderr", _stderr)):
            bind(sys, name, stream)
            bind(sys, f"__{name}__", stream)

        bind(_stdout, "target", stdout)
        bind(_stderr, "target", stderr)
        yield stdout, stderr
