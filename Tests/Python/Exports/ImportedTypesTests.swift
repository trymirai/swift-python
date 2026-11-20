//
//  Created by Anton Spivak
//

import _NIOFileSystem
#if canImport(Foundation)
import Foundation
#endif
import Python
import SystemPackage
import Testing

// MARK: - PythonFuture

@PythonImportedClass(module: "asyncio", name: "Future")
private struct PythonFuture {
    @PythonInit
    init(in session: Python::Session) async throws

    @PythonFunction("set_result")
    func resolve(_ value: Int) async throws

    @PythonFunction
    func result() async throws -> Int
}

@Test(.timeLimit(.minutes(1)))
func importedConstructorsReturnAwaitableInstancesOnTheirOwningLoop() async throws {
    let session = try await Python::Runtime().session()
    defer { await session.close() }

    let future = try await PythonFuture(in: session)
    try await session.set(future, forKey: "future")
    _ = try await session.evaluate("""
    import asyncio
    assert future.get_loop() is asyncio.get_running_loop()
    await asyncio.sleep(0)
    """)
    try await future.resolve(42)
    #expect(try await future.result() == 42)

    try await session.reset()
    try await expectPythonFailure(.exception(.referenceError)) { _ = try await future.result() }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func sessionCallsAwaitReadyAndPendingFutures(ready: Bool) async throws {
    let session = try await Python::Runtime().session(.source("""
    import asyncio
    def complete(future, value, ready):
        if ready:
            future.set_result(value)
        else:
            asyncio.get_running_loop().call_soon(future.set_result, value)
        return future
    """))
    defer { await session.close() }

    let complete = try await session.get("complete", as: Python::Reference.self)
    for value: Int? in [42, nil] {
        let future = try await PythonFuture(in: session)
        let result: Int? = try await session.call(complete, arguments: [future, value, ready])
        #expect(result == value)
    }
}

// MARK: - ScaledValue

@PythonImportedClass(module: "__main__", name: "ScaledValue")
private struct ScaledValue {
    @PythonInit
    init(_ value: Int, scale multiplier: Int = 2, in context: Python::Context) throws

    @PythonInit
    init(_ value: Int, scale multiplier: Int = 2, in session: Python::Session) async throws

    @PythonProperty(isReadOnly: true)
    var total: Int
}

@Test(.timeLimit(.minutes(1)))
func importedInitializersMapSwiftArgumentsToThePythonConstructor() async throws {
    let session = try await Python::Runtime().session()
    defer { await session.close() }

    _ = try await session.evaluate("""
    class ScaledValue:
        def __init__(self, value, /, *, scale):
            if scale < 0:
                raise ValueError("scale must be nonnegative")
            self.total = value * scale
    """)

    let value = try await ScaledValue(6, in: session)
    try await session.enqueue { py in
        #expect(try value.total == 12)
        let local = try ScaledValue(6, scale: 3, in: py)
        #expect(try local.total == 18)

        let module = try py.import(module: "__main__")
        let type = try module.value(forAttribute: "ScaledValue")
        let dynamic = try type(6, keywords: [("scale", 3)])
        #expect(try dynamic.value(forAttribute: "total").decode(as: Int.self) == 18)

        try expectPythonFailure(.exception(.valueError)) {
            _ = try ScaledValue(6, scale: -1, in: py)
        }
    }
    try await expectPythonFailure(.exception(.valueError)) {
        _ = try await ScaledValue(6, scale: -1, in: session)
    }
}

// MARK: - ImportedReport

@PythonImportedClass(module: "report_fixture", name: "Report")
private struct ImportedReport {
    @PythonProperty
    static var category: String

    @PythonProperty("display_name")
    var title: String

    @PythonProperty("kind", isReadOnly: true)
    var kind: String

    @PythonFunction
    func rename(_ object: String, _ suffix: String, copies: Int) throws -> ImportedReport

    @PythonFunction
    func refresh() async throws -> ImportedReport

    @PythonFunction
    func fail() async throws

    @PythonFunction
    func wait() async throws

    @PythonFunction("wait_until_started")
    func waitUntilStarted() async throws

    @PythonFunction("wait_until_cancelled")
    func waitUntilCancelled() async throws

    @PythonFunction("make")
    static func make(_ session: String) async throws -> ImportedReport
}

// MARK: - ImportedTypes

@PythonExportedModule("imported_types", source: """
'Imports for exported types.'
from __future__ import annotations; leap_day = datetime.date(2024, 2, 29)

def source_title(report: report_fixture.Report) -> str:
    return report.display_name
""")
private enum ImportedTypes {
    @PythonFunction
    static func keep(_ report: ImportedReport) async -> ImportedReport {
        await Task.yield()
        return report
    }

    @PythonFunction
    static func title(_ report: ImportedReport) throws -> String {
        try report.title
    }

    @PythonFunction("pathlib")
    static func path(_ path: Python::Path) -> Python::Path {
        path
    }

    @PythonFunction("make_date")
    static func makeDate(_ text: String) throws -> Python::Date {
        try .fromISOFormat(text)
    }

    @PythonFunction
    static func edit(_ report: ImportedReport) throws -> ImportedReport {
        try report.$title("draft")
        try report.$title { $0.uppercased() }
        guard try report.kind == "report" else {
            throw Python::Failure(.typeError, message: "Expected a report.")
        }
        return try report.rename("[", "]", copies: 2)
    }

    @PythonFunction
    static func refresh(_ report: ImportedReport) async throws -> ImportedReport {
        async let updated = report.refresh()
        async let created = ImportedReport.make("other")
        _ = try await created
        try ImportedReport.$category("updated")
        guard try ImportedReport.category == "updated" else {
            throw Python::Failure(.valueError, message: "Unexpected class property.")
        }
        return try await updated
    }

    @PythonFunction
    static func suffix(_ title: String) async -> String {
        await Task.yield()
        return title + "!"
    }

    @PythonFunction
    static func fail(_ report: ImportedReport) async throws {
        try await report.fail()
    }

    @PythonFunction
    static func cancel(_ report: ImportedReport) async throws -> Bool {
        let task = Task { try await report.wait() }
        defer { task.cancel() }
        try await report.waitUntilStarted()
        task.cancel()
        do {
            try await task.value
            return false
        } catch is CancellationError {
            try await report.waitUntilCancelled()
            return true
        }
    }

    @PythonFunction("dict")
    static func dates(_ dates: [String: Python::DateTime]) -> [String: Python::DateTime] {
        dates
    }

    @PythonFunction
    static func paths(_ paths: [Python::Path]?) -> [Python::Path]? {
        paths
    }
}

// MARK: - ImportedRecord

@PythonExportedClass("Record", module: ImportedTypes.self)
private final class ImportedRecord {
    @PythonProperty
    let path: Python::Path

    @PythonProperty
    var date: Python::Date?

    @PythonInit
    init(_ path: Python::Path) throws {
        self.path = path
        try $date(nil)
    }
}

@Test(.timeLimit(.minutes(1)))
func importedTypesSupplyLazyAnnotationsAndPreserveIdentity() async throws {
    try await withTemporaryDirectory { root in
        try await reportFixtureSource.write(toFileAt: root.appending("report_fixture.py"))

        let runtime = try await Python::Runtime(cacheDirectory: root.appending("cache").string)
        let session = try await runtime.session(
            importPaths: [root.string],
            modules: [ImportedTypes.self],
        )

        try await withSession(session) { session in
            let execution = try await session.evaluate(importedTypesChecks)
            #expect(execution.end == .finished)
            let created = try await ImportedReport.make("outside", in: session)
            let refreshed = try await created.refresh()
            let title = try await session.enqueue { _ in try refreshed.title }
            #expect(title == "outside!")

            try await session.reset()
            try await expectPythonFailure(.exception(.referenceError)) {
                _ = try await created.refresh()
            }
            let fresh = try await ImportedReport.make("fresh", in: session)
            #expect(try await session.enqueue { _ in try fresh.title } == "fresh")
        }
    }
}

private let reportFixtureSource = """
import asyncio

class Report:
    category = "report"

    def __init__(self, title='Report'):
        self.display_name = title
        self.started = asyncio.Event()
        self.cancelled = asyncio.Event()

    @property
    def kind(self):
        return "report"

    def rename(self, prefix, suffix, *, copies):
        self.display_name = prefix + self.display_name * copies + suffix
        return self

    def refresh(self):
        async def update():
            import imported_types
            self.display_name = await imported_types.suffix(self.display_name)
            return self
        return update()

    @classmethod
    async def make(cls, name):
        await asyncio.sleep(0)
        return cls(name)

    async def fail(self):
        await asyncio.sleep(0)
        raise ValueError("cannot refresh")

    async def wait(self):
        self.started.set()
        try:
            await asyncio.Future()
        finally:
            self.cancelled.set()

    async def wait_until_started(self):
        await self.started.wait()

    async def wait_until_cancelled(self):
        await self.cancelled.wait()
"""

private let importedTypesChecks = """
import inspect
import sys
import typing
import imported_types as exports

assert 'report_fixture' not in sys.modules
signature = inspect.signature(exports.keep)
assert signature.parameters['report'].annotation == 'report_fixture.Report'
assert signature.return_annotation == 'report_fixture.Report'
assert 'report: report_fixture.Report' in inspect.getsource(exports.keep)
assert exports.__doc__ == 'Imports for exported types.'
assert 'report_fixture' not in sys.modules

Report = typing.get_type_hints(exports.keep)['return']
assert Report is sys.modules['report_fixture'].Report
report = Report()
assert await exports.keep(report) is report
assert exports.title(report) == 'Report'
assert exports.source_title(report) == 'Report'
assert typing.get_type_hints(exports.source_title)['report'] is Report

assert exports.edit(report) is report
assert report.display_name == '[DRAFTDRAFT]'

assert await exports.refresh(report) is report
assert report.display_name == '[DRAFTDRAFT]!'

try:
    await exports.fail(report)
except ValueError as error:
    assert str(error) == 'cannot refresh'
else:
    raise AssertionError('expected ValueError')

assert await exports.cancel(report)

try:
    await exports.keep(object())
except TypeError as error:
    assert 'report_fixture.Report' in str(error)
else:
    raise AssertionError('expected TypeError')

from datetime import date, datetime
from pathlib import Path
assert typing.get_type_hints(exports.paths)['return'] == list[Path] | None
path = Path('report.txt')
assert exports.paths([path])[0] is path
assert exports.paths(None) is None

assert typing.get_type_hints(exports.dict)['return'] == dict[str, datetime]
assert typing.get_type_hints(exports.pathlib)['return'] is Path
assert exports.pathlib(path) is path

assert exports.leap_day == date(2024, 2, 29)
assert type(exports.make_date('2024-02-29')) is date

record = exports.Record(path)
assert typing.get_type_hints(exports.Record.path.fget)['return'] is Path
assert typing.get_type_hints(exports.Record.date.fset)['value'] == date | None
assert record.path is path
record.date = exports.leap_day
assert record.date is exports.leap_day
"""

@Test
func standardImportedTypesRetainThePythonInstance() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()

    try await withSession(session) { session in
        _ = try await session.evaluate("""
        from datetime import date, datetime, timedelta, tzinfo
        from pathlib import Path

        class Zone(tzinfo):
            def utcoffset(self, value):
                return timedelta(hours=2)

        path = Path('reports/today.txt')
        day = date(2000, 2, 29)
        moment = datetime(2000, 2, 29, 12, tzinfo=Zone(), fold=1)
        """)

        let path = try await session.get("path", as: Python::Path.self)
        let day = try await session.get("day", as: Python::Date.self)
        let moment = try await session.get("moment", as: Python::DateTime.self)
        let dateSubclass = try await session.get("moment", as: Python::Date.self)

        try await session.set(path, forKey: "swift_path")
        try await session.set(day, forKey: "swift_day")
        try await session.set(moment, forKey: "swift_moment")
        try await session.set(dateSubclass, forKey: "swift_date_subclass")
        _ = try await session.evaluate("""
        assert swift_path is path
        assert swift_day is day
        assert swift_moment is moment
        assert swift_moment.tzinfo is moment.tzinfo
        assert swift_date_subclass is moment
        """)

        try await session.reset()
        await #expect(throws: Python::Failure.self) {
            try await session.set(day, forKey: "previous_day")
        }
    }
}

