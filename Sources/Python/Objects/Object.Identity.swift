//
//  Created by Anton Spivak
//

import Synchronization

// MARK: - Object.Identity

public extension Object {
    /// Identity shared by an exported Swift instance and its Python wrapper.
    @_documentation(visibility: internal)
    final class Identity: Sendable {
        private let state: Mutex<State> = .init(State())

        public init?<Instance: AnyObject>(for type: Instance.Type) {
            if let base = _getSuperclass(type), base is any _PClass.Type {
                return nil
            }
        }

        func claim(_ instance: any _PClass, in storage: Interpreter.Storage) throws {
            try state.withLock { try $0.claim(ObjectIdentifier(instance), in: storage.references) }
        }

        func beginWrapperConstruction() throws {
            try state.withLock { try $0.wrapper.beginConstruction() }
        }

        func endWrapperConstruction() {
            state.withLock { $0.wrapper.endConstruction() }
        }

        var wrapper: WeakReference? {
            state.withLock {
                if case let .bound(wrapper) = $0.wrapper {
                    wrapper
                } else {
                    nil
                }
            }
        }

        func bind(_ wrapper: WeakReference) throws {
            try state.withLock { try $0.wrapper.bind(wrapper) }
        }
    }
}

// MARK: - Object.Identity.State

private extension Object.Identity {
    struct State {
        var owner: ObjectIdentifier?
        weak var references: Reference.Store?

        var wrapper: Wrapper = .unbound

        mutating func claim(_ owner: ObjectIdentifier, in references: Reference.Store) throws {
            guard let previous = self.owner else {
                self.owner = owner
                self.references = references
                return
            }

            guard previous == owner else {
                throw Module.Catalog
                    .failure("An instance identity cannot be shared by Swift objects.")
            }
            guard self.references === references else {
                throw Reference.wrongInterpreter()
            }
        }
    }
}

// MARK: - Object.Identity.Wrapper

private extension Object.Identity {
    enum Wrapper {
        case unbound
        case constructing(previous: WeakReference?)
        case bound(WeakReference)

        mutating func beginConstruction() throws {
            switch self {
            case .unbound:
                self = .constructing(previous: nil)
            case let .bound(wrapper):
                self = .constructing(previous: wrapper)
            case .constructing:
                throw Exception(
                    name: "RuntimeError",
                    message: "Python wrapper construction is already in progress.",
                )
            }
        }

        mutating func endConstruction() {
            if case let .constructing(previous) = self {
                self = previous.map(Self.bound) ?? .unbound
            }
        }

        mutating func bind(_ wrapper: WeakReference) throws {
            guard case .constructing = self else {
                throw Module.Catalog.failure("The Swift instance is already initialized.")
            }
            self = .bound(wrapper)
        }
    }
}
