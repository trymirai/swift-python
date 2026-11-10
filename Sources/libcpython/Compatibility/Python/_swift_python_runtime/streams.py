"""Capture Python streams in memory or append them to host files."""

import contextlib
import io
import sys

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


class _Output(io.TextIOWrapper):
    def __init__(self, descriptor: int | None, control=None, stream: str | None = None) -> None:
        self.memory = _MemoryOutput() if descriptor is None else None
        raw = (
            self.memory
            if self.memory is not None
            else _open(descriptor, "ab", buffering=0, closefd=False)
        )

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
    # Keep this identity stable: logging handlers retain streams across REPL blocks.
    encoding = "utf-8"
    errors = "backslashreplace"

    def __init__(self, fallback) -> None:
        self.target = fallback

    def writable(self) -> bool:
        return True

    def write(self, text: str) -> int:
        if self.target is None:
            return len(text)

        return self.target.write(text)

    def flush(self) -> None:
        if self.target is not None and not self.target.closed:
            self.target.flush()

    def close(self) -> None:
        if self.target is not None:
            self.target.close()

    def _attached_target(self):
        if self.target is None:
            raise io.UnsupportedOperation("No execution stream is attached")

        return self.target

    def fileno(self) -> int:
        return self._attached_target().fileno()

    @property
    def buffer(self) -> io.BufferedIOBase:
        return self._attached_target().buffer


_stdout = _Stream(sys.stdout)
_stderr = _Stream(sys.stderr)


def _input_stream(descriptor: int | None) -> io.TextIOBase:
    if descriptor is None:
        return io.TextIOWrapper(io.BytesIO(), encoding="utf-8")

    return _open(descriptor, "r", encoding="utf-8", closefd=False)


def install() -> None:
    sys.stdout = sys.__stdout__ = _stdout
    sys.stderr = sys.__stderr__ = _stderr
    sys.stdin = sys.__stdin__ = _input_stream(None)


@contextlib.contextmanager
def capture(control, configuration: dict[str, int]):
    callback = control if control("capture") else None

    with contextlib.ExitStack() as stack:
        stdout = stack.enter_context(_Output(configuration.get("stdout"), callback, "stdout"))
        stderr = stack.enter_context(_Output(configuration.get("stderr"), callback, "stderr"))
        stdin = stack.enter_context(_input_stream(configuration.get("stdin")))

        bindings = (
            (sys, "stdin", stdin),
            (sys, "__stdin__", stdin),
            (sys, "stdout", _stdout),
            (sys, "__stdout__", _stdout),
            (sys, "stderr", _stderr),
            (sys, "__stderr__", _stderr),
            (_stdout, "target", stdout),
            (_stderr, "target", stderr),
        )
        for owner, attribute, value in bindings:
            previous = getattr(owner, attribute)
            setattr(owner, attribute, value)
            stack.callback(setattr, owner, attribute, previous)

        yield stdout, stderr
