"""Assemble Python classes and bind their instances to Swift peers."""

from collections import namedtuple
from inspect import Signature
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
        self._creating = False

    def prepare(self, record, module: ModuleType) -> _PreparedClass:
        key, base, name, documentation, constructor, methods, properties = record
        name = identifier(name)

        create = self._functions.create
        constructor = create(constructor, module) if constructor is not None else None
        members = {method[0]: create(method, module, member=True) for method in methods}

        for record in properties:
            property_name, descriptor = self._prepare_property(record, module)
            members[property_name] = descriptor

        return _PreparedClass(module, key, base, name, documentation, constructor, members)

    def _prepare_property(self, record, module: ModuleType) -> tuple[str, property]:
        name, documentation, getter, setter = record
        identifier(name)
        if is_reserved_member(name):
            raise ValueError("Reserved native property name")

        create = self._functions.create
        getter = create(getter, module)
        annotation = getter.__signature__.return_annotation
        if annotation is not Signature.empty:
            documentation = f"{annotation}\n\n{documentation or ''}".rstrip()

        descriptor = property(
            getter,
            create(setter, module) if setter is not None else None,
            doc=documentation,
        )
        return name, descriptor

    def install(self, pending: list[_PreparedClass]) -> None:
        self._invoke("register_wrap", self.wrap)

        self._install_pending(pending)

    def _install_pending(self, pending: list[_PreparedClass]) -> None:
        while pending:
            ready = []
            blocked = []
            for record in pending:
                if record.base is None or record.base in self._types:
                    ready.append(record)
                else:
                    blocked.append(record)

            if not ready:
                raise TypeError("A native class base module is missing")

            for record in ready:
                self._make_class(record)
            pending[:] = blocked

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
        base = self._types[record.base] if record.base is not None else object

        native_type = None

        def new(cls: type, *args, **kwargs):
            if cls is not native_type:
                raise TypeError("Expected the concrete native class")

            if constructor is None:
                raise TypeError(f"{name} has no PythonInit; wrap an existing Swift instance")

            return constructor(*args, **kwargs)

        new.__name__ = "__new__"
        new.__qualname__ = f"{name}.__new__"
        new.__module__ = module.__name__

        if constructor is not None:
            record.members["__signature__"] = constructor.__signature__.replace(
                return_annotation=Signature.empty
            )
        elif getattr(base, "__signature__", None) is not None:
            # A returned-only subclass must not advertise its base's constructor.
            record.members["__signature__"] = None

        if record.base is None:
            def init_subclass(cls, **kwargs) -> None:
                """Python subclassing is unavailable."""
                if not self._creating:
                    raise TypeError("Subclass native classes in Swift using PythonExportedClass")

            init_subclass.__name__ = "__init_subclass__"
            init_subclass.__qualname__ = f"{name}.__init_subclass__"
            init_subclass.__module__ = module.__name__
            record.members["__init_subclass__"] = classmethod(init_subclass)

        record.members.update(
            __slots__=(
                ("_swift_peer", "_swift_fields", "__weakref__") if record.base is None else ()
            ),
            __module__=module.__name__,
            __doc__=record.documentation,
            __new__=staticmethod(new),
        )

        self._creating = True
        try:
            native_type = type(name, (base,), record.members)
        finally:
            self._creating = False

        require_free_name(module, name)
        self._types[record.key] = native_type
        self._invoke("register_type", record.key, native_type)
        self._invoke("freeze", native_type)
        setattr(module, name, native_type)
