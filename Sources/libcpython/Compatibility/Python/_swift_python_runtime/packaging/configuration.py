"""Immutable interpreter facts and the application-supplied package base."""

import email.parser
import importlib.metadata
import sys
import tempfile
import urllib.parse
from dataclasses import dataclass
from pathlib import Path

from packaging.markers import default_environment
from packaging.specifiers import SpecifierSet
from packaging.tags import parse_tag, sys_tags
from packaging.utils import canonicalize_name
from packaging.version import Version

from .paths import absolute_path

PYTHON_VERSION = Version(sys.version.split()[0])
MARKER_ENVIRONMENT = default_environment()
SUPPORTED_TAGS = frozenset(sys_tags())
ABI = [sys.implementation.cache_tag, sys.platform, getattr(sys.implementation, "_multiarch", "")]


@dataclass(frozen=True)
class Configuration:
    cache: Path
    index: str

    base: dict


def supports_python(specifier: str | None) -> bool:
    return not specifier or SpecifierSet(specifier).contains(PYTHON_VERSION, prereleases=True)


def _distribution(distribution: importlib.metadata.Distribution) -> dict:
    metadata = distribution.metadata
    name = metadata["Name"]
    version = metadata["Version"] if name else None
    if not version:
        raise ValueError("Application package metadata must contain Name and Version")

    requires_python = metadata.get("Requires-Python")
    if not supports_python(requires_python):
        raise ValueError(f"Application package {name} requires Python {requires_python}")

    wheel = distribution.read_text("WHEEL")
    if wheel:
        wheel_metadata = email.parser.Parser().parsestr(wheel)
        tags = set().union(*(parse_tag(tag) for tag in wheel_metadata.get_all("Tag", [])))
        if tags and not tags.intersection(SUPPORTED_TAGS):
            raise ValueError(f"Application package {name} has incompatible wheel tags")

    return {
        "name": canonicalize_name(name),
        "version": str(Version(version)),
        "requires": metadata.get_all("Requires-Dist", []),
    }


def _read_package_base(paths: list[str]) -> tuple[dict, set[str]]:
    base = {}
    base_files = set()
    for distribution in importlib.metadata.distributions(path=paths):
        record = _distribution(distribution)
        name = record["name"]
        if name in base:
            raise ValueError(f"Application package {name!r} is supplied by multiple sources")

        base[name] = record
        base_files.update(str(path) for path in distribution.files or ())

    return base, base_files


def _read_options(configuration: dict) -> tuple[Path, str]:
    cache = configuration.get("cache")
    if cache is None:
        cache = str(Path(tempfile.gettempdir()) / "swift-python-packages" / ABI[0])
    cache = absolute_path(cache)

    index = configuration["index"].rstrip("/") + "/"
    if urllib.parse.urlsplit(index).scheme not in ("https", "file"):
        raise ValueError("Package indexes must use HTTPS or a local file URL")

    return cache, index


def _check_source_paths(sources: list[dict]) -> None:
    for source in sources:
        if "directory" in source and not absolute_path(source["directory"]).is_dir():
            raise FileNotFoundError(source["directory"])

        if "archive" in source:
            absolute_path(source["archive"])


def load(configuration: dict, sources: list[dict], read) -> tuple[Configuration, dict]:
    from ..packages import install

    cache, index = _read_options(configuration)
    paths = install(sources, read)
    _check_source_paths(sources)

    base, base_files = _read_package_base(paths)
    configuration = Configuration(cache, index, base)
    return configuration, {
        "cache": str(cache),
        "abi": ABI,
        "base": {name: record["version"] for name, record in base.items()},
        "base_files": sorted(base_files),
    }
