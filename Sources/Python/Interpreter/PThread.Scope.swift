//
//  Created by Anton Spivak
//

internal import libcpython

extension PThread {
    // Installed only for a synchronous attachment. Python's GIL protects storage.
    @safe
    final class Scope {
        let storage: Interpreter.Storage
        let execution: Session.Control?

        @unsafe
        private let task: UnsafeCurrentTask?

        var constructedWrappers: [Reference] = []

        var streams: Session.Stream.Descriptors?

        @unsafe
        private init(
            storage: Interpreter.Storage,
            execution: Session.Control?,
            streams: Session.Stream.Descriptors?,
            task: UnsafeCurrentTask?,
        ) {
            self.storage = storage
            self.execution = execution
            self.streams = streams
            unsafe self.task = task
        }

        static var current: Scope? {
            guard let pointer = unsafe CPython_CurrentScope() else {
                return nil
            }
            return unsafe Unmanaged<Scope>.fromOpaque(pointer).takeUnretainedValue()
        }

        var matchesTask: Bool {
            unsafe withUnsafeCurrentTask { unsafe $0 == task }
        }

        // Register only while attached: the GIL keeps the thread-state pointers alive.
        func withEvaluation<Result: ~Copyable>(_ body: () throws -> Result) rethrows -> Result {
            guard let execution else {
                return try body()
            }
            execution.beginEvaluation(in: storage.key)
            defer { execution.endEvaluation() }

            var evaluation = unsafe CPython_Evaluation(
                context: Unmanaged.passUnretained(execution).toOpaque(),
                interrupt: { context in unsafe Object.interrupt(context) },
            )
            var result: Result?
            try withUnsafeMutablePointer(to: &evaluation) { pointer in
                let previous = unsafe CPython_SetEvaluation(pointer)
                defer { _ = unsafe CPython_SetEvaluation(previous) }
                result = try body()
            }
            return result!
        }

        static func run<Result: ~Copyable>(
            storage: Interpreter.Storage,
            execution: Session.Control?,
            streams: Session.Stream.Descriptors? = nil,
            _ body: (Scope) throws -> Result,
        ) rethrows -> Result {
            var result: Result?
            unsafe try withUnsafeCurrentTask { task in
                let scope = unsafe Scope(
                    storage: storage,
                    execution: execution,
                    streams: streams,
                    task: task,
                )
                let previous = unsafe CPython_SetScope(Unmanaged.passUnretained(scope).toOpaque())
                defer {
                    _ = unsafe CPython_SetScope(previous)
                    withExtendedLifetime(scope) {}
                }
                result = try body(scope)
            }
            return result!
        }
    }
}
