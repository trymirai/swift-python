"""Render Swift function, class and property metadata as stub declarations."""

from ..exports.functions import identifier, is_reserved_member
from .annotations import Annotations
from .formatting import documentation, function, indent


def render_function(
    record,
    annotations: Annotations,
    *,
    name=None,
    doc=None,
    decorators=(),
    receiver=False,
    returns=None,
) -> list[str]:
    function_name, function_doc, result, asynchronous, parameters, _, _ = record
    name = identifier(name or function_name)
    parameters = [
        (identifier(parameter), annotations.resolve(annotation), has_default)
        for parameter, annotation, has_default, _ in parameters
    ]
    if parameters and parameters[0][0] == "self" and receiver:
        parameters = parameters[1:]

    result = returns or annotations.resolve(result)
    doc = doc if doc is not None else function_doc
    if not _requires_overloads(parameters):
        arguments = (["self"] if receiver else []) + [_parameter(p) for p in parameters]
        return function(
            name, arguments, result, asynchronous=asynchronous, doc=doc, decorators=decorators
        )

    # One disjoint overload per positional argument count also represents Swift's
    # optional-before-required order without inventing a default for a required argument.
    overload = annotations.import_module("typing", preferred="_typing") + ".overload"
    lines = []
    for count in range(len(parameters) + 1):
        arguments = _overload_parameters(parameters, count, receiver)
        if lines:
            lines.append("")
        lines += function(
            name,
            arguments,
            result,
            asynchronous=asynchronous,
            doc=doc if count == 0 else None,
            decorators=(*decorators, overload),
        )

    return lines


def _overload_parameters(parameters, count: int, receiver: bool) -> list[str]:
    arguments = ["self"] if receiver else []
    arguments += [_parameter(p, default=False) for p in parameters[:count]]
    if count:
        arguments.append("/")
    if count < len(parameters):
        arguments += ["*", *(_parameter(p) for p in parameters[count:])]
    return arguments


def _parameter(parameter, *, default: bool = True) -> str:
    name, annotation, optional = parameter
    return f"{name}: {annotation}" + (" = ..." if optional and default else "")


def _requires_overloads(parameters) -> bool:
    has_default = False
    for _, _, optional in parameters:
        if has_default and not optional:
            return True
        has_default |= optional

    return False


def render_class(record, annotations: Annotations, bindings: dict) -> list[str]:
    _, base, name, doc, constructor, methods, properties = record
    identifier(name)

    bases = ""
    if base is not None:
        owner, member = bindings[base]
        bases = "(" + annotations.resolve((f"{owner}.{member}", [(owner, member)])) + ")"

    members = documentation(doc)
    if members:
        members.append("")
    if constructor is not None:
        members += render_function(
            constructor, annotations, name="__init__", receiver=True, returns="None"
        )
    else:
        typing = annotations.import_module("typing", preferred="_typing")
        members += function(
            "__new__", ["cls", f"_unavailable: {typing}.Never", "/"], typing + ".Self"
        )

    for property_record in sorted(properties, key=lambda record: record[0]):
        members += ["", *_property(property_record, annotations)]
    for method in sorted(methods, key=lambda record: record[0]):
        if is_reserved_member(method[0]):
            raise ValueError("Native classes do not export Python special methods")
        members += ["", *render_function(method, annotations, receiver=True)]

    return [f"class {name}{bases}:", *indent(members or ["..."])]


def _property(record, annotations: Annotations) -> list[str]:
    name, doc, getter, setter = record
    identifier(name)
    if is_reserved_member(name):
        raise ValueError("Reserved native property name")

    lines = render_function(
        getter,
        annotations,
        name=name,
        doc=doc,
        decorators=(annotations.resolve(("property", [])),),
        receiver=True,
    )
    if setter is not None:
        lines += [
            "",
            *render_function(
                setter,
                annotations,
                name=name,
                decorators=(name + ".setter",),
                receiver=True,
                returns="None",
            ),
        ]

    return lines
