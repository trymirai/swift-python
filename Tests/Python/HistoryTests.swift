//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import SystemPackage
import Testing

@Test
func historyKeepsSourcesAndActualFinalResults() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(history: .init(outputs: .unlimited))
    let firstSource = "data = {'count': 42}\nprint('ready')\ndata"
    try await withSession(session) { session in
        let first = try await session.evaluate(firstSource)
        #expect(first.number == 1)
        #expect(first.output.stdout == "ready\n{'count': 42}\n")
        try await session.set(firstSource, forKey: "source")

        let check = try await session.evaluate("""
        assert In[1] == source
        assert Out[1] is data
        Out[1]['count'] += 1
        assert data['count'] == 43
        assert list(In) == [1]
        assert not any(name.startswith('__swift_python_result__') for name in globals())
        """, recordingHistory: false)
        #expect(check.number == nil)

        let expressions = try await session.evaluate("1\n2")
        #expect(expressions.number == 2)
        #expect(expressions.output.stdout == "1\n2\n")
        _ = try await session.evaluate("print('printed')")
        _ = try await session.evaluate("assigned = 99")
        let awaited = try await session.evaluate("""
        import asyncio
        await asyncio.sleep(0, result=data)
        """)
        #expect(awaited.number == 5)
        _ = try await session.evaluate("""
        assert Out[2] == 2
        assert 3 not in Out and 4 not in Out
        assert Out[5] is data
        assert list(In) == [1, 2, 3, 4, 5]
        """, recordingHistory: false)
        let globals = try await session.evaluate("globals()")
        #expect(globals.number == 6)
        #expect(!globals.output.stdout.contains("__swift_python_result__"))
        let failure = try await #require(throws: Python::ExecutionError.self) {
            try await session.evaluate("""
            class BadDisplay:
                def __repr__(self):
                    raise ValueError('display failed')
            BadDisplay()
            """)
        }
        #expect(failure.number == 7)
        _ = try await session.evaluate("""
        assert Out[6] is globals()
        assert 7 not in Out
        assert not any(name.startswith('__swift_python_result__') for name in globals())
        """, recordingHistory: false)
        _ = try await session.evaluate("""
        import sys
        rendered = []
        def custom_displayhook(value):
            if value is not None:
                rendered.append(value)
        sys.displayhook = custom_displayhook
        """, recordingHistory: false)
        let custom = try await session.evaluate("data")
        #expect(custom.number == 8)
        #expect(custom.output.stdout.isEmpty)
        _ = try await session.evaluate("""
        assert Out[8] is data
        assert rendered == [data]
        assert sys.displayhook is custom_displayhook
        """, recordingHistory: false)
    }
}

@Test
func historyInputRetentionOwnsAndReadsItsFiles() async throws {
    try await withTemporaryDirectory { root in
        let unrelated = root.appending("keep.txt")
        try await "keep".write(toFileAt: unrelated)
        let first = root.appending("first.py")
        let second = root.appending("second.py")
        let stdout = root.appending("stdout.txt")
        let stderr = root.appending("stderr.txt")
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(history: .init(
            inputs: .last(1),
            outputs: .last(1),
        ))
        try await withSession(session) { session in
            _ = try await session.evaluate("first = 1\nfirst", redirecting: [
                .source: first,
                .stdout: stdout,
                .stderr: stderr,
            ])
            let execution = try await session.evaluate("second = 2\nsecond", redirecting: [
                .source: second,
                .stdout: stdout,
                .stderr: stderr,
            ])
            #expect(execution.output.stdout.isEmpty)
            #expect(try await FileSystem.shared.info(forFileAt: first) == nil)
            #expect(try await readText(at: second) == "second = 2\nsecond")
            #expect(try await readText(at: stdout) == "1\n2\n")

            // The input view reads the file instead of retaining another source string.
            try await "stored source".write(
                toFileAt: second,
                options: .newFile(replaceExisting: true),
            )
            _ = try await session.evaluate("""
            assert list(In) == [2]
            assert len(In) == 1
            assert In[2] == 'stored source'
            assert list(Out) == [2] and Out[2] == 2
            try:
                In[1]
            except KeyError:
                pass
            else:
                raise AssertionError('expired source is still indexed')
            """, recordingHistory: false)
        }
        #expect(try await readText(at: second) == "stored source")
        #expect(try await readText(at: stdout) == "1\n2\n")
        #expect(try await readText(at: stderr) == "")
        #expect(try await readText(at: unrelated) == "keep")
    }
}

