//
//  Created by Anton Spivak
//

import SystemPackage

extension StandardLibraryBuilder {
    func collectLibrary() async throws -> Library {
        var resources = try await standardLibraryResources()
        try await appendRuntimeResources(to: &resources)
        try await appendConfigurationResources(to: &resources)

        resources.sort { Self.precedesInCatalog($0.path, $1.path) }

        var modules = resources.compactMap(Module.init(resource:))
        modules.sort { Self.precedesInCatalog($0.name, $1.name) }

        return Library(modules: modules, resources: resources)
    }

    // The C catalog searches with strcmp, so compare UTF-8 bytes.
    private static func precedesInCatalog(_ left: String, _ right: String) -> Bool {
        left.utf8.lexicographicallyPrecedes(right.utf8)
    }

    private func standardLibraryResources() async throws -> [Resource] {
        let omitted: Set<String> = [
            "test",
            "tests",
            "__pycache__",
            "idlelib",
            "tkinter",
            "turtledemo",
            "ensurepip",
        ]

        let excludedSuffixes = [".pyc", ".pyo", ".so", ".dll", ".exe", ".pyd", ".DS_Store"]
        let library = workspace.sourceDirectory.appending("Lib")
        let paths = try await workspace.paths(library, omitting: omitted)

        return paths.compactMap { path in
            guard !excludedSuffixes.contains(where: path.hasSuffix) else {
                return nil
            }
            let directory = path == "subprocess.py" ? workspace.outputDirectory : library
            return Resource(path: path, source: directory.appending(path))
        }
    }

    private func appendRuntimeResources(to resources: inout [Resource]) async throws {
        let root = workspace.packageDirectory
        let adapters = root.appending("Sources/libcpython/Compatibility/Python")
        let adapterPaths = try await workspace.paths(adapters, omitting: ["__pycache__"])
        for path in adapterPaths where path.hasSuffix(".py") {
            resources.append(Resource(path: path, source: adapters.appending(path)))
        }

        let packages = root.appending("Submodules/python-packages")
        for path in try await workspace.paths(packages, omitting: []) where path.hasSuffix(".whl") {
            resources.append(Resource(
                path: "_swift_python_packages/" + path,
                source: packages.appending(path),
            ))
        }
    }

    private func appendConfigurationResources(to resources: inout [Resource]) async throws {
        for (name, body) in try await makeConfigurationModules() {
            let filename = name + ".py"
            let path = workspace.outputDirectory.appending(filename)
            try await workspace.write(body, to: path)
            resources.append(Resource(path: filename, source: path))
        }
    }
}
