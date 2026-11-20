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
from .configuration import ABI, Configuration, supports_python
from .paths import walk_files
from .requirements import parse_requirements
from .wheels import WheelCache


def fingerprint(request: dict, configuration: Configuration) -> str:
    return _resolution_fingerprint(request["requirements"], configuration, set())


def prepare(request: dict, configuration: Configuration) -> dict:
    requested = request["requirements"]
    local = request["local"]
    local_roots = parse_requirements(local, configuration.markers)
    overrides, pinned = _select_overrides(request, configuration.base, local_roots)

    signature = _resolution_fingerprint(requested + local, configuration, overrides)
    if request.get("fingerprint") == signature and not request["update"]:
        return {"status": "unchanged"}

    roots = [
        *parse_requirements(requested, configuration.markers),
        *local_roots,
        *parse_requirements(list(configuration.base), configuration.markers),
    ]
    base = {name: package for name, package in configuration.base.items() if name not in overrides}
    installed = request["installed"]
    provider = Provider(replace(configuration, base=base), installed, request["update"], pinned)

    wheels = _resolve_wheels(provider, roots)
    if not request["replace_files"] and _changes_installed_wheels(wheels, installed):
        return {"status": "requires_reset"}

    distributions = _prepare_distributions(provider.wheels, wheels)
    _check_base_collisions(distributions, base)
    return {"status": "resolved", "fingerprint": signature, "distributions": distributions}


def _has_exact_pin(version: Version, requirements: list[Requirement]) -> bool:
    return any(
        spec.operator in ("==", "===")
        and "*" not in spec.version
        and spec.contains(version, prereleases=True)
        for requirement in requirements
        for spec in requirement.specifier
    )


def _dependencies_for_extras(
    values: list[str],
    extras: frozenset[str],
    markers: dict,
) -> list[Requirement]:
    dependencies = []
    extras = extras | {""}

    for value in values:
        requirement = Requirement(value)
        if requirement.url:
            raise ValueError(f"Source dependency is unsupported: {value}")

        if requirement.marker is None or any(
            requirement.marker.evaluate({**markers, "extra": extra}) for extra in extras
        ):
            # The resolver receives dependencies after evaluating the parent's markers.
            requirement.marker = None
            dependencies.append(requirement)

    return dependencies


class Provider(AbstractProvider):
    def __init__(
        self,
        configuration: Configuration,
        installed: dict,
        update: bool,
        pinned: set[str],
    ) -> None:
        self.configuration = configuration
        self.wheels = WheelCache(configuration)

        self.installed = installed
        self.update = update
        self.pinned = pinned

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

    def find_matches(self, identifier: str, requirements, incompatibilities):
        # The resolver can advance before it starts consuming the returned generator.
        constraints = list(requirements[identifier])
        extras = frozenset(extra for requirement in constraints for extra in requirement.extras)
        excluded = set(incompatibilities[identifier])

        def matches():
            for candidate in self._candidates(identifier, extras, constraints):
                if candidate in excluded:
                    continue

                excluded.add(candidate)
                if all(self.is_satisfied_by(requirement, candidate) for requirement in constraints):
                    yield candidate

        return matches()

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

        return _dependencies_for_extras(values, candidate.extras, self.configuration.markers)

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
        self,
        name: str,
        extras: frozenset[str],
        requirements: list[Requirement],
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

    def _metadata(self, wheel: Wheel):
        metadata = self._wheel_metadata.get(wheel.digest)
        if metadata is None:
            metadata = self.wheels.metadata(wheel)
            self._wheel_metadata[wheel.digest] = metadata
        return metadata


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
    requirements: list[str],
    configuration: Configuration,
    overrides: set[str],
) -> str:
    signature = {
        "requirements": requirements,
        "base": configuration.base,
        "overrides": sorted(overrides),
        "abi": ABI,
        "markers": configuration.markers,
        "index": configuration.index,
    }
    return hashlib.sha256(json.dumps(signature, sort_keys=True).encode()).hexdigest()


def _select_overrides(
    request: dict, base: dict, local_roots: list[Requirement]
) -> tuple[set[str], set[str]]:
    def excludes_version(requirement: Requirement, record: dict | None) -> bool:
        return bool(record) and not requirement.specifier.contains(
            record["version"], prereleases=None
        )

    installed = request["installed"]
    overrides = set(installed).difference(request["removed"])

    # An existing local override stays selected until an explicit change replaces it.
    pinned = set() if request["update"] else overrides.copy()
    for requirement in local_roots:
        name = canonicalize_name(requirement.name)
        if excludes_version(requirement, installed.get(name)):
            pinned.discard(name)
        if excludes_version(requirement, base.get(name)):
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


def _prepare_distributions(cache: WheelCache, wheels: dict[str, Wheel]) -> dict:
    distributions = {}
    for name, wheel in sorted(wheels.items()):
        site = cache.unpack(wheel)
        files = sorted(str(path.relative_to(site)) for path in walk_files(site))
        distributions[name] = {"record": wheel.record(), "directory": str(site), "files": files}

    return distributions
