"""Resolve requirements against the session's selected package sources."""

import hashlib
import json
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterator
from dataclasses import replace

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name
from packaging.version import Version
from resolvelib import AbstractProvider, BaseReporter, ResolutionImpossible, Resolver

from .candidate import Candidate, Distribution, Wheel
from .configuration import ABI, MARKER_ENVIRONMENT, Configuration, supports_python
from .paths import walk_files
from .requirements import _requirements
from .wheels import WheelCache


def _has_exact_pin(version: Version, requirements: list[Requirement]) -> bool:
    return any(
        spec.operator in ("==", "===")
        and "*" not in spec.version
        and spec.contains(version, prereleases=True)
        for requirement in requirements
        for spec in requirement.specifier
    )


def _dependencies_for_extras(values: list[str], extras: frozenset[str]) -> list[Requirement]:
    dependencies = []
    extras = extras | {""}

    for value in values:
        requirement = Requirement(value)
        if requirement.url:
            raise ValueError(f"Source dependency is unsupported: {value}")

        if requirement.marker is None or any(
            requirement.marker.evaluate({**MARKER_ENVIRONMENT, "extra": extra}) for extra in extras
        ):
            # The resolver receives dependencies after evaluating the parent's markers.
            requirement.marker = None
            dependencies.append(requirement)

    return dependencies


class Provider(AbstractProvider):
    def __init__(
        self, configuration: Configuration, installed: dict, update: bool, pinned: set[str]
    ) -> None:
        self.configuration = configuration

        self.installed = installed
        self.update = update
        self.pinned = pinned

        self.wheels = WheelCache(configuration.cache)
        self._index_cache = {}
        self._wheel_metadata = {}

    def identify(self, requirement_or_candidate: Requirement | Candidate) -> str:
        return canonicalize_name(requirement_or_candidate.name)

    def get_preference(
        self,
        identifier: str,
        resolutions,
        candidates,
        information,
        backtrack_causes,
    ) -> tuple[bool, str]:
        return (identifier not in self.configuration.base, identifier)

    def is_satisfied_by(self, requirement: Requirement, candidate: Candidate) -> bool:
        return (
            canonicalize_name(requirement.name) == candidate.name
            and requirement.extras.issubset(candidate.extras)
            and requirement.specifier.contains(candidate.version, prereleases=None)
        )

    def _index_files(self, name: str) -> list[dict]:
        cached = self._index_cache.get(name)
        if cached is not None:
            return cached

        files = self._fetch_index_files(name)
        self._index_cache[name] = files
        return files

    def _fetch_index_files(self, name: str) -> list[dict]:
        url = urllib.parse.urljoin(self.configuration.index, name + "/")
        if urllib.parse.urlsplit(url).scheme == "file":
            url += "index.json"

        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.pypi.simple.v1+json",
                "User-Agent": "swift-python",
            },
        )

        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = json.load(response)
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            return []
        except urllib.error.URLError as error:
            if not isinstance(error.reason, FileNotFoundError):
                raise
            return []
        return data["files"]

    def _index_wheels(self, name: str, requirements: list[Requirement]) -> Iterator[Wheel]:
        for file in self._index_files(name):
            filename = file["filename"]

            try:
                version = Wheel.version_for(name, filename)
            except ValueError:
                continue

            if not supports_python(file.get("requires-python")):
                continue

            if file.get("yanked") and not _has_exact_pin(version, requirements):
                continue

            digest = file.get("hashes", {}).get("sha256", "")
            url = urllib.parse.urljoin(self.configuration.index + name + "/", file["url"])
            yield Wheel(name, version, filename, url, digest)

    def _candidates(
        self, name: str, extras: frozenset[str], requirements: list[Requirement]
    ) -> Iterator[Candidate]:
        if name in self.configuration.base:
            version = Version(self.configuration.base[name]["version"])
            yield Candidate(Distribution(name, version), extras)
            return

        previous = self.installed.get(name)
        if previous and not self.update:
            yield Candidate(Wheel.from_record(name, previous), extras)
            if name in self.pinned:
                return

        wheels = sorted(
            self._index_wheels(name, requirements),
            key=lambda wheel: (wheel.version, wheel.filename),
            reverse=True,
        )
        yield from (Candidate(wheel, extras) for wheel in wheels)

    def find_matches(self, identifier: str, requirements, incompatibilities):
        # The resolver can advance before it starts consuming the returned generator.
        requirements = list(requirements[identifier])
        extras = frozenset(extra for requirement in requirements for extra in requirement.extras)
        excluded = set(incompatibilities[identifier])

        return self._matching_candidates(identifier, extras, requirements, excluded)

    def _matching_candidates(
        self,
        name: str,
        extras: frozenset[str],
        requirements: list[Requirement],
        excluded: set[Candidate],
    ) -> Iterator[Candidate]:
        for candidate in self._candidates(name, extras, requirements):
            if candidate in excluded:
                continue

            excluded.add(candidate)
            if all(self.is_satisfied_by(requirement, candidate) for requirement in requirements):
                yield candidate

    def _metadata(self, wheel: Wheel):
        metadata = self._wheel_metadata.get(wheel.digest)
        if metadata is None:
            metadata = self.wheels.metadata(wheel)
            self._wheel_metadata[wheel.digest] = metadata
        return metadata

    def get_dependencies(self, candidate: Candidate) -> list[Requirement]:
        distribution = candidate.distribution
        if isinstance(distribution, Wheel):
            metadata = self._metadata(distribution)
            if not supports_python(metadata.get("Requires-Python")):
                # An impossible requirement makes resolvelib reject this wheel and try another.
                return [Requirement(candidate.name + "==0,!=0")]

            values = metadata.get_all("Requires-Dist", [])
        else:
            values = self.configuration.base[candidate.name]["requires"]

        return _dependencies_for_extras(values, candidate.extras)


