//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import Testing

@Test(.timeLimit(.minutes(1)))
func sqliteKeepsActualStateAfterErrors() async throws {
    let session = try await Python::Runtime().session()
    defer { await session.close() }

    _ = try await session.evaluate("""
    import sqlite3

    connection = sqlite3.connect(':memory:')
    connection.execute('CREATE TABLE values_ (value int)')
    values = []
    """)
    _ = try await #require(throws: Python::ExecutionError.self) {
        try await session.evaluate("""
        values.append(42)
        connection.execute('INSERT INTO values_ VALUES (42)')
        connection.commit()
        connection.create_function('double', 1, lambda value: value * 2)
        cursor = connection.execute('SELECT value FROM values_')
        raise ValueError('state remains')
        """)
    }
    let retained = try await session.evaluate("""
    assert values == [42]
    assert cursor.fetchone() == (42,)
    assert connection.execute('SELECT double(value) FROM values_').fetchall() == [(84,)]
    """)
    #expect(retained.end == .finished)

    _ = try await #require(throws: Python::ExecutionError.self) {
        try await session.evaluate("connection.close()\nraise ValueError('closed')")
    }
    let closed = try await session.evaluate("""
    try:
        connection.execute('SELECT 42')
    except sqlite3.ProgrammingError:
        pass
    else:
        raise AssertionError('The closed connection was reopened')
    assert sqlite3.connect(':memory:').execute('SELECT 42').fetchone() == (42,)
    """)
    #expect(closed.end == .finished)

    try await session.reset()
    let reset = try await session.evaluate("""
    assert 'connection' not in globals() and 'values' not in globals()
    import sqlite3
    assert sqlite3.connect(':memory:').execute('SELECT 42').fetchone() == (42,)
    """)
    #expect(reset.end == .finished)
}

@Test(.timeLimit(.minutes(1)))
func sqliteUsesOperatingSystemFileAccess() async throws {
    try await withTemporaryDirectory { root in
        let database = root.appending("native.sqlite")
        let session = try await Python::Runtime().session(
            delegate: FileAccessDelegate { _ in false },
        )
        defer { await session.close() }
        try await session.set(database.string, forKey: "path")

        let result = try await session.evaluate("""
        import sqlite3

        connection = sqlite3.connect(path)
        connection.execute('CREATE TABLE values_ (value int)')
        connection.execute('INSERT INTO values_ VALUES (42)')
        connection.commit()
        connection.close()
        connection = sqlite3.connect(path)
        assert connection.execute('SELECT value FROM values_').fetchone() == (42,)
        connection.close()
        """)
        #expect(result.end == .finished)
        #expect(try await FileSystem.shared.info(forFileAt: database)?.type == .regular)
    }
}

@Test(.timeLimit(.minutes(1)))
func opensslHashesKeepActualStateAfterErrors() async throws {
    let session = try await Python::Runtime().session()
    defer { await session.close() }
    _ = try await session.evaluate("""
    import _hashlib, hashlib

    value = hashlib.sha256(b'first')
    assert isinstance(value, _hashlib.HASH)
    """)
    _ = try await #require(throws: Python::ExecutionError.self) {
        try await session.evaluate("value.update(b'second')\nraise ValueError('state remains')")
    }
    let result = try await session.evaluate("""
    assert value.hexdigest() == hashlib.sha256(b'firstsecond').hexdigest()
    """)
    #expect(result.end == .finished)
}
