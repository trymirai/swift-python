//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import SystemPackage
import Testing

// MARK: - StubsTests

struct StubsTests {
    @Test
    func `stubs describe declarations without executing application code`() async throws {
        try await withTemporaryDirectory { root in
            let destination = root.appending("typings")
            let stubs = Python::Stubs([StubRoot.self, StubChildModule.self])
            try await stubs.write(to: destination.string)

            let source = try await Self.read(destination.appending("stub_fixture/records.pyi"))
            #expect(source.contains("def list(limit: int = ...) -> _builtins.list[Record | None]"))
            #expect(source.contains("@_builtins.property"))
            #expect(source.contains("@value.setter"))
            #expect(!source.contains("@display_name.setter"))
            #expect(source.contains("current_value: int"))
            #expect(source.contains("unknown: object"))
            #expect(source.contains("def greeting(prefix: str = ...) -> str"))
            #expect(source.contains("def read(self, *, fresh: bool = ...) -> str"))
            #expect(!source.contains("application_code("))
            #expect(!source.contains("def _discarded"))
            try await Self.checkDeclarations(in: source)

            let parent = try await Self.read(destination.appending("stub_fixture/__init__.pyi"))
            #expect(parent.contains("from . import records as records"))
            let child = try await Self.read(destination.appending("stub_child.pyi"))
            #expect(child.contains("class Child(stub_fixture.records.Record):"))
        }
    }

    @Test
    func `writing stubs replaces stale files and preserves deterministic output`() async throws {
        try await withTemporaryDirectory { root in
            let destination = root.appending("typings")
            let sibling = root.appending("keep.txt")
            try await "keep".write(toFileAt: sibling, options: .newFile(replaceExisting: false))
            let stubs = Python::Stubs([StubRoot.self, StubRecords.self])
            try await stubs.write(to: destination.string)
            let first = try await Self.read(destination.appending("stub_fixture/records.pyi"))
            try await "obsolete".write(
                toFileAt: destination.appending("obsolete.pyi"),
                options: .newFile(replaceExisting: false),
            )

            try await stubs.write(to: destination.string)
            #expect(try await FileSystem.shared
                .info(forFileAt: destination.appending("obsolete.pyi")) == nil)
            #expect(try await Self.read(destination.appending("stub_fixture/records.pyi")) == first)
            #expect(try await Self.read(sibling) == "keep")

            try await Python::Stubs([]).write(to: destination.string)
            try await FileSystem.shared.withDirectoryHandle(atPath: destination) { handle in
                for try await entry in handle.listContents() {
                    Issue.record("Unexpected stub output: \(entry.name)")
                }
            }
        }
    }

    @Test
    func `generation and path errors preserve the existing output`() async throws {
        try await withTemporaryDirectory { root in
            let destination = root.appending("typings")
            try await FileSystem.shared.createDirectory(
                at: destination,
                withIntermediateDirectories: false,
            )
            let sentinel = destination.appending("keep.txt")
            try await "keep".write(toFileAt: sentinel, options: .newFile(replaceExisting: false))

            await #expect(throws: (any Swift::Error).self) {
                try await Python::Stubs([InvalidStubModule.self]).write(to: destination.string)
            }
            await #expect(throws: (any Swift::Error).self) {
                try await Python::Stubs([]).write(to: "/")
            }
            #expect(try await Self.read(sentinel) == "keep")
        }
    }

    private static func read(_ path: FilePath) async throws -> String {
        try await String(contentsOf: path, maximumSizeAllowed: .unlimited)
    }

    private static func checkDeclarations(in source: String) async throws {
        let session = try await Python::Runtime().session()
        try await withSession(session) { session in
            try await session.set(source, forKey: "stub_source")
            _ = try await session.evaluate(#"""
            import ast

            tree = ast.parse(stub_source)
            record = next(node for node in tree.body
                          if isinstance(node, ast.ClassDef) and node.name == 'Record')
            display_name = next(node for node in record.body
                                if isinstance(node, ast.FunctionDef) and node.name == 'display_name')
            assert ast.get_docstring(display_name) == r'A name containing "quotes" and a \ path.'

            unusual = [node for node in tree.body
                       if isinstance(node, ast.FunctionDef) and node.name == 'unusual']
            assert len(unusual) == 3
            assert all(node.decorator_list for node in unusual)
            assert len(unusual[0].args.kwonlyargs) == 2
            assert len(unusual[-1].args.posonlyargs) == 2
            """#)
        }
    }
}
