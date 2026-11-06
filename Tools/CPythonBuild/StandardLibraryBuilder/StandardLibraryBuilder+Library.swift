//
//  Created by Anton Spivak
//

import SystemPackage

extension StandardLibraryBuilder {
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

        let adapters = root.appending("Sources/libcpython/Compatibility/Python")
        for path in try await workspace.paths(adapters, omitting: ["__pycache__"])
            where path.hasSuffix(".py")
        {
            resources.append(Resource(path: path, source: adapters.appending(path)))
        }

        let packages = root.appending("Submodules/python-packages")
        for path in try await workspace.paths(packages, omitting: []) where path.hasSuffix(".whl") {
            resources.append(Resource(
                path: "_swift_python_packages/" + path,
                source: packages.appending(path),
            ))
        }

        for (name, body) in try await makeConfigurationModules() {
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
}
