//
//  Created by Anton Spivak
//

internal import _NIOFileSystem
import Synchronization
internal import SystemPackage

// MARK: - Session.History.Store

extension Session.History {
    // The input index lives outside the checkpointed Python heap.
    final class Store: Sendable {
        let configuration: Session.History

        private let state: Mutex<State> = .init(State())

        init(_ configuration: Session.History) throws {
            try configuration.inputs.validate()
            try configuration.outputs.validate()
            self.configuration = configuration
        }

        func reserveNumber() throws -> Int {
            try state.withLock { try $0.reserveNumber() }
        }

        func save(_ source: String, number: Int, destination: Runtime.Path?) async throws {
            let input: Input
            if let destination {
                try await source.write(
                    toFileAt: destination.file,
                    options: .newFile(replaceExisting: false, permissions: .ownerReadWrite),
                )
                input = .file(destination.file)
            } else {
                input = .memory(source)
            }

            let expired = state.withLock { state in
                state.insert(input, number: number, limit: configuration.inputs.limit)
            }
            for file in expired {
                try await FileSystem.shared.removeItem(at: file)
            }
        }

        func close() {
            state.withLock { state in
                state.isClosed = true
                state.inputs.removeAll()
            }
        }

        private func read(_ number: Int) throws -> String {
            let input = try state.withLock { state in
                guard !state.isClosed else {
                    throw Session.Error.closed
                }
                guard let input = state.inputs[number] else {
                    throw Exception(name: "KeyError", message: String(number))
                }
                return input
            }

            let file: FilePath
            switch input {
            case let .memory(source):
                return source
            case let .file(path):
                file = path
            }
            let descriptor = try FileDescriptor.open(
                file,
                .readOnly,
                options: [.closeOnExec, .noFollow],
            )
            defer { try? descriptor.close() }

            return try String(decoding: descriptor.readAllBytes(), as: UTF8.self)
        }
    }
}

// MARK: - Session.History.Store.State

private extension Session.History.Store {
    enum Input: Sendable {
        case memory(String)
        case file(FilePath)

        var filePath: FilePath? {
            if case let .file(path) = self {
                path
            } else {
                nil
            }
        }
    }

    struct State {
        var number: Int = 0
        var inputs: [Int: Input] = [:]

        var isClosed: Bool = false

        mutating func reserveNumber() throws -> Int {
            guard !isClosed else {
                throw Session.Error.closed
            }
            guard number < Int.max else {
                throw Runtime.Failure("The session exhausted its history numbers.")
            }
            number += 1
            return number
        }

        mutating func insert(_ input: Input, number: Int, limit: Int) -> [FilePath] {
            inputs[number] = input
            guard limit > 0, inputs.count > limit else {
                return []
            }

            let expired = inputs.keys.sorted().prefix(inputs.count - limit)
            let files = expired.compactMap { inputs.removeValue(forKey: $0)?.filePath }
            let retained = Set(inputs.values.compactMap(\.filePath))
            return files.filter { !retained.contains($0) }
        }
    }
}

// MARK: - Session.History.Store + Object.Callable

extension Session.History.Store: Object.Callable {
    @_lifetime(borrow attachment)
    func call(
        _ arguments: borrowing Object,
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        switch try arguments.item(at: 0).string() {
        case "count":
            return try Object(encoding: state.withLock { $0.inputs.count }, in: attachment)
        case "keys":
            return try Object(encoding: state.withLock { $0.inputs.keys.sorted() }, in: attachment)
        case "get":
            return try Object(
                encoding: read(arguments.item(at: 1).decode(as: Int.self)),
                in: attachment,
            )
        default:
            throw Exception(name: "ValueError", message: "Unknown input history command.")
        }
    }
}
