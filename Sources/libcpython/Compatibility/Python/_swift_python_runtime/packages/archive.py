"""Seekable archive readers and immutable ZIP indexes."""

import io
import zipfile

from .resources import Distribution


class Reader(io.RawIOBase):
    def __init__(self, size: int, read) -> None:
        self.size = size
        self.position = 0
        self._read = read

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def tell(self) -> int:
        return self.position

    def seek(self, offset: int, whence: int = 0) -> int:
        if whence == 0:
            origin = 0
        elif whence == 1:
            origin = self.position
        else:
            origin = self.size

        position = offset + origin
        if whence not in (0, 1, 2) or position < 0:
            raise ValueError("Invalid archive position")

        self.position = position
        return position

    def read(self, size: int = -1) -> bytes:
        if self.position >= self.size:
            return b""

        count = max(0, self.size - self.position)
        if size >= 0:
            count = min(count, size)

        data = self._read(self.position, count)
        self.position += len(data)
        return data


class Archive:
    def __init__(self, root: str, reader) -> None:
        self.root = root
        self.zip = zipfile.ZipFile(reader)
        self.names = frozenset(self.zip.namelist())

        if any(name.startswith("/") or ".." in name.split("/") for name in self.names):
            raise ValueError("Invalid package archive path")

        if any(name.endswith((".so", ".dylib", ".pyd", ".dll")) for name in self.names):
            raise ImportError("Embedded archives support Python code and resources only")

    def distributions(self, name: str | None = None):
        for path in sorted(self.names):
            if path.endswith(".dist-info/METADATA") and path.count("/") == 1:
                distribution = Distribution(self, path.rpartition("/")[0])
                if name is None or normalize_name(distribution.metadata["Name"]) == normalize_name(
                    name
                ):
                    yield distribution


def normalize_name(name: str) -> str:
    import re

    return re.sub(r"[-_.]+", "-", name).lower()
