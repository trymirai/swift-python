"""Swift-facing package preparation; environment transactions stay in Swift."""

import hashlib
import json
from dataclasses import replace

from ..packages import installation_tools

# The pinned wheel libraries must be mounted before importing their consumers.
installation_tools()

from .candidate import Wheel
from .configuration import Configuration, describe, load, marker_environment
from .configuration import project_package_source as project_package_source
from .requirements import module_name as module_name
from .requirements import names as names
from .requirements import normalize as normalize
from .requirements import project as project
from .requirements import script as script
from .resolver import fingerprint as resolution_fingerprint
from .resolver import prepare as prepare_distributions
from .wheels import archive as archive

_configuration = None


def configure(configuration: dict, sources: list[dict], read) -> dict:
    global _configuration
    if _configuration is not None:
        raise RuntimeError("The package service is already configured")

    options = load(configuration)
    # Publish the configuration only after the initial sources are validated.
    description = describe(options, sources, read)

    _configuration = options
    return description


def describe_sources(sources: list[dict], read) -> dict:
    return describe(_configuration, sources, read)


def prepare(request: dict) -> dict:
    return prepare_distributions(request, _configuration_for(request))


def fingerprint(request: dict) -> str:
    return resolution_fingerprint(request, _configuration_for(request))


def _configuration_for(request: dict) -> Configuration:
    # One service resolves for sessions with different base packages and destinations.
    return replace(_configuration, base=request["base"], markers=marker_environment(request))


def package_fingerprint(request: dict) -> str:
    signature = sorted(request["digests"].items())
    encoded = json.dumps(signature, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def encode_manifest(manifest: dict) -> str:
    return json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"


def decode_manifest(data: bytes) -> dict:
    manifest = json.loads(data)
    if not isinstance(manifest, dict):
        raise ValueError("Expected a package environment manifest")

    packages = manifest.get("packages")
    if not isinstance(packages, dict):
        raise ValueError("Expected package records in the environment manifest")

    for name, record in packages.items():
        Wheel.from_record(name, record)

    return manifest
