//
//  Created by Anton Spivak
//

import SystemPackage

extension Build {
    func collectLibrary() async throws -> Library {
        let root = workspace.packageDirectory
        let source = workspace.sourceDirectory
        let output = workspace.outputDirectory

        let omitted: Set<String> = [
            "test",
            "tests",
            "__pycache__",
            "idlelib",
            "tkinter",
            "turtledemo",
            "ensurepip",
        ]

        let library = source.appending("Lib")
        let paths = try await workspace.paths(library, omitting: omitted).filter { path in
            ![".pyc", ".pyo", ".so", ".dll", ".exe", ".pyd", ".DS_Store"]
                .contains { path.hasSuffix($0) }
        }

        var resources = paths.map { Resource(path: $0, source: library.appending($0)) }
        resources.append(Resource(
            path: "_swift_python_importer.py",
            source: root.appending("Sources/libcpython/Compatibility/Importer.py"),
        ))

        for (name, body) in try await configurationModules() {
            let filename = name + ".py"
            let path = output.appending(filename)
            try await workspace.write(body, to: path)
            resources.append(Resource(path: filename, source: path))
        }

        // The C lookup uses strcmp, so catalogs must follow byte order rather than Unicode collation.
        resources.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        let modules = resources.compactMap(Module.init(resource:))
            .sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }

        return Library(modules: modules, resources: resources)
    }

    struct Library {
        let modules: [Module]
        let resources: [Resource]
    }

    struct Module {
        let name: String

        let path: String
        let source: FilePath

        let isPackage: Bool

        init?(resource: Resource) {
            guard resource.path.hasSuffix(".py") else {
                return nil
            }

            path = resource.path
            source = resource.source

            isPackage = path.hasSuffix("/__init__.py")

            let suffix = isPackage ? "/__init__.py" : ".py"
            name = String(path.dropLast(suffix.count)).replacing("/", with: ".")
        }

        var symbol: String {
            "_Py_M__" + name.replacing(".", with: "_").replacing("-", with: "_")
        }
    }

    struct Resource {
        let path: String
        let source: FilePath
    }
}
