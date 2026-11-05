//
//  Created by Anton Spivak
//

import Python
import Testing

// MARK: - BufferScale

private struct BufferScale: Python::Decodable {
    let amount: UInt8

    init(from decoder: borrowing Python::Decoder) throws {
        amount = try decoder["amount"].get()
    }
}

// MARK: - BufferModule

@PythonModule("buffers")
private enum BufferModule {
    @PythonFunction
    static func sum(_ values: Span<UInt8>) -> Int {
        var result = 0
        for index in values.indices {
            result += Int(values[index])
        }
        return result
    }

    @PythonFunction
    static func scale(_ values: inout MutableSpan<UInt8>, by scale: BufferScale) {
        for index in values.indices {
            values[index] *= scale.amount
        }
    }

    @PythonFunction
    static func floating(_ values: Span<Double>) -> Double {
        var result = 0.0
        for index in values.indices {
            result += values[index]
        }
        return result
    }

    @PythonFunction
    static func text(_ text: UTF8Span) -> Int {
        text.span.count
    }

    @PythonFunction
    static func overlap(_ first: Span<UInt8>, _ second: inout MutableSpan<UInt8>) {
        if !first.isEmpty {
            second[0] = first[0]
        }
    }

    @PythonFunction
    static func reenter(
        _ values: inout MutableSpan<UInt8>,
        context: borrowing Python::Context,
    ) throws {
        try context["unsafe_reentry"].set(values.count)
    }
}

@Test
func exportedBufferArgumentsBorrowPythonStorage() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [BufferModule.self])
    _ = try await session.evaluate(#"""
    import buffers, array

    values = bytearray([1, 2, 3])
    assert buffers.sum(values) == 6
    buffers.scale(values, {'amount': 3})
    assert values == bytearray([3, 6, 9])
    assert buffers.sum(b'abc') == 294
    assert buffers.sum(memoryview(values)) == 18
    assert buffers.sum(b'') == 0
    assert buffers.floating(array.array('d', [1.25, 2.5])) == 3.75
    assert buffers.text('Привет\x00🐍') == len('Привет\x00🐍'.encode())

    rejected = [
        ("bytes as a string", TypeError, lambda: buffers.text(b'bad')),
        ("list as a buffer", BufferError, lambda: buffers.sum([1, 2])),
        ("strided view", BufferError, lambda: buffers.sum(memoryview(values)[::2])),
        ("wrong element type", BufferError, lambda: buffers.floating(array.array('f', [1]))),
        ("unaligned view", BufferError,
         lambda: buffers.floating(memoryview(bytearray(17))[1:].cast('d'))),
        ("read-only exporter", BufferError, lambda: buffers.scale(b'abc', {'amount': 2})),
        ("overlapping borrows", BufferError, lambda: buffers.overlap(values, memoryview(values))),
        ("Python reentry", RuntimeError, lambda: buffers.reenter(values)),
    ]
    for description, expected_error, action in rejected:
        try:
            action()
        except expected_error:
            pass
        else:
            raise AssertionError(f"Expected {expected_error.__name__} for {description}")

    buffers.scale(values, {'amount': 2})
    assert values == bytearray([6, 12, 18])
    assert 'unsafe_reentry' not in globals()
    """#)
    await session.close()
}

@Test
func explicitBufferLeaseMutatesAndReadsPythonStorage() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()
    _ = try await session.evaluate("""
    values = bytearray([6, 12, 18])
    invalid_buffer = [1, 2]
    """)
    try await session.enqueue { context in
        let invalid = try context["invalid_buffer"].object()
        do {
            let lease = try invalid.buffer(as: UInt8.self)
            _ = lease.count
            Issue.record("Expected an unsupported exporter to fail.")
        } catch let exception as Python::Exception {
            #expect(exception.name == "BufferError")
        }

        let object = try context["values"].object()
        let lease = try object.buffer(as: UInt8.self, isWritable: true)
        try lease.withMutableSpan { span in span[1] = 42 }
        let sum = try lease.withSpan { span in BufferModule.sum(span) }
        #expect(sum == 66)
    }
    _ = try await session.evaluate("assert values == bytearray([6, 42, 18])")
    await session.close()
}
