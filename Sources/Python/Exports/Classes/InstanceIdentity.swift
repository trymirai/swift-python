//
//  Created by Anton Spivak
//

import Synchronization

final class InstanceIdentity: Sendable {
    private struct State {
        var ownerID: ObjectIdentifier?

        var wrapper: WeakReference?

        var isConstructingWrapper: Bool = false
    }

    private let state: Mutex<State> = .init(State())

    func claim(_ instance: any _PythonClass, in storage: InterpreterStorage) throws {
        guard instance._pythonContext.references === storage.references else {
            throw Reference.wrongInterpreter()
        }
        try state.withLock { state in
            if let ownerID = state.ownerID, ownerID != ObjectIdentifier(instance) {
                throw ExportCatalog
                    .failure("An instance identity cannot be shared by Swift objects.")
            }

            state.ownerID = ObjectIdentifier(instance)
        }
    }

    func beginWrapperConstruction() throws {
        try state.withLock { state in
            guard !state.isConstructingWrapper else {
                throw Exception(
                    name: "RuntimeError",
                    message: "Python wrapper construction is already in progress.",
                )
            }
            state.isConstructingWrapper = true
        }
    }

    func endWrapperConstruction() {
        state.withLock { $0.isConstructingWrapper = false }
    }

    var isConstructingWrapper: Bool {
        state.withLock { $0.isConstructingWrapper }
    }

    var wrapper: WeakReference? {
        state.withLock { $0.wrapper }
    }

    func bind(_ wrapper: WeakReference) {
        state.withLock { $0.wrapper = wrapper }
    }
}
