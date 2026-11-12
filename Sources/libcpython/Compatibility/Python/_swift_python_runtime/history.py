"""Lazy input source history and a session-local cache of expression results."""

from collections.abc import Mapping


class _Inputs(Mapping):
    def __init__(self, read) -> None:
        self._read = read

    def __getitem__(self, number: int) -> str:
        if not isinstance(number, int):
            raise TypeError("Input history keys must be execution numbers")
        return self._read("get", number)

    def __iter__(self):
        return iter(self._read("keys"))

    def __len__(self) -> int:
        return self._read("count")


class History:
    def __init__(self, output_limit: int, read) -> None:
        self.inputs = _Inputs(read)
        self.outputs = {}
        self.output_limit = output_limit

    def bind(self, namespace: dict) -> None:
        namespace["In"] = self.inputs
        namespace["Out"] = self.outputs

    def remember(self, number: int, value) -> None:
        if value is None:
            return
        self.outputs[number] = value
        if self.output_limit > 0:
            while len(self.outputs) > self.output_limit:
                del self.outputs[next(iter(self.outputs))]