@Test
func aSwiftTaskCannotBorrowAnotherTasksPythonAttachment() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()

    try await withSession(session) { session in
        let task = try await session.enqueue { context in
            let day = try Python::Date(year: 2000, month: 2, day: 29, in: context)
            let attachedContext = context
            return Task.immediate {
                try day.object(in: attachedContext).value(forAttribute: "year").decode(as: Int.self)
            }
        }
        try await expectPythonFailure(.exception(.runtimeError)) {
            _ = try await task.value
        }
    }
}

@Test
func standardImportedTypesSupportSwiftConstructionAndConversion() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()

    try await withSession(session) { session in
        try await session.enqueue { context in
            let day = try checkCalendarDate(in: context)
            try checkLocalDateTime(on: day, in: context)
            try checkUTCDateTime(in: context)
            try checkPathConversions(in: context)
        }
    }
}

private func checkCalendarDate(in context: Python::Context) throws -> Python::Date {
    let day = try Python::Date(year: 2000, month: 2, day: 29, in: context)
    #expect(try day.isoFormat() == "2000-02-29")
    #expect(try day.weekday() == 1)
    #expect(throws: Python::Failure.self) {
        try Python::Date(year: 2001, month: 2, day: 29, in: context)
    }
    return day
}

private func checkLocalDateTime(on day: Python::Date, in context: Python::Context) throws {
    let local = try Python::DateTime(
        year: 2000,
        month: 2,
        day: 29,
        hour: 12,
        microsecond: 125_000,
        fold: 1,
        in: context,
    )
    #expect(try local.date().isoFormat() == day.isoFormat())
    #expect(try local.microsecond == 125_000)
    #expect(try local.fold == 1)
    #expect(try local.timeZoneName() == nil)
}

