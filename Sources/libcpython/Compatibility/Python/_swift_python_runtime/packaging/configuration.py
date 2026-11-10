"""Immutable interpreter facts and a session's supplied package base."""

import email.parser
import importlib.metadata
import sys
import tempfile
import urllib.parse
from dataclasses import dataclass, replace
from pathlib import Path
from sysconfig import get_path

from packaging.markers import default_environment
from packaging.specifiers import SpecifierSet
from packaging.tags import parse_tag, sys_tags
from packaging.version import Version

from ..packages import distribution_files, load_sources, select_distributions
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


def _check_wheel_tags(distribution: importlib.metadata.Distribution, name: str) -> None:
    wheel = distribution.read_text("WHEEL")
    if not wheel:
        return

    metadata = email.parser.Parser().parsestr(wheel)
    tags = set().union(*(parse_tag(tag) for tag in metadata.get_all("Tag", [])))
    if tags and not tags.intersection(SUPPORTED_TAGS):
        raise ValueError(f"Package {name} has incompatible wheel tags")


def _distribution(distribution: importlib.metadata.Distribution) -> dict:
    metadata = distribution.metadata
    name = metadata["Name"]
    version = metadata["Version"] if name else None
    if not version:
        raise ValueError("Package metadata must contain Name and Version")

    requires_python = metadata.get("Requires-Python")
    if not supports_python(requires_python):
        raise ValueError(f"Package {name} requires Python {requires_python}")

    _check_wheel_tags(distribution, name)
    return {
        "version": str(Version(version)),
        "requires": metadata.get_all("Requires-Dist", []),
        "files": sorted(distribution_files(distribution)),
    }


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


def project_package_source(directory: str) -> str | None:
    project = absolute_path(directory).resolve()
    venv = str(project / ".venv")
    venv_packages = Path(get_path("purelib", scheme="venv", vars={"base": venv, "platbase": venv}))

    for candidate in (project / "site-packages", venv_packages):
        # A symlink can point outside the project even when the candidate path is under it.
        path = candidate.resolve()
        if path.is_relative_to(project) and path.is_dir():
            return str(path)
    return None


def with_sources(configuration: Configuration, sources: list[dict], read) -> Configuration:
    _check_source_paths(sources)
    selected, _ = select_distributions(load_sources(sources, read))
    base = {name: _distribution(distribution) for name, (_, distribution) in selected.items()}
    return replace(configuration, base=base)


def load(options: dict) -> Configuration:
    cache, index = _read_options(options)
    return Configuration(cache, index, {})


def describe(configuration: Configuration) -> dict:
    return {
        "cache": str(configuration.cache),
        "abi": ABI,
        "base": configuration.base,
    }
