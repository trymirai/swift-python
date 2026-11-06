//
//  Created by Anton Spivak
//

internal import libcpython
internal import SystemPackage

extension Interpreter.Storage {
    func installFileOpenCheck() {
        // The thread state owns storage until the hook is cleared.
        let context = unsafe Unmanaged.passUnretained(self).toOpaque()
        unsafe CPython_SetFileOpenCheck({ context, path, mode, options in
            let storage = unsafe Unmanaged<Interpreter.Storage>.fromOpaque(context)
                .takeUnretainedValue()
            let request = Session.FileOpenRequest(
                path: unsafe FilePath(platformString: path),
                mode: .init(rawValue: mode),
                options: .init(rawValue: options),
            )
            return storage.checkFileOpen(request)
        }, context)
    }

    private func checkFileOpen(_ request: Session.FileOpenRequest) -> Int32 {
        guard let session, let delegate = fileOpenDelegate, let execution else {
            unsafe CPython_RaiseSwiftError(
                "RuntimeError",
                "File access requires an active Python session.",
            )
            return -1
        }

        do {
            let call = try Session.Control.Call({
                try await delegate.session(session, shouldOpenFile: request)
            }, sessionID: sessionOrigin)
            let allowed = try execution.waitForFileOpen(call, id: allocateCallID())
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
