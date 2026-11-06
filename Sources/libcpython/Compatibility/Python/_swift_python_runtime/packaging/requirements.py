"""Parse project, inline-script and explicitly supplied Python requirements."""

import re
import tomllib

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name

from .configuration import MARKER_ENVIRONMENT, PYTHON_VERSION, supports_python


def _requirements(values: list[str]) -> list[Requirement]:
    result = []

    for value in values:
        requirement = Requirement(value)
        if requirement.url is not None:
            raise ValueError(
                "Direct URLs and source builds are not supported; use named wheel requirements"
            )

        if requirement.marker is None or requirement.marker.evaluate(MARKER_ENVIRONMENT):
            result.append(requirement)

    return result


def _requirements_txt(text: str) -> list[str]:
    lines = []
    pending = ""

    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        line = re.split(r"\s+#", line, maxsplit=1)[0].strip()
        if line.endswith("\\"):
            pending += line[:-1] + " "
            continue

        line = pending + line
        pending = ""
        if line.startswith("-"):
            raise ValueError(
                "requirements.txt supports requirement declarations, not pip command options"
            )
        lines.append(line)

    if pending:
        raise ValueError("Unfinished continuation in requirements.txt")
    return lines


def _check_python(specifier: str | None, origin: str) -> None:
    if not supports_python(specifier):
        raise ValueError(
            f"The {origin} requires Python {specifier}; this runtime is {PYTHON_VERSION}"
        )


def project(request: dict, unused, control) -> list[str]:
    manifest = request.get("pyproject")
    requirements_text = request.get("requirements")
    metadata = tomllib.loads(manifest).get("project", {}) if manifest is not None else {}

    _check_python(metadata.get("requires-python"), "project")

    if requirements_text is not None:
        requirements = _requirements_txt(requirements_text)
    else:
        if "dependencies" in metadata.get("dynamic", []):
            raise ValueError("Project dependencies must be declared in pyproject.toml")
        requirements = metadata.get("dependencies", [])

    return [str(value) for value in _requirements(requirements)]


def _script_metadata(source: str) -> dict | None:
    # PyPA's canonical PEP 723 scan; unknown block types remain untouched.
    pattern = r"(?m)^# /// (?P<type>[a-zA-Z0-9-]+)$\s(?P<content>(^#(| .*)$\s)+)^# ///$"
    normalized = source.replace("\r\n", "\n").replace("\r", "\n")
    matches = [match for match in re.finditer(pattern, normalized) if match["type"] == "script"]
    if len(matches) > 1:
        raise ValueError("Multiple script metadata blocks found")

    if not matches:
        return None

    content = "".join(
        line[2:] if line.startswith("# ") else line[1:]
        for line in matches[0]["content"].splitlines(keepends=True)
    )
    return tomllib.loads(content)


def script(request: dict, unused, control) -> list[str]:
    metadata = _script_metadata(request["source"])
    if metadata is None:
        return []

    requirements = metadata.get("dependencies", [])
    if not isinstance(requirements, list) or not all(
        isinstance(value, str) for value in requirements
    ):
        raise ValueError("Script dependencies must be an array of requirement strings")

    requires_python = metadata.get("requires-python")
    if requires_python is not None:
        if not isinstance(requires_python, str):
            raise ValueError("Script requires-python must be a version specifier string")

        _check_python(requires_python, "script")

    return [str(requirement) for requirement in _requirements(requirements)]


def normalize(request: dict, unused, control) -> list[dict]:
    return [
        {"name": canonicalize_name(value.name), "declaration": str(value)}
        for value in _requirements(request["requirements"])
    ]


def names(request: dict, unused, control) -> list[str]:
    return [canonicalize_name(value) for value in request["names"]]


def module_name(request: dict, unused, control) -> str:
    parts = request["module"].split(".")
    if not all(part.isidentifier() for part in parts):
        raise ValueError("Expected an importable module name")
    return parts[0]