private func checkUTCDateTime(in context: Python::Context) throws {
    let utc = try Python::DateTime(utcTimestamp: -0.125, in: context)
    #expect(try utc.isoFormat() == "1969-12-31T23:59:59.875000+00:00")
    #expect(try utc.timestamp() == -0.125)

    #if canImport(Foundation)
    let instant = Foundation::Date(timeIntervalSince1970: 0.25)
    let dateTime = try Python::DateTime(instant, in: context)
    #expect(try dateTime.timeZoneName() == "UTC")
    #expect(abs(try dateTime.foundationDate().timeIntervalSince(instant)) < 0.000_001)
    #endif
}

private func checkPathConversions(in context: Python::Context) throws {
    let base = try Python::Path("reports", in: context)
    let path = try base.joinPath("résumé.txt").withSuffix(".md")
    #expect(try path.stem == "résumé")
    #expect(try path.suffix == ".md")
    #expect(try path.parts == ["reports", "résumé.md"])
    #expect(try path.relativeTo(base).string() == "résumé.md")
    #expect(try path.filePath == FilePath("reports/résumé.md"))
    #expect(try Python::Path(path.filePath, in: context).string() == path.string())
    #expect(try !path.isAbsolute())

    let invalidPath = try Python::Path("a\0b", in: context)
    #expect(throws: Python::Failure.self) { try invalidPath.filePath }
}
