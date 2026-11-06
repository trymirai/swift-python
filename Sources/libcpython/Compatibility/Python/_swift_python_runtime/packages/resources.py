"""Read-only resources and distribution metadata inside application archives."""

from __future__ import annotations

import importlib.metadata
import io
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .archive import Archive


class Resource:
    def __init__(self, archive: "Archive", path: str) -> None:
        self.archive = archive
        self.path = path.strip("/")

    @property
    def name(self) -> str:
        return self.path.rsplit("/", 1)[-1]

    @property
    def _prefix(self) -> str:
        return self.path + "/" if self.path else ""

    def iterdir(self):
        prefix = self._prefix
        names = {
            name[len(prefix) :].split("/", 1)[0]
            for name in self.archive.names
            if name.startswith(prefix)
        }

        for name in sorted(names - {""}):
            yield self.joinpath(name)

    def is_file(self) -> bool:
        return self.path in self.archive.names and not self.path.endswith("/")

    def is_dir(self) -> bool:
        return self.archive.has_member_with_prefix(self._prefix)

    def exists(self) -> bool:
        # Distribution.files() also checks installed RECORD paths. Unlike the
        # Traversable resource protocol, that metadata API requires exists().
        return self.is_file() or self.is_dir()

    def joinpath(self, *parts: str) -> "Resource":
        components = self.path.split("/") if self.path else []

        for part in parts:
            for component in str(part).split("/"):
                if component in ("..", "."):
                    raise ValueError("Package resource paths must be relative")

                if component:
                    components.append(component)

        return Resource(self.archive, "/".join(components))

    def __truediv__(self, part: str) -> "Resource":
        return self.joinpath(part)

    def open(self, mode: str = "r", *args, **kwargs) -> io.BytesIO | io.TextIOWrapper:
        if mode not in ("r", "rt", "rb"):
            raise ValueError("Application packages are read-only")

        stream = io.BytesIO(self.read_bytes())
        return stream if mode == "rb" else io.TextIOWrapper(stream, *args, **kwargs)

    def read_bytes(self) -> bytes:
        try:
            return self.archive.zip.read(self.path)
        except KeyError:
            raise FileNotFoundError(str(self)) from None

    def read_text(self, encoding: str = "utf-8", errors: str = "strict") -> str:
        return self.read_bytes().decode(encoding, errors)

    def __str__(self) -> str:
        return self.archive.root + "/" + self.path


class ResourceReader:
    def __init__(self, archive: "Archive", path: str) -> None:
        self.resource = Resource(archive, path)

    def files(self) -> Resource:
        return self.resource

    def open_resource(self, name: str) -> io.BytesIO | io.TextIOWrapper:
        return self.resource.joinpath(name).open("rb")

    def resource_path(self, name: str) -> str:
        raise FileNotFoundError("This resource is embedded in the executable")

    def is_resource(self, name: str) -> bool:
        return self.resource.joinpath(name).is_file()

    def contents(self):
        return (entry.name for entry in self.resource.iterdir())


class Distribution(importlib.metadata.Distribution):
    def __init__(self, archive: "Archive", path: str) -> None:
        self.archive = archive
        self.path = path

    def read_text(self, filename: str) -> str | None:
        try:
            return Resource(self.archive, self.path + "/" + filename).read_text()
        except FileNotFoundError:
            return None

    def locate_file(self, path) -> Resource:
        # RECORD may refer to scripts outside site-packages. They are absent
        # from this archive and must be reported as missing, not read from disk.
        return Resource(self.archive, str(path))