@Test
func historyUsesMemoryWithoutSourceRedirection() async throws {
    try await withTemporaryDirectory { root in
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(
            directory: root.string,
            history: .init(outputs: .unlimited),
        )
        try await withSession(session) { session in
            for number in 1 ... 36 {
                #expect(try await session.evaluate(String(number)).number == number)
            }
            _ = try await session.evaluate("""
            assert len(In) == 36
            assert In[1] == '1' and In[36] == '36'
            assert len(Out) == 36
            assert Out[1] == 1 and Out[36] == 36
            """, recordingHistory: false)
            #expect(try await ProjectFixture.directoryNames(at: root).isEmpty)
        }
    }
}

@Test
func historySourceRedirectRequiresANewFileAndAnExistingParent() async throws {
    try await withTemporaryDirectory { root in
        let existing = root.appending("existing.py")
        let missing = root.appending("missing/input.py")
        let shared = root.appending("shared.py")
        let unrecorded = root.appending("unrecorded.py")
        try await "keep".write(toFileAt: existing)
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(history: .init())
        try await withSession(session) { session in
            for path in [existing, missing] {
                await #expect(throws: (any Error).self) {
                    try await session.evaluate("unexpected = True", redirecting: [.source: path])
                }
            }
            await #expect(throws: (any Error).self) {
                try await session.evaluate("unexpected = True", redirecting: [
                    .source: shared,
                    .stdout: shared,
                ])
            }
            let check = try await session.evaluate("""
            assert 'unexpected' not in globals()
            assert not In and not Out
            """, recordingHistory: false, redirecting: [.source: unrecorded])
            #expect(check.number == nil)
            #expect(try await readText(at: existing) == "keep")
            #expect(try await FileSystem.shared
                .info(forFileAt: missing.removingLastComponent()) == nil)
            #expect(try await FileSystem.shared.info(forFileAt: shared) == nil)
            #expect(try await FileSystem.shared.info(forFileAt: unrecorded) == nil)
        }
    }
}

@Test
func historyOutputEvictionReleasesPythonObjects() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(history: .init(inputs: .last(1), outputs: .last(1)))
    try await withSession(session) { session in
        _ = try await session.evaluate("""
        import gc, weakref
        watched = []
        class Item:
            pass
        def make_item():
            item = Item()
            watched.append(weakref.ref(item))
            return item
        """, recordingHistory: false)
        _ = try await session.evaluate("make_item()")
        _ = try await session.evaluate("make_item()")
        _ = try await session.evaluate("""
        gc.collect()
        assert list(In) == [2] and In[2] == 'make_item()'
        assert list(Out) == [2]
        assert watched[0]() is None
        assert watched[1]() is Out[2]
        Out.clear()
        gc.collect()
        assert watched[1]() is None
        """, recordingHistory: false)
    }
}

// MARK: - HistoryPublicationError

private enum HistoryPublicationError: Error {
    case rejected
}

