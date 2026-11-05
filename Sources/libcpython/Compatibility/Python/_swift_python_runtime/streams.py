"""Capture Python streams in memory or append them to host files."""

import contextlib
import io
import sys

# Host-selected streams stay outside a consumer's managed-file transactions.
# Save the original opener before extension modules can replace ordinary open().
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
    def __init__(self, path: str | None, control=None, stream: str | None = None) -> None:
        self.memory = _MemoryOutput() if path is None else None
        raw = self.memory if self.memory is not None else _open(path, "ab", buffering=0)

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
        for index in range(0, len(text), 16 * 1024):
            part = text[index : index + 16 * 1024]
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

    def fileno(self) -> int:
        if self.target is None:
            raise io.UnsupportedOperation("No execution stream is attached")

        return self.target.fileno()

    @property
    def buffer(self) -> io.BufferedIOBase:
        if self.target is None:
            raise io.UnsupportedOperation("No execution stream is attached")

        return self.target.buffer


_stdout = _Stream(sys.stdout)
_stderr = _Stream(sys.stderr)


def install() -> None:
    sys.stdout = sys.__stdout__ = _stdout
    sys.stderr = sys.__stderr__ = _stderr
    sys.stdin = sys.__stdin__ = io.TextIOWrapper(io.BytesIO(), encoding="utf-8")


@contextlib.contextmanager
def capture(control):
    configuration = control("streams")
    callback = control if control("capture") else None

    with contextlib.ExitStack() as stack:
        stdout = stack.enter_context(_Output(configuration["stdout"], callback, "stdout"))
        stderr = stack.enter_context(_Output(configuration["stderr"], callback, "stderr"))
        diagnostic_path = configuration["traceback"]
        diagnostic = (
            stack.enter_context(_open(diagnostic_path, "ab"))
            if diagnostic_path is not None
            else None
        )

        input_path = configuration["stdin"]
        stdin = stack.enter_context(
            _open(input_path, "r", encoding="utf-8")
            if input_path is not None
            else io.TextIOWrapper(io.BytesIO(), encoding="utf-8")
        )

        for name, value in (
            ("stdin", stdin),
            ("__stdin__", stdin),
            ("stdout", _stdout),
            ("__stdout__", _stdout),
            ("stderr", _stderr),
            ("__stderr__", _stderr),
        ):
            previous = getattr(sys, name)
            setattr(sys, name, value)
            stack.callback(setattr, sys, name, previous)

        previous_stdout, previous_stderr = _stdout.target, _stderr.target
        _stdout.target, _stderr.target = stdout, stderr
        stack.callback(setattr, _stdout, "target", previous_stdout)
        stack.callback(setattr, _stderr, "target", previous_stderr)

        yield stdout, stderr, diagnostic
