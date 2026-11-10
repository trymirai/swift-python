//
//  Created by Anton Spivak
//

internal import libcpython
internal import SystemPackage

extension Interpreter.Storage {
    func withFileAccess<Result: ~Copyable>(
        _ operation: () throws -> Result,
    ) rethrows -> Result {
        guard let fileAccess else {
            return try operation()
        }

        // The thread state owns storage until the hook is cleared.
        let context = unsafe Unmanaged.passUnretained(self).toOpaque()
        unsafe CPython_SetSubprocesses(execution?.subprocesses?.handle)
        unsafe CPython_SetFileAccessCheck({ context, path, mode, options, operation, exists in
            let storage = unsafe Unmanaged<Interpreter.Storage>.fromOpaque(context)
                .takeUnretainedValue()
            let request = Session.FileAccessRequest(
                path: unsafe FilePath(platformString: path),
                operation: .init(operation, mode: mode, options: options),
                exists: exists,
                scope: storage.execution?.scope,
            )
            return storage.authorizeFileAccess(request)
        }, context, fileAccess.descriptors)
        defer {
            CPython_SetFileAccessCheck(nil, nil, nil)
            CPython_SetSubprocesses(nil)
        }
        return try operation()
    }

    private func authorizeFileAccess(_ request: Session.FileAccessRequest) -> Int32 {
        guard let execution, let fileAccess else {
            // Finalizers can run between blocks, outside the user's permission grant.
            return 0
        }
        if fileAccess.permitsRead(request) {
            return 1
        }
        guard let delegate = fileAccess.delegate else {
            return 0
        }

        do {
            let call = try Session.Control.Call({
                try await delegate.shouldAllowFileAccess(request)
            }, sessionID: sessionOrigin)
            let allowed = try execution.waitForFileAccess(call, id: allocateCallID())
            return allowed ? 1 : 0
        } catch {
            if (try? execution.checkInterruption()) == nil {
                _ = execution.deliverInterruption()
                CPython_RaiseKeyboardInterrupt()
            } else {
                Object.raise(error)
            }
            return -1
        }
    }
}

private extension Session.FileAccessRequest.Operation {
    init(_ operation: CPython_FileOperation, mode: Int32, options: Int32) {
        switch operation {
        case CPython_FileMetadata:
            self = .metadata
        case CPython_FileEnumerate:
            self = .enumerate
        case CPython_FileCreateDirectory:
            self = .createDirectory
        case CPython_FileRemove:
            self = .remove
        case CPython_FileRenameSource:
            self = .renameSource
        case CPython_FileRenameDestination:
            self = .renameDestination
        default:
            self = .open(mode: .init(rawValue: mode), options: .init(rawValue: options))
        }
    }
}