@Test
func historyInputsSurviveRollbackAndReset() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(
        transactional: true,
        history: .init(outputs: .last(1)),
    )
    try await withSession(session) { session in
        _ = try await session.evaluate("data = {'value': 1}\ndata")
        let failed = "Out.clear()\ndata['value'] = 9\nraise ValueError('failed')"
        let error = try await #require(throws: Python::ExecutionError.self) {
            try await session.evaluate(failed)
        }
        #expect(error.number == 2)
        await #expect(throws: HistoryPublicationError.self) {
            try await session.evaluate("{'unpublished': True}", committing: { _ in
                throw HistoryPublicationError.rejected
            })
        }
        _ = try await session.evaluate("""
        assert list(In) == [1, 2, 3]
        assert 'raise ValueError' in In[2]
        assert list(Out) == [1]
        assert Out[1] is data and data['value'] == 1
        """, recordingHistory: false)

        try await session.reset()
        _ = try await session.evaluate("""
        assert not Out
        assert list(In) == [1, 2, 3]
        assert 'data' not in globals()
        """, recordingHistory: false)
        #expect(try await session.evaluate("4").number == 4)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func historyRecordsInterruptedAttempts(timeout: Bool) async throws {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let suspended = AsyncStream<Void>.makeStream()
    defer {
        entered.continuation.finish()
        suspended.continuation.finish()
    }
    let host = Python::Module("host", functions: [
        .init("wait") { _ in
            entered.continuation.yield(())
            for await _ in suspended.stream {}
            try Task.checkCancellation()
            return .none
        },
    ])
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(
        moduleDefinitions: [host],
        transactional: true,
        history: .init(outputs: .unlimited),
    )
    try await withSession(session) { session in
        _ = try await session.evaluate("from host import wait\n{'saved': True}")
        let task = Task {
            defer { entered.continuation.finish() }
            return try await session.evaluate(
                "Out.clear()\nawait wait()",
                timeout: timeout ? .seconds(2) : nil,
            )
        }
        defer { task.cancel() }
        if !timeout {
            _ = try await #require(nextSignal(from: entered.stream))
            task.cancel()
        }
        let result = try await task.value
        #expect(result.number == 2)
        #expect(result.end == (timeout ? .timedOut : .stopped))
        _ = try await session.evaluate("""
        assert list(In) == [1, 2]
        assert In[2].endswith('await wait()')
        assert list(Out) == [1]
        assert Out[1] == {'saved': True}
        """, recordingHistory: false)
    }
}

@Test
func historySessionsAreIsolated() async throws {
    let runtime = try await Python::Runtime()
    let first = try await runtime.session(history: .init(outputs: .unlimited))
    let second = try await runtime.session(history: .init(outputs: .unlimited))
    defer {
        await first.close()
        await second.close()
    }
    _ = try await first.evaluate("'first'")
    _ = try await second.evaluate("'second'")
    _ = try await first.evaluate("assert Out[1] == 'first'", recordingHistory: false)
    _ = try await second.evaluate("assert Out[1] == 'second'", recordingHistory: false)
    await first.close()
    _ = try await second.evaluate("assert Out[1] == 'second'", recordingHistory: false)
}

@Test
func historyValidatesLimitsAndIsOffByDefault() async throws {
    let runtime = try await Python::Runtime()
    for count in [-1, 0] {
        await #expect {
            try await runtime.session(history: .init(inputs: .last(count)))
        } throws: { error in
            String(describing: error).contains("history entry limit must be positive")
        }
        await #expect {
            try await runtime.session(history: .init(outputs: .last(count)))
        } throws: { error in
            String(describing: error).contains("history entry limit must be positive")
        }
    }
    try await withTemporaryDirectory { root in
        let source = root.appending("unused.py")
        let session = try await runtime.session()
        try await withSession(session) { session in
            let execution = try await session.evaluate(
                "assert 'In' not in globals() and 'Out' not in globals()",
                redirecting: [.source: source],
            )
            #expect(execution.number == nil)
            #expect(try await FileSystem.shared.info(forFileAt: source) == nil)
        }
    }
}

@Test
func historyNumbersAnAttemptWhoseInitializationFails() async throws {
    try await withTemporaryDirectory { root in
        let source = root.appending("input.py")
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(
            .source("raise ValueError('startup failed')"),
            history: .init(),
        )
        try await withSession(session) { session in
            let error = try await #require(throws: Python::ExecutionError.self) {
                try await session.evaluate("'not reached'", redirecting: [.source: source])
            }
            #expect(error.number == 1)
            #expect(try await readText(at: source) == "'not reached'")
        }
    }
}

@Test(arguments: [false, true])
func historyBindsToTheSelectedModuleNamespace(project: Bool) async throws {
    try await withTemporaryDirectory { root in
        try await """
        import asyncio
        await asyncio.sleep(0)
        def read_input(number):
            return In[number]
        def read_output(number):
            return Out[number]
        """.write(toFileAt: root.appending("workload.py"))
        let runtime = try await Python::Runtime()
        let startup: Python::Session.Startup = project
            ? .project(directory: root.string, module: "workload")
            : .module("workload")
        let session = try await runtime.session(
            startup,
            importPaths: [root.string],
            history: .init(outputs: .unlimited),
        )
        try await withSession(session) { session in
            _ = try await session.evaluate("data = {'value': 1}\ndata")
            _ = try await session.evaluate("""
            assert read_input(1) == "data = {'value': 1}\\ndata"
            assert read_output(1) is data
            """, recordingHistory: false)
        }
    }
}
