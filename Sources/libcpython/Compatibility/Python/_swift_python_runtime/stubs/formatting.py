"""Format shared stub syntax and escaped documentation."""

import inspect


def documentation(text: str | None, indent: str = "") -> list[str]:
    if text is None:
        return []

    text = inspect.cleandoc(text).replace("\\", "\\\\").replace('"""', '\\"""')
    text = text.replace("\0", "\\x00").replace("\r", "\\r")
    lines = text.split("\n")
    if len(lines) == 1:
        return [f'{indent}"""{lines[0]}"""']

    return [
        f'{indent}"""{lines[0]}',
        *(indent + line if line else "" for line in lines[1:]),
        f'{indent}"""',
    ]


def function(
    name: str,
    parameters: list[str],
    returns: str,
    *,
    asynchronous: bool = False,
    doc: str | None = None,
    decorators=(),
) -> list[str]:
    prefix = "async " if asynchronous else ""
    start, end = f"{prefix}def {name}(", f") -> {returns}:"
    signature = start + ", ".join(parameters) + end
    body = documentation(doc, "    ") + ["    ..."]

    if len(signature) + 4 <= 96:
        lines = [signature, *body] if doc is not None else [signature + " ..."]
    else:
        lines = [start, *(f"    {parameter}," for parameter in parameters), end, *body]

    return [*("@" + decorator for decorator in decorators), *lines]


def indent(lines: list[str]) -> list[str]:
    return ["    " + line if line else "" for line in lines]
