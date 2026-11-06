"""Resolve a complete requirement set against the fixed application base."""

import hashlib
import json
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterator

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name
from packaging.version import Version
from resolvelib import AbstractProvider, BaseReporter, ResolutionImpossible, Resolver

from .candidate import Candidate, Distribution, Wheel
from .configuration import ABI, MARKER_ENVIRONMENT, Configuration, supports_python
from .paths import walk_files
from .requirements import _requirements
from .wheels import WheelCache


def _is_pinned(version: Version, requirements: list[Requirement]) -> bool:
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
    def __init__(self, configuration: Configuration, installed: dict, update: bool) -> None:
        self.configuration = configuration
        self.installed = installed
        self.update = update

        self.wheels = WheelCache(configuration.cache)
        self.index = {}
        self.metadata = {}

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
        if name in self.index:
            return self.index[name]

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
            files = []
        else:
            files = data["files"]

        self.index[name] = files
        return files

    def _index_wheels(self, name: str, requirements: list[Requirement]) -> Iterator[Wheel]:
        for file in self._index_files(name):
            filename = file["filename"]

            try:
                version = Wheel.version_for(name, filename)
            except ValueError:
                continue

            if not supports_python(file.get("requires-python")):
                continue

            if file.get("yanked") and not _is_pinned(version, requirements):
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

        wheels = sorted(
            self._index_wheels(name, requirements),
            key=lambda wheel: (wheel.version, wheel.filename),
            reverse=True,
        )
        yield from (Candidate(wheel, extras) for wheel in wheels)

    def find_matches(self, identifier: str, requirements, incompatibilities):
        requirements = list(requirements[identifier])
        extras = frozenset(extra for requirement in requirements for extra in requirement.extras)
        excluded = set(incompatibilities[identifier])

        def matches():
            for candidate in self._candidates(identifier, extras, requirements):
                if candidate in excluded:
                    continue

                excluded.add(candidate)
                if all(
                    self.is_satisfied_by(requirement, candidate) for requirement in requirements
                ):
                    yield candidate

        # Snapshot the resolver's inputs before it starts consuming candidates.
        return matches()

    def get_dependencies(self, candidate: Candidate) -> list[Requirement]:
        wheel = candidate.distribution
        if not isinstance(wheel, Wheel):
            values = self.configuration.base[candidate.name]["requires"]
        else:
            if wheel.digest not in self.metadata:
                self.metadata[wheel.digest] = self.wheels.metadata(wheel)

            metadata = self.metadata[wheel.digest]
            if not supports_python(metadata.get("Requires-Python")):
                # An empty match makes this candidate unavailable without changing
                # the meaning of the project's requirements.
                return [Requirement(candidate.name + "==0,!=0")]

            values = metadata.get_all("Requires-Dist", [])

        return _dependencies_for_extras(values, candidate.extras)


def _prepare_distribution(cache: WheelCache, wheel: Wheel) -> dict:
    site = cache.unpack(wheel) / "site-packages"
    files = sorted(str(path.relative_to(site)) for path in walk_files(site))
    return {"record": wheel.record(), "directory": str(site), "files": files}


def _resolve_wheels(provider: Provider, roots: list[Requirement]) -> dict[str, Wheel]:
    try:
        resolution = Resolver(provider, BaseReporter()).resolve(roots, max_rounds=1000)
    except ResolutionImpossible as error:
        causes = ", ".join(str(cause.requirement) for cause in error.causes)
        raise ValueError(f"No compatible pure-Python wheel set satisfies: {causes}") from None

    return {
        name: candidate.distribution
        for name, candidate in resolution.mapping.items()
        if isinstance(candidate.distribution, Wheel)
    }


def prepare(request: dict, configuration: Configuration) -> dict:
    requirements = request["requirements"]
    signature = {
        "requirements": requirements,
        "base": configuration.base,
        "abi": ABI,
        "index": configuration.index,
    }
    fingerprint = hashlib.sha256(json.dumps(signature, sort_keys=True).encode()).hexdigest()
    if request.get("fingerprint") == fingerprint and not request["update"]:
        return {"status": "unchanged"}

    roots = _requirements(
        requirements
        + [name + "==" + record["version"] for name, record in configuration.base.items()]
    )
    provider = Provider(configuration, request["installed"], request["update"])
    wheels = _resolve_wheels(provider, roots)

    if not request["replace_files"]:
        selected = {name: wheel.digest for name, wheel in wheels.items()}
        installed = {name: record["digest"] for name, record in request["installed"].items()}
        if selected != installed:
            return {"status": "requires_reset"}

    distributions = {
        name: _prepare_distribution(provider.wheels, wheel)
        for name, wheel in sorted(wheels.items())
    }
    return {"status": "resolved", "fingerprint": fingerprint, "distributions": distributions}
