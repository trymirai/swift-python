//
//  Created by Anton Spivak
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - CPythonBuildPlugin.InputFiles

extension CPythonBuildPlugin {
    // Build-tool plugins cannot import package products such as NIOFileSystem.
    // Visit directories with libc so edits to any upstream input invalidate generation.
    struct InputFiles: ~Copyable {
        let packageDirectory: String

        func collect() throws -> [String] {
            let directories = [
                "Sources/libcpython/Generated/Configuration",
                "Sources/libcpython/Compatibility/Python",

                "Submodules/cpython/Include",
                "Submodules/cpython/Objects",
                "Submodules/cpython/Parser",
                "Submodules/cpython/Python",
                "Submodules/cpython/Modules",
                "Submodules/cpython/Lib",
                "Submodules/cpython/Programs",

                "Submodules/python-packages",
            ]

            // The manifest and tool are tracked by SwiftPM; enumerate the files the build tool reads.
            var inputs = [String]()
            for path in directories {
                try visit(path, into: &inputs)
            }

            inputs.append(contentsOf: [
                "Submodules/cpython/Tools/freeze/flag.py",
                "Submodules/cpython/configure",
                "Submodules/cpython/Makefile.pre.in",
                "Submodules/cpython/config.guess",
                "Submodules/cpython/config.sub",
            ])

            return inputs.sorted()
        }

        private func visit(_ path: String, into inputs: inout [String]) throws {
            inputs.append(path)
            guard let directory = opendir(packageDirectory + "/" + path) else {
                throw MissingInputError(path: path)
            }
            defer {
                closedir(directory)
            }

            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 {
                        throw MissingInputError(path: path)
                    }
                    break
                }

                // dirent belongs to readdir until the next call; decode its name inside that borrow.
                let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
                }

                if Self.excludedNames.contains(name) {
                    continue
                }

                let childPath = path + "/" + name
                switch try fileKind(at: childPath) {
                case mode_t(S_IFDIR):
                    try visit(childPath, into: &inputs)
                case mode_t(S_IFREG):
                    inputs.append(childPath)
                default:
                    break
                }
            }
        }

        private func fileKind(at path: String) throws -> mode_t {
            var attributes = stat()
            guard lstat(packageDirectory + "/" + path, &attributes) == 0 else {
                throw MissingInputError(path: path)
            }
            return attributes.st_mode & mode_t(S_IFMT)
        }
    }
}

private extension CPythonBuildPlugin.InputFiles {
    static let excludedNames: Set<String> = [
        ".",
        "..",
        ".git",

        "__pycache__",
        "test",
        "tests",
        "idlelib",
        "tkinter",
        "turtledemo",
        "ensurepip",
    ]
}