def _prepare_distribution(cache: WheelCache, wheel: Wheel) -> dict:
    site = cache.unpack(wheel) / "site-packages"
    files = sorted(str(path.relative_to(site)) for path in walk_files(site))
    return {"record": wheel.record(), "directory": str(site), "files": files}


def _describe_conflict(provider: Provider, cause) -> str:
    requirement = cause.requirement
    message = str(requirement)
    name = canonicalize_name(requirement.name)

    source = provider.configuration.base.get(name)
    if name in provider.pinned:
        source = provider.installed[name]
    if source is not None:
        message += f" (selected source provides {name}=={source['version']})"

    if parent := cause.parent:
        message = f"{parent.name}=={parent.version} requires {message}"
    return message


def _resolve_wheels(provider: Provider, roots: list[Requirement]) -> dict[str, Wheel]:
    try:
        resolution = Resolver(provider, BaseReporter()).resolve(roots, max_rounds=1000)
    except ResolutionImpossible as error:
        causes = ", ".join(_describe_conflict(provider, cause) for cause in error.causes)
        raise ValueError(f"Package dependency conflict: {causes}") from None

    return {
        name: candidate.distribution
        for name, candidate in resolution.mapping.items()
        if isinstance(candidate.distribution, Wheel)
    }


def _resolution_fingerprint(
    requirements: list[str], configuration: Configuration, overrides: set[str]
) -> str:
    signature = {
        "requirements": requirements,
        "base": configuration.base,
        "overrides": sorted(overrides),
        "abi": ABI,
        "index": configuration.index,
    }
    return hashlib.sha256(json.dumps(signature, sort_keys=True).encode()).hexdigest()


def _select_overrides(request: dict, base: dict) -> tuple[set[str], set[str]]:
    local = request["local"]
    installed = request["installed"]
    overrides = set(installed).difference(request["removed"])

    # An existing local override stays selected until an explicit change replaces it.
    pinned = set() if request["update"] else set(overrides)
    for requirement in _requirements(local):
        name = canonicalize_name(requirement.name)
        if (previous := installed.get(name)) and not requirement.specifier.contains(
            previous["version"], prereleases=None
        ):
            pinned.discard(name)
        if (source := base.get(name)) and not requirement.specifier.contains(
            source["version"], prereleases=None
        ):
            overrides.add(name)

    overrides.intersection_update(base)
    pinned.intersection_update(overrides)
    return overrides, pinned


def _check_base_collisions(distributions: dict, base: dict) -> None:
    base_files = {file for package in base.values() for file in package["files"]}
    if not base_files:
        return

    for distribution in distributions.values():
        for file in distribution["files"]:
            if file in base_files:
                raise ValueError(f"Local package file conflicts with the application base: {file}")


def _changes_installed_wheels(wheels: dict[str, Wheel], installed: dict) -> bool:
    return wheels.keys() != installed.keys() or any(
        wheel.digest != installed[name]["digest"] for name, wheel in wheels.items()
    )


def prepare(request: dict, configuration: Configuration) -> dict:
    overrides, pinned = _select_overrides(request, configuration.base)
    installed = request["installed"]
    requirements = request["requirements"] + request["local"]
    fingerprint = _resolution_fingerprint(requirements, configuration, overrides)
    if request.get("fingerprint") == fingerprint and not request["update"]:
        return {"status": "unchanged"}

    roots = _requirements(requirements + list(configuration.base))
    effective = replace(
        configuration,
        base={
            name: package for name, package in configuration.base.items() if name not in overrides
        },
    )
    provider = Provider(effective, installed, request["update"], pinned)
    wheels = _resolve_wheels(provider, roots)

    if not request["replace_files"] and _changes_installed_wheels(wheels, installed):
        return {"status": "requires_reset"}

    distributions = {
        name: _prepare_distribution(provider.wheels, wheel)
        for name, wheel in sorted(wheels.items())
    }
    _check_base_collisions(distributions, effective.base)
    return {"status": "resolved", "fingerprint": fingerprint, "distributions": distributions}
