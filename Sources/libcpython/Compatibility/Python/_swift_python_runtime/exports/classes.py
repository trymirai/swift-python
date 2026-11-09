"""Assemble Python classes and bind their instances to Swift peers."""

from collections import namedtuple
from types import ModuleType

from .functions import FunctionFactory, identifier, is_reserved_member, require_free_name

_PreparedClass = namedtuple(
    "_PreparedClass",
    (
        "module",
        "key",
        "base",
        "name",
        "documentation",
        "constructor",
        "members",
    ),
)


class NativeClasses:
    def __init__(self, invoke, functions: FunctionFactory) -> None:
        self._invoke = invoke
        self._functions = functions

        self._types = {}
        self._base = None

        self._creating = False

    def prepare(self, record, module: ModuleType) -> _PreparedClass:
        key, base, name, documentation, constructor, methods, properties = record
        name = identifier(name)

        create = self._functions.create
        constructor = create(constructor, module) if constructor is not None else None
        members = {method[0]: create(method, module, member=True) for method in methods}

        for property_name, property_doc, getter, setter in properties:
            identifier(property_name)
            if is_reserved_member(property_name):
                raise ValueError("Reserved native property name")

            members[property_name] = property(
                create(getter, module),
                create(setter, module) if setter is not None else None,
                doc=property_doc,
            )

        return _PreparedClass(module, key, base, name, documentation, constructor, members)

    def install(self, pending: list[_PreparedClass]) -> None:
        registry = self

        class _SwiftObject:
            __slots__ = ("_swift_peer", "_swift_fields", "__weakref__")

            def __init_subclass__(cls, **kwargs) -> None:
                if not registry._creating:
                    raise TypeError("Subclass native classes in Swift using PythonClass")

                super().__init_subclass__(**kwargs)

        self._base = _SwiftObject
        self._invoke("freeze", _SwiftObject)
        self._invoke("register_wrap", self.wrap)

        self._install_pending(pending)

    def _install_pending(self, pending: list[_PreparedClass]) -> None:
        while pending:
            ready = [
                record for record in pending if record.base is None or record.base in self._types
            ]
            if not ready:
                raise TypeError("A native class base module is missing")

            for record in ready:
                self._make_class(record)
                pending.remove(record)

    def wrap(self, key, capsule):
        wrapper = object.__new__(self._types[key])
        object.__setattr__(wrapper, "_swift_peer", capsule)
        object.__setattr__(wrapper, "_swift_fields", {})
        self._invoke("bind", wrapper)
        return wrapper

    def _make_class(self, record: _PreparedClass) -> None:
        module = record.module
        name = record.name
        constructor = record.constructor

        native_type = None

        def new(cls: type, *args, **kwargs):
            if cls is not native_type:
                raise TypeError("Expected the concrete native class")

            if constructor is None:
                raise TypeError(f"{name} has no PythonInit; wrap an existing Swift instance")

            return constructor(*args, **kwargs)

        def initialize(self, *args, **kwargs) -> None:
            # __new__ has already initialized and bound the complete Swift peer.
            pass

        record.members.update(
            __slots__=(),
            __module__=module.__name__,
            __doc__=record.documentation,
            __new__=staticmethod(new),
            __init__=initialize,
        )

        self._creating = True
        try:
            base = self._types[record.base] if record.base else self._base
            native_type = type(name, (base,), record.members)
        finally:
            self._creating = False

        require_free_name(module, name)
        self._types[record.key] = native_type
        self._invoke("register_type", record.key, native_type)
        self._invoke("freeze", native_type)
        setattr(module, name, native_type)
