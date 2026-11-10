//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import SystemPackage
import Testing

@Test
func defaultFileAccessUsesHostImportRootsForReadsOnly() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let readable = root.appending("readable")
        let outside = root.appending("readable-other")
        try await FileSystem.shared.createDirectory(
            at: readable,
            withIntermediateDirectories: false,
        )
        try await FileSystem.shared.createDirectory(at: outside, withIntermediateDirectories: false)
        try await "allowed".write(toFileAt: readable.appending("data"))
        try await "outside".write(toFileAt: outside.appending("data"))
        try await FileSystem.shared.createSymbolicLink(
            at: readable.appending("escape"),
            withDestination: outside.appending("data"),
        )

        let runtime = try await Python::Runtime()
        let session = try await runtime.session(importPaths: [readable.string])
        try await withSession(session) { session in
            try await session.set(outside.string, forKey: "outside")
            _ = try await session.evaluate("""
            import os, sys
            from pathlib import Path

            base = Path(sys.path[0])
            data = base / "data"
            assert data.read_text() == "allowed"
            sys.path.append(outside)
            for access in (
                lambda: Path(outside, "data").read_text(),
                lambda: (base / "escape").read_text(),
                lambda: data.write_text("changed"),
                lambda: os.chmod(data, 0o777),
                lambda: os.unlink(data),
            ):
                try:
                    access()
                except PermissionError:
                    pass
                else:
                    raise AssertionError("Unexpected file permission")
            """)
            try await session.replaceImportPaths([outside.string])
            _ = try await session.evaluate("assert Path(outside, 'data').read_text() == 'outside'")
        }
        #expect(try await contents(readable.appending("data")) == "allowed")
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func openRemainsBoundDuringAuthorization(swapParent: Bool) async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let approved = root.appending("approved")
        let protected = root.appending("protected")
        let moved = root.appending("moved")
        try await FileSystem.shared.createDirectory(
            at: approved,
            withIntermediateDirectories: false,
        )
        try await FileSystem.shared.createDirectory(
            at: protected,
            withIntermediateDirectories: false,
        )
        let original = approved.appending("data")
        let victim = protected.appending("data")
        let link = root.appending("link")
        try await "original".write(toFileAt: original)
        try await "untouched".write(toFileAt: victim)
        try await FileSystem.shared.createSymbolicLink(at: link, withDestination: original)

        let delegate = FileAccessDelegate { request in
            if
                request.path.lastComponent?.string == "data",
                case let .open(_, options) = request.operation, options.contains(.truncate)
            {
                // Change the visible path after the target has been pinned.
                if swapParent {
                    try await FileSystem.shared.moveItem(at: approved, to: moved)
                    try await FileSystem.shared.moveItem(at: protected, to: approved)
                } else {
                    try await FileSystem.shared.removeItem(at: link)
                    try await FileSystem.shared.createSymbolicLink(
                        at: link,
                        withDestination: victim,
                    )
                }
            }
            return true
        }
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(delegate: delegate)
        defer { await session.close() }
        try await session.set(root.string, forKey: "root")
        let result = try await session.evaluate(swapParent ? """
        import os
        directory = os.open(root + '/approved', os.O_RDONLY | os.O_DIRECTORY)
        with open(os.open('data', os.O_WRONLY | os.O_TRUNC, dir_fd=directory), 'w') as file:
            _ = file.write('written')
        os.close(directory)
        """ : """
        with open(root + '/link', 'w') as file:
            _ = file.write('written')
        """)
        #expect(result.end == .finished)
        #expect(try await contents(swapParent ? moved.appending("data") : original) == "written")
        #expect(try await contents(swapParent ? original : victim) == "untouched")
    }
}

