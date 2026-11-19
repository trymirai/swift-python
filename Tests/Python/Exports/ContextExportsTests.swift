//
//  Created by Anton Spivak
//

import Python
import Testing

// MARK: - ContextExportsBaseModule

@PythonExportedModule("context_exports_base")
private enum ContextExportsBaseModule {}

// MARK: - ContextExportsChildModule

@PythonExportedModule("context_exports_child")
private enum ContextExportsChildModule {
    @PythonFunction("class_count")
    static func classCount(_ context: Python::Context) async throws -> Int {
        await Task.yield()
        return try context.exports.classes().count
    }
}

// MARK: - ContextExportsBase

@PythonExportedClass("Base", module: ContextExportsBaseModule.self)
private class ContextExportsBase {
    private var getterReads = 0
    private let secret = 99

    @PythonProperty("python_name")
    let renamed = 11

    @PythonProperty("_explicit")
    let underscored = 13

    @PythonProperty("shared")
    let baseShared = 17

    @PythonProperty("shadowed")
    let baseShadowed = 19

    @PythonProperty
    var stored: Int

    @PythonProperty(isReadOnly: true)
    var readonly: Int

    @PythonProperty
    var measured: Int {
        getterReads += 1
        return 23
    }

    @PythonInit
    init() throws {
        try $stored(3)
        try $readonly(5)
    }

    @PythonFunction
    func readCount() -> Int {
        getterReads
    }

    @PythonFunction("becomes_property")
    func baseMethod() -> String {
        "base method"
    }
}

// MARK: - ContextExportsChild

@PythonExportedClass("Child", module: ContextExportsChildModule.self)
private final class ContextExportsChild: ContextExportsBase {
    @PythonProperty
    let child = 29

    @PythonProperty("shared")
    let childShared = 31

    @PythonProperty("becomes_property")
    let childProperty = 37

    @PythonFunction("shadowed")
    func childMethod() -> String {
        "child method"
    }

    @PythonInit
    override init() throws {
        try super.init()
    }
}

// MARK: - ContextExportsInherited

@PythonExportedClass("Inherited", module: ContextExportsChildModule.self)
private final class ContextExportsInherited: ContextExportsBase {}

// MARK: - ContextExportsEmpty

@PythonExportedClass("Empty", module: ContextExportsBaseModule.self)
private final class ContextExportsEmpty {}

@Test
func contextExportsListsClassesWithoutPythonMetadata() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [ContextExportsChildModule.self])
    defer { await session.close() }

    _ = try await session.evaluate("class PythonOnly: pass")
    try await bindExportedClasses(in: session)
    _ = try await session.evaluate("""
    from context_exports_base import Base, Empty
    from context_exports_child import Child, Inherited, class_count
    from contextlib import redirect_stdout
    from io import StringIO
    import inspect

    assert len(exported_classes) == 4
    assert set(exported_classes) == {Base, Child, Inherited, Empty}
    assert PythonOnly not in exported_classes and int not in exported_classes
    assert await class_count() == 4

    def property_names(cls):
        members = {}
        for base in reversed(cls.__mro__):
            members.update(vars(base))
        return tuple(sorted(name for name, member in members.items() if isinstance(member, property)))

    base_names = ('_explicit', 'measured', 'python_name', 'readonly', 'shadowed', 'shared', 'stored')
    child_names = ('_explicit', 'becomes_property', 'child', 'measured', 'python_name',
                   'readonly', 'shared', 'stored')
    assert property_names(Base) == base_names
    assert property_names(Child) == child_names
    assert property_names(Inherited) == base_names
    assert property_names(Empty) == ()

    metadata_name = '__swift_exported_properties__'
    for cls in exported_classes:
        assert not hasattr(cls, metadata_name)
        assert metadata_name not in vars(cls)
        assert metadata_name not in dir(cls)
        assert metadata_name not in dict(inspect.getmembers(cls))
        assert metadata_name not in dict(inspect.getmembers_static(cls))
        with redirect_stdout(StringIO()) as output:
            help(cls)
        assert metadata_name not in output.getvalue()

    value = Child()
    assert property_names(type(value)) == child_names and value.readCount() == 0
    snapshot = {name: getattr(value, name) for name in property_names(type(value))}
    assert snapshot == {'_explicit': 13, 'becomes_property': 37, 'child': 29, 'measured': 23,
                        'python_name': 11, 'readonly': 5, 'shared': 31, 'stored': 3}
    assert value.readCount() == 1
    assert value.shadowed() == 'child method'
    assert Child.readonly.fset is None

    assert not hasattr(value, metadata_name)
    assert metadata_name not in dir(value)
    assert metadata_name not in dict(inspect.getmembers(value))
    assert metadata_name not in dict(inspect.getmembers_static(value))
    with redirect_stdout(StringIO()) as output:
        help(value)
    assert metadata_name not in output.getvalue()
    """)
}

// MARK: - ContextExportsEmptyModule

@PythonExportedModule("context_exports_empty")
private enum ContextExportsEmptyModule {}

@Test(arguments: [false, true])
func contextExportsReturnsEmptyWithoutInstalledClasses(module: Bool) async throws {
    let runtime = try await Python::Runtime()
    let modules: [any Python::ModuleHost.Type] = module ? [ContextExportsEmptyModule.self] : []
    let session = try await runtime.session(modules: modules)
    defer { await session.close() }

    let classes = try await session.enqueue { context in
        try context.exports.classes()
    }
    #expect(classes.isEmpty)
}

@Test
func contextExportsAndClassReferencesStayWithinTheirGeneration() async throws {
    let runtime = try await Python::Runtime()
    let first = try await runtime.session(modules: [ContextExportsChildModule.self])
    let second = try await runtime.session()
    defer {
        await first.close()
        await second.close()
    }

    let exports: Python::Context.Exports = try await first.enqueue { $0.exports }
    let classes = try await first.enqueue { _ in
        try exports.classes()
    }
    #expect(classes.count == 4)
    try await first.enqueue { context in
        try context.set(classes, forKey: "saved_classes")
        try context.set(exports.classes(), forKey: "current_classes")
    }
    _ = try await first.evaluate("assert set(saved_classes) == set(current_classes)")

    await #expect(throws: Python::Exception.self) {
        try await second.enqueue { _ in try exports.classes() }
    }
    await #expect(throws: Python::Exception.self) {
        try await second.set(classes, forKey: "foreign_classes")
    }

    try await first.reset()
    await #expect(throws: Python::Exception.self) {
        try await first.enqueue { _ in try exports.classes() }
    }
    await #expect(throws: Python::Exception.self) {
        try await first.set(classes, forKey: "old_classes")
    }
    try await bindExportedClasses(in: first)
    _ = try await first.evaluate("""
    from context_exports_child import Child
    assert len(exported_classes) == 4 and Child in exported_classes
    assert not hasattr(Child, '__swift_exported_properties__')
    """)
}

private func bindExportedClasses(in session: Python::Session) async throws {
    try await session.enqueue { context in
        try context.set(context.exports.classes(), forKey: "exported_classes")
    }
}
