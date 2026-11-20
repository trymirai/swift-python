//
//  Created by Anton Spivak
//

import Python
import Testing

// MARK: - FailureFixture

@PythonExportedModule("failure_fixture")
private enum FailureFixture {
    @PythonFunction
    static func fail() throws {
        throw Python::Failure(.valueError, message: "left\0right")
    }
}

@Test
func exceptionDetailsSurviveBothDirectionsAcrossTheBridge() async throws {
    let session = try await Python::Runtime().session(modules: [FailureFixture.self])
    defer { await session.close() }

    _ = try await session.evaluate("""
    from failure_fixture import fail

    try:
        fail()
    except ValueError as error:
        message = str(error)

    class BrokenText(Exception):
        def __str__(self):
            raise ValueError("format failed")

    def broken():
        raise BrokenText()
    """)
    #expect(try await session.get("message", as: String.self) == "left\0right")

    let evaluated = try await session.requireFailure(evaluating: "broken()")
    let called = try await #require(throws: Python::Failure.self) {
        try await session.enqueue { py in _ = try py.object("broken")() }
    }
    #expect(evaluated.kind == .exception(.init(rawValue: "BrokenText")))
    #expect(evaluated.traceback?.contains("BrokenText") == true)
    #expect(called.kind == evaluated.kind)
}

@Test
func scalarSubclassesAndKeywordsPreservePythonValues() async throws {
    let session = try await Python::Runtime().session()
    defer { await session.close() }

    _ = try await session.evaluate("""
    from enum import IntEnum, StrEnum

    class Count(IntEnum):
        answer = 42

    class Label(StrEnum):
        answer = "yes"

    class Wide(int):
        def __str__(self):
            raise AssertionError("not a conversion")

    number, label, wide = Count.answer, Label.answer, Wide(2**80)

    def count(**keywords):
        return len(keywords)
    """)
    #expect(try await session.get("number", as: Int.self) == 42)
    #expect(try await session.get("wide", as: Int128.self) == 1 << 80)
    #expect(try await session.get("label", as: String.self) == "yes")
    try await expectPythonFailure(.exception(.typeError)) {
        try await session.enqueue { py in
            _ = try py.object("count")(arguments: [], keywords: [("x", 1), ("x", 2)])
        }
    }

    let count = try await session.enqueue { py in
        try py.object("count")(arguments: [], keywords: [("é", 1), ("e\u{301}", 2)])
            .decode(as: Int.self)
    }
    #expect(count == 2)
}

@Test
func optionalAttributesAndIterationPreservePythonFailures() async throws {
    let session = try await Python::Runtime().session(.source("""
    class Sample:
        present = None

        @property
        def broken(self):
            raise ValueError("getter")

    def sequence():
        yield 42
        raise LookupError("iterator")

    sample = Sample()
    """))
    defer { await session.close() }

    try await session.enqueue { py in
        let sample = try py.object("sample")
        if let _ = try sample.valueIfPresent(forAttribute: "missing") {
            Issue.record("A missing attribute returned a Python object")
        }
        guard let present = try sample.valueIfPresent(forAttribute: "present") else {
            Issue.record("An attribute containing None was missing")
            return
        }
        #expect(try present.decode(as: Int?.self) == nil)
        try expectPythonFailure(.exception(.valueError)) {
            _ = try sample.valueIfPresent(forAttribute: "broken")
        }

        var values = [Int]()
        let iterator = try #require(throws: Python::Failure.self) {
            try py.object("sequence")().forEach { values.append(try $0.decode()) }
        }
        #expect(values == [42])
        #expect(iterator.kind == .exception(.init(rawValue: "LookupError")))
    }
}
