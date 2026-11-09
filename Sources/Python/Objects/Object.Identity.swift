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
            let owner = ObjectIdentifier(instance)
            try state.withLock { state in
                if let previous = state.owner {
                    guard previous == owner else {
                        throw Module.Catalog
                            .failure("An instance identity cannot be shared by Swift objects.")
                    }
                    guard state.references === storage.references else {
                        throw Reference.wrongInterpreter()
                    }
                } else {
                    state.owner = owner
                    state.references = storage.references
                }
            }
        }

        func beginWrapperConstruction() throws {
            try state.withLock { state in
                switch state.wrapper {
                case .unbound:
                    state.wrapper = .constructing(previous: nil)
                case let .bound(wrapper):
                    state.wrapper = .constructing(previous: wrapper)
                case .constructing:
                    throw Exception(
                        name: "RuntimeError",
                        message: "Python wrapper construction is already in progress.",
                    )
                }
            }
        }

        func endWrapperConstruction() {
            state.withLock { state in
                if case let .constructing(previous) = state.wrapper {
                    state.wrapper = previous.map(Wrapper.bound) ?? .unbound
                }
            }
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

        func restoreWrapper(_ wrapper: WeakReference?) {
            state.withLock { $0.wrapper = wrapper.map(Wrapper.bound) ?? .unbound }
        }

        func bind(_ wrapper: WeakReference) throws {
            try state.withLock { state in
                guard case .constructing = state.wrapper else {
                    throw Module.Catalog.failure("The Swift instance is already initialized.")
                }
                state.wrapper = .bound(wrapper)
            }
        }
    }
}

// MARK: - Object.Identity.State

private extension Object.Identity {
    struct State {
        weak var references: Reference.Store?
        
        var owner: ObjectIdentifier?
        var wrapper: Wrapper = .unbound
    }
}

// MARK: - Object.Identity.Wrapper

private extension Object.Identity {
    enum Wrapper {
        case unbound
        case constructing(previous: WeakReference?)
        case bound(WeakReference)
    }
}
