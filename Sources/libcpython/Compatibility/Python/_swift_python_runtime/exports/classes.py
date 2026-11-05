"""Assemble Python classes and bind their instances to Swift peers."""

from types import ModuleType

from .functions import FunctionFactory, identifier, is_reserved_member


class NativeClasses:
    def __init__(self, invoke, functions: FunctionFactory) -> None:
        self._invoke = invoke
        self._functions = functions
        self._types = {}
        self._creating = False
        self._base = None

    def prepare(self, record, module: ModuleType) -> tuple:
        key, base, name, documentation, constructor, methods, properties = record
        name = identifier(name)
        create = self._functions.create
        constructor = create(constructor, module) if constructor is not None else None
        members = {record[0]: create(record, module, member=True) for record in methods}

        for property_name, property_doc, getter, setter in properties:
            identifier(property_name)
            if is_reserved_member(property_name):
                raise ValueError("Reserved native property name")

            members[property_name] = property(
                create(getter, module),
                create(setter, module) if setter is not None else None,
                doc=property_doc,
            )

        return module, key, base, name, documentation, constructor, members

    def install(self, pending: list[tuple]) -> None:
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

        while pending:
            ready = [record for record in pending if record[2] is None or record[2] in self._types]
            if not ready:
                raise TypeError("A native class base module is missing")

            for record in ready:
                self._make_class(*record)
                pending.remove(record)

    def wrap(self, key, capsule):
        return self._bind(self._types[key], capsule)

    def _bind(self, cls: type, capsule):
        try:
            wrapper = object.__new__(cls)
            object.__setattr__(wrapper, "_swift_peer", capsule)
            object.__setattr__(wrapper, "_swift_fields", {})
            self._invoke("bind", wrapper)
            return wrapper
        except BaseException:
            self._invoke("abandon", capsule)
            raise

    def _make_class(
        self, module: ModuleType, key, base, name: str, doc: str | None, constructor, members: dict
    ) -> None:
        native_type = None

        def new(cls: type, *args, **kwargs):
            if cls is not native_type:
                raise TypeError("Expected the concrete native class")

            if constructor is None:
                raise TypeError(f"{name} has no PythonInit; wrap an existing Swift instance")

            return self._bind(cls, constructor(*args, **kwargs))

        def initialize(self, *args, **kwargs) -> None:
            # __new__ has already initialized and bound the complete Swift peer.
            pass

        members.update(
            __slots__=(),
            __module__=module.__name__,
            __doc__=doc,
            __new__=staticmethod(new),
            __init__=initialize,
        )
        self._creating = True
        try:
            native_type = type(name, (self._types[base] if base else self._base,), members)
        finally:
            self._creating = False

        if name in module.__dict__:
            raise ValueError(f"Python name {module.__name__}.{name} already exists")

        self._types[key] = native_type
        self._invoke("register_type", key, native_type)
        self._invoke("freeze", native_type)
        setattr(module, name, native_type)
