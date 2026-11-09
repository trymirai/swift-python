//
//  Created by Anton Spivak
//

internal import libcpython

extension Interpreter {
    enum CheckpointOutcome {
        case commit
        case rollback
    }

    borrowing func beginCheckpoint() throws {
        try pThread.withAttached { attachment in
            let storage = attachment.storage
            precondition(storage.checkpoint == .inactive)
            guard CPython_BeginFileCheckpoint() == 0 else {
                throw Runtime.Failure("Unable to checkpoint the file descriptors.")
            }
            guard CPython_BeginCheckpoint() == 0 else {
                CPython_FinishFileCheckpoint(true)
                throw Runtime.Failure("Unable to capture the Python interpreter checkpoint.")
            }
            storage.references.beginCheckpoint()
            storage.classRegistry?.beginCheckpoint()
            storage.checkpoint = .active
        }
    }

    borrowing func finishCheckpoint(_ outcome: CheckpointOutcome) {
        guard pThread.storage.checkpoint == .active else {
            return
        }
        let restoring = outcome == .rollback
        pThread.withAttached(releasingReferences: false) { attachment in
            let storage = attachment.storage
            storage.settleCheckpoint {
                storage.classRegistry?.finishCheckpoint(restoring: restoring)
                CPython_FinishCheckpoint(restoring)
                CPython_FinishFileCheckpoint(restoring)
            }
            storage.references.finishCheckpoint(restoring: restoring)
        }
    }
}
