//
//  Created by Anton Spivak
//

internal import libcpython
internal import SystemPackage

extension Interpreter {
    // Owned by the interpreter and used on its executor.
    @safe
    final class FileAccess {
        let descriptors: OpaquePointer
        let delegate: (any Session.Delegate)?

        private let packageRoots: [FilePath]
        private var importRoots: [FilePath]

        init(
            importPaths: [String],
            packages: [Runtime.PackageSource.Resolved],
            delegate: (any Session.Delegate)?,
        ) throws {
            self.delegate = delegate
            self.importRoots = Self.resolve(importPaths.lazy.map { FilePath($0) })
            let packagePaths = packages.lazy.compactMap { package -> FilePath? in
                switch package {
                case let .directory(path), let .archive(path):
                    path.file
                case .embedded:
                    nil
                }
            }
            self.packageRoots = Self.resolve(packagePaths)

            guard let descriptors = unsafe CPython_NewFiles() else {
                throw Runtime.Failure("Unable to allocate the Python file descriptor registry.")
            }
            unsafe self.descriptors = descriptors
        }

        deinit {
            unsafe CPython_FreeFiles(descriptors)
        }

        func replaceImportPaths(_ paths: [String]) {
            importRoots = Self.resolve(paths.lazy.map { FilePath($0) })
        }

        func permitsRead(_ request: Session.FileAccessRequest) -> Bool {
            switch request.operation {
            case let .open(mode, options):
                guard
                    mode == .readOnly,
                    options.intersection([.create, .truncate, .append]).isEmpty
                else {
                    return false
                }
            case .metadata, .enumerate:
                break
            case .createDirectory, .remove, .renameSource, .renameDestination:
                return false
            }
            return importRoots.contains { request.path.starts(with: $0) }
                || packageRoots.contains { request.path.starts(with: $0) }
        }

        private static func resolve(_ paths: some Sequence<FilePath>) -> [FilePath] {
            paths.compactMap { path in try? FileTarget(path).path }
        }
    }
}