@Test(.timeLimit(.minutes(1)))
func restrictedFileOperationsCheckDescriptorsAndNativeModules() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let allowed = root.appending("allowed")
        let denied = root.appending("denied")
        let original = allowed.appending("source")
        let protected = denied.appending("target")

        try await FileSystem.shared.createDirectory(at: allowed, withIntermediateDirectories: false)
        try await FileSystem.shared.createDirectory(at: denied, withIntermediateDirectories: false)
        try await "allowed".write(toFileAt: original)
        try await "protected".write(toFileAt: protected)

        let host = try FileDescriptor.open(protected, .readWrite)
        defer { try? host.close() }

        let delegate = FileAccessDelegate { request in
            !request.path.components.contains("denied")
        }
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(delegate: delegate)
        defer { await session.close() }
        try await session.set(root.string, forKey: "root")
        try await session.set(Int(host.rawValue), forKey: "host")

        let execution = try await session.evaluate("""
        import os, io, socket
        from pathlib import Path

        base = Path(root)
        source = base / 'allowed' / 'source'
        target = base / 'denied' / 'target'

        try:
            import sqlite3
        except ImportError:
            pass
        else:
            sqlite3.connect(target).execute('CREATE TABLE bypass (value int)')
            raise AssertionError('sqlite3 reached an unmediated file')
        try:
            import _ctypes
        except ImportError:
            pass
        else:
            raise AssertionError('ctypes loaded')

        def denied(operation):
            try:
                operation()
            except OSError:
                return
            raise AssertionError('operation was allowed')

        denied(lambda: open(host, 'r+'))
        denied(lambda: io.FileIO(source, 'r', opener=lambda *_: host))
        denied(lambda: os.read(host, 1))
        denied(lambda: os.close(host))
        denied(lambda: os.ftruncate(host, 0))
        denied(lambda: os.fstat(host))
        denied(lambda: socket.socket(fileno=host))

        denied(lambda: os.listdir(target.parent))
        denied(lambda: list(os.scandir(target.parent)))
        denied(lambda: os.stat(target))
        denied(lambda: os.rename(source, target))
        denied(lambda: os.unlink(target))

        with os.scandir(source.parent) as entries:
            entry, = list(entries)
        assert entry.name == 'source' and entry.stat().st_size == 7
        source.rename(source.with_name('moved'))
        assert not source.exists()
        source.write_text('new')
        with open(source, 'w') as file:
            _ = file.write('x')
        assert source.read_text() == 'x'
        source.unlink()
        """)
        #expect(execution.end == .finished)
        #expect(try await FileSystem.shared.info(forFileAt: original) == nil)
        #expect(try await contents(allowed.appending("moved")) == "allowed")
        #expect(try await contents(protected) == "protected")
    }
}

@Test(.timeLimit(.minutes(1)))
func rollbackPreservesFileIOAndItsPosition() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let path = root.appending("data")
        try await "abcd".write(toFileAt: path)

        let runtime = try await Python::Runtime()
        let session = try await runtime.session(directory: root.string, transactional: true)
        defer { await session.close() }
        try await session.set(path.string, forKey: "path")
        _ = try await session.evaluate("""
        import io
        file = io.FileIO(path)
        alias = file
        identity = id(file)
        descriptor = file.fileno()
        assert file.read(1) == b'a'
        """)

        _ = try await #require(throws: Python::ExecutionError.self) {
            try await session.evaluate("""
            assert file.read(1) == b'b'
            file.close()
            replacement = io.FileIO(path)
            assert replacement.fileno() != descriptor
            del file
            raise ValueError('rollback')
            """)
        }

        let result = try await session.evaluate("""
        assert file is alias and id(file) == identity
        assert not file.closed and file.fileno() == descriptor
        assert file.read() == b'bcd'
        assert 'replacement' not in globals()
        file.close()
        """)
        #expect(result.end == .finished)
        #expect(try await contents(path) == "abcd")
    }
}

// MARK: - FileAccessDelegate

struct FileAccessDelegate: Python::Session.Delegate {
    let authorize: @Sendable (Python::Session.FileAccessRequest) async throws -> Bool

    func shouldAllowFileAccess(_ request: Python::Session.FileAccessRequest) async throws -> Bool {
        try await authorize(request)
    }
}

private func contents(_ path: FilePath) async throws -> String {
    try await String(contentsOf: path, maximumSizeAllowed: .unlimited)
}
