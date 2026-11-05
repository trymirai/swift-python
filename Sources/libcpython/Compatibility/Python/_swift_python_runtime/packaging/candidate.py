"""A resolved distribution candidate and its immutable wheel identity."""

from dataclasses import dataclass

from packaging.version import Version


@dataclass(frozen=True)
class Candidate:
    name: str
    version: Version
    extras: frozenset = frozenset()
    url: str = ""
    digest: str = ""
    filename: str = ""
    provided: bool = False
