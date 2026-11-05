"""Resolve a complete requirement set against the fixed application base."""

import hashlib
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from packaging.requirements import Requirement
from packaging.specifiers import SpecifierSet
from packaging.utils import canonicalize_name, parse_wheel_filename
from packaging.version import Version
from resolvelib import AbstractProvider, BaseReporter, ResolutionImpossible, Resolver

from .candidate import Candidate
from .configuration import ABI, MARKER_ENVIRONMENT, PYTHON_VERSION, SUPPORTED_TAGS, Configuration
from .requirements import _requirements
from .wheels import WheelCache


class Provider(AbstractProvider):
    def __init__(self, configuration: Configuration, installed: dict, update: bool) -> None:
        self.configuration = configuration
        self.wheels = WheelCache(configuration.cache)
        self.installed = installed
        self.update = update
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

    def _candidates(self, name: str, extras: frozenset[str], requirements: list[Requirement]):
        if name in self.configuration.base:
            yield Candidate(
                name, Version(self.configuration.base[name]["version"]), extras, provided=True
            )
            return

        previous = self.installed.get(name)
        if previous and not self.update:
            yield Candidate(
                name,
                Version(previous["version"]),
                extras,
                previous["url"],
                previous["digest"],
                previous["filename"],
            )

        if name not in self.index:
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
                if error.code == 404:
                    data = {"files": []}
                else:
                    raise

            self.index[name] = data["files"]

        candidates = []

        for file in self.index[name]:
            filename = file["filename"]

            try:
                distribution, version, _, tags = parse_wheel_filename(filename)
            except ValueError:
                continue

            if distribution != name or not tags.intersection(SUPPORTED_TAGS):
                continue

            if not all(tag.abi == "none" and tag.platform == "any" for tag in tags):
                continue

            requires_python = file.get("requires-python")
            if requires_python and not SpecifierSet(requires_python).contains(
                PYTHON_VERSION, prereleases=True
            ):
                continue

            if file.get("yanked") and not any(
                any(
                    spec.operator in ("==", "===")
                    and "*" not in spec.version
                    and spec.contains(version, prereleases=True)
                    for spec in requirement.specifier
                )
                for requirement in requirements
            ):
                continue

            digest = file.get("hashes", {}).get("sha256", "")
            if not re.fullmatch(r"[0-9a-f]{64}", digest):
                raise ValueError(f"Package index must provide a SHA-256 hash for {filename}")

            url = urllib.parse.urljoin(self.configuration.index + name + "/", file["url"])
            if urllib.parse.urlsplit(url).scheme not in ("https", "file"):
                raise ValueError(f"Wheel URL must use HTTPS or a local file: {filename}")

            candidates.append(Candidate(name, version, extras, url, digest, filename))

        candidates.sort(key=lambda candidate: (candidate.version, candidate.filename), reverse=True)
        yield from candidates

    def find_matches(self, identifier: str, requirements, incompatibilities):
        requirements = list(requirements[identifier])
        extras = frozenset(extra for requirement in requirements for extra in requirement.extras)
        excluded = set(incompatibilities[identifier])

        def matches():
            seen = set()

            for candidate in self._candidates(identifier, extras, requirements):
                if candidate in seen or candidate in excluded:
                    continue

                seen.add(candidate)
                if all(
                    self.is_satisfied_by(requirement, candidate) for requirement in requirements
                ):
                    yield candidate

        return matches()

    def get_dependencies(self, candidate: Candidate) -> list[Requirement]:
        if candidate.provided:
            values = self.configuration.base[candidate.name]["requires"]
        else:
            if candidate.digest not in self.metadata:
                self.metadata[candidate.digest] = self.wheels.metadata(candidate)
            metadata = self.metadata[candidate.digest]
            requires_python = metadata.get("Requires-Python")
            if requires_python and not SpecifierSet(requires_python).contains(
                PYTHON_VERSION, prereleases=True
            ):
                # An empty match makes this candidate unavailable without changing
                # the meaning of the project's requirements.
                return [Requirement(candidate.name + "==0,!=0")]

            values = metadata.get_all("Requires-Dist", [])

        dependencies = []

        for value in values:
            requirement = Requirement(value)
            if requirement.url:
                raise ValueError(f"Source dependency is unsupported: {value}")

            if requirement.marker is None or any(
                requirement.marker.evaluate({**MARKER_ENVIRONMENT, "extra": extra})
                for extra in candidate.extras | {""}
            ):
                # Markers have been evaluated for the parent candidate's extras.
                requirement.marker = None
                dependencies.append(requirement)

        return dependencies


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
        return {"fingerprint": fingerprint, "unchanged": True, "distributions": {}}
    roots = _requirements(
        requirements
        + [name + "==" + record["version"] for name, record in configuration.base.items()]
    )
    provider = Provider(configuration, request["installed"], request["update"])
    try:
        resolution = Resolver(provider, BaseReporter()).resolve(roots, max_rounds=1000)
    except ResolutionImpossible as error:
        causes = ", ".join(str(cause.requirement) for cause in error.causes)
        raise ValueError(f"No compatible pure-Python wheel set satisfies: {causes}") from None
    distributions = {}
    for name, candidate in sorted(resolution.mapping.items()):
        if candidate.provided:
            continue
        site = provider.wheels.unpack(candidate) / "site-packages"
        files = sorted(
            str(Path(directory, file).relative_to(site))
            for directory, _, names in os.walk(site)
            for file in names
        )
        distributions[name] = {
            "record": {
                "version": str(candidate.version),
                "url": candidate.url,
                "digest": candidate.digest,
                "filename": candidate.filename,
            },
            "directory": str(site),
            "files": files,
        }
    return {"fingerprint": fingerprint, "unchanged": False, "distributions": distributions}
