"""Swift-facing package preparation; environment transactions stay in Swift."""

from ..packages import installation_tools

# The pinned wheel libraries must be mounted before importing their consumers.
installation_tools()

from .configuration import load
from .requirements import module_name as module_name
from .requirements import names as names
from .requirements import normalize as normalize
from .requirements import project as project
from .requirements import script as script
from .resolver import prepare as prepare_distributions
from .wheels import archive as archive

_configuration = None


def configure(configuration: dict, sources: list[dict], read) -> dict:
    global _configuration
    if _configuration is not None:
        raise RuntimeError("The package service is already configured")
    _configuration, description = load(configuration, sources, read)
    return description


def prepare(request: dict, unused, control) -> dict:
    return prepare_distributions(request, _configuration)
