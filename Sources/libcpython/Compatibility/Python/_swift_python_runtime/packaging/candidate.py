"""A resolved distribution candidate and its immutable wheel identity."""

import re
import urllib.parse
from dataclasses import dataclass

from packaging.utils import parse_wheel_filename
from packaging.version import Version

from .configuration import SUPPORTED_TAGS


@dataclass(frozen=True)
class Distribution:
    name: str
    version: Version


@dataclass(frozen=True)
class Wheel(Distribution):
    filename: str

    url: str
    digest: str

    def __post_init__(self) -> None:
        if self.version != self.version_for(self.name, self.filename):
            raise ValueError(f"Wheel version does not match its filename: {self.filename}")

        if not isinstance(self.digest, str) or not re.fullmatch(r"[0-9a-f]{64}", self.digest):
            raise ValueError(f"Expected a SHA-256 hash for {self.filename}")

        if not isinstance(self.url, str) or "\0" in self.url:
            raise ValueError(f"Invalid wheel URL: {self.filename}")
        url = urllib.parse.urlsplit(self.url)
        if not (
            (url.scheme == "https" and url.hostname)
            or (url.scheme == "file" and url.path.startswith("/"))
        ):
            raise ValueError(f"Wheel URL must use HTTPS or a local file: {self.filename}")

    @staticmethod
    def version_for(name: str, filename: str) -> Version:
        if not isinstance(filename, str) or any(char in filename for char in ("/", "\\", "\0")):
            raise ValueError(f"Invalid wheel filename: {filename!r}")

        distribution, version, _, tags = parse_wheel_filename(filename)
        if (
            distribution != name
            or not tags.intersection(SUPPORTED_TAGS)
            or not all(tag.abi == "none" and tag.platform == "any" for tag in tags)
        ):
            raise ValueError(f"Incompatible wheel: {filename}")
        return version

    @classmethod
    def from_record(cls, name: str, record: dict) -> "Wheel":
        try:
            return cls(
                name,
                Version(record["version"]),
                record["filename"],
                record["url"],
                record["digest"],
            )
        except (KeyError, TypeError) as error:
            raise ValueError(f"Invalid saved wheel record for {name!r}") from error

    def record(self) -> dict:
        return {
            "version": str(self.version),
            "url": self.url,
            "digest": self.digest,
            "filename": self.filename,
        }


@dataclass(frozen=True)
class Candidate:
    distribution: Distribution
    extras: frozenset[str]

    @property
    def name(self) -> str:
        return self.distribution.name

    @property
    def version(self) -> Version:
        return self.distribution.version
