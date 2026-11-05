//
//  Created by Anton Spivak
//

import Foundation
import Python
import Synchronization
import Testing

@Test
func projectEnvironmentRequiresAnExclusiveLease() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.withProject { _ in
            let error = try await #require(throws: Python::Exception.self) {
                try await fixture.runtime.session(environmentDirectory: fixture.environment)
            }
            #expect(error.message.contains("already in use"))

            await #expect(throws: CocoaError.self) {
                try await fixture.runtime.session(
                    environmentDirectory: fixture.root.appending("project/pyproject.toml").string,
                )
            }
        }
    }
}

@Test
func projectUpdatesRequireResetForLoadedDependencies() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.withProject { session in
            #expect(await session.startupOutput?.stdout == "ready\n")
            #expect(try await session.evaluate("counter = 41; answer()").stdout == "42\n")
            _ = try await session.evaluate("""
            import os
            assert os.stat(sampledep.__file__).st_nlink >= 2
            """)
            #expect(try await session.installedPackages() == [
                "sampledep": "1.0",
                "sampleleaf": "1.0",
                "sharedbase": "1.0",
            ])

            // The loaded module keeps its original path after an unrelated install.
            try await session.install(requirements: ["sampleextra"])
            try await fixture.addDependencyUpdate()
            await #expect {
                try await session.updatePackages()
            } throws: { error in
                guard case let .resetRequired(modules)? = error as? Python::SessionError else {
                    return false
                }
                return modules.contains("sampledep")
            }
            #expect(try await session.installedPackages()["sampledep"] == "1.0")
            #expect(try await session.evaluate("answer()").stdout == "42\n")

            try await session.reset()
            try await session.updatePackages()
            #expect(try await session.installedPackages()["sampledep"] == "2.0")
            #expect(try await session.evaluate("answer()").stdout == "42\n")

            await #expect(throws: Python::Exception.self) {
                try await session.install(requirements: ["sharedbase>=2"])
            }
            #expect(try await session.installedPackages()["sampledep"] == "2.0")

            try await session.uninstall(packages: ["sampleextra"])
            #expect(try await session.installedPackages()["sampleextra"] == nil)
        }
    }
}

@Test
func installingASubmoduleRequiresResetForItsLoadedParent() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.addDependencyUpdate()
        try await fixture.withProject { session in
            // The parent remains imported from the generation before this install.
            try await session.install(requirements: ["sampleextra"])
            await #expect {
                try await session.install(requirements: ["sampleplugin"])
            } throws: { error in
                guard case let .resetRequired(modules)? = error as? Python::SessionError else {
                    return false
                }
                return modules.contains("sampledep")
            }
            #expect(try await session.installedPackages()["sampleplugin"] == nil)

            try await session.reset()
            try await session.install(requirements: ["sampleplugin"])
            let output = try await session.evaluate("""
            import sampledep.plugin
            sampledep.plugin.VALUE
            """)
            #expect(output.stdout == "10\n")
        }
    }
}

// MARK: - PublicationFailure

private enum PublicationFailure: CaseIterable {
    case invalidationError
    case stopped

    var action: String {
        switch self {
        case .invalidationError:
            "raise ValueError('invalidation failed')"
        case .stopped:
            "environment_test.stop()"
        }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: PublicationFailure.allCases)
private func packagePublicationRollsBack(_ failure: PublicationFailure) async throws {
    try await ProjectFixture.withFixture { fixture in
        let stopTarget = Mutex<Python::Session?>(nil)
        defer { stopTarget.withLock { $0 = nil } }
        let stop = Python::Module.Function("stop", synchronous: { _ in
            _ = stopTarget.withLock { $0 }?.stop()
            return .none
        })
        let controls = Python::Module("environment_test", functions: [stop])

        try await fixture.withProject(moduleDefinitions: [controls]) { session in
            stopTarget.withLock { $0 = session }
            let files = FileManager.default
            let current = fixture.environment + "/current"
            let generations = fixture.environment + "/generations"
            let previous = try files.destinationOfSymbolicLink(atPath: current)
            let previousGenerations = try Set(files.contentsOfDirectory(atPath: generations))
            let installed = try await session.installedPackages()

            _ = try await session.evaluate("""
            import environment_test, sys

            class Finder:
                def find_spec(self, fullname, path=None, target=None):
                    return None

                def invalidate_caches(self):
                    \(failure.action)

            finder = Finder()
            sys.meta_path.append(finder)
            """)

            switch failure {
            case .invalidationError:
                let error = try await #require(throws: Python::Exception.self) {
                    try await session.install(requirements: ["sampleextra"])
                }
                #expect(error.message.contains("invalidation failed"))
            case .stopped:
                await #expect {
                    try await session.install(requirements: ["sampleextra"])
                } throws: { error in
                    if case .stopped? = error as? Python::ExecutionError {
                        return true
                    }
                    return false
                }
            }

            #expect(try await session.installedPackages() == installed)
            #expect(try files.destinationOfSymbolicLink(atPath: current) == previous)
            #expect(try Set(files.contentsOfDirectory(atPath: generations)) == previousGenerations)
            _ = try await session.evaluate("sys.meta_path.remove(finder)")
            #expect(try await session.evaluate("answer()").stdout == "41\n")
        }
    }
}

@Test
func savedProjectEnvironmentReopensOffline() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.addDependencyUpdate()
        try await fixture.withProject { session in
            let installed = try await session.installedPackages()
            #expect(installed["sampledep"] == "2.0")
        }

        _ = try fixture.write(
            "# Project requirements\nsampledep>=1\n",
            to: "project/requirements.txt",
        )
        _ = try fixture.write("""
        [project]
        name = "test-assistant"
        version = "1.0"
        dependencies = ["sampledep>=99"]
        """, to: "project/pyproject.toml")
        try fixture.takeIndexOffline()

        try await fixture.withProject { session in
            try await session.resolvePackages()
            #expect(try await session.evaluate("answer()").stdout == "42\n")
        }
    }
}

@Test
func projectBundleLoadsFromEmbeddedBytesAndDisk() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.addDependencyUpdate()
        let archive = fixture.root.appending("packages.zip").string
        try await fixture.runtime.bundle(project: fixture.project, module: "assistant", to: archive)

        let bytes = try Array(Data(contentsOf: URL(fileURLWithPath: archive)))
        let sources: [Python::PackageSource] = [.embedded(bytes), .archive(archive)]
        for source in sources {
            let runtime = try await Python::Runtime(
                packages: [.directory(fixture.root.appending("global").string), source],
                cacheDirectory: fixture.root.appending("bundle-cache").string,
                packageIndex: URL(
                    fileURLWithPath: fixture.root.appending("missing-index").string,
                    isDirectory: true,
                ).absoluteString,
            )
            let session = try await runtime.session(.module("assistant"))
            let output = try await session.evaluate("""
            import inspect, pkgutil
            from importlib.metadata import version, files as distribution_files, packages_distributions
            from importlib.resources import as_file, files

            assert version("sampledep") == "2.0"
            assert "sampledep" in packages_distributions()
            assert any(str(path).endswith("__init__.py") for path in distribution_files("sampledep"))
            assert "def answer" in inspect.getsource(answer)
            assert "helpers" in {name for _, name, _ in pkgutil.iter_modules(__path__)}
            with as_file(files("assistant").joinpath("message.txt")) as resource:
                assert resource.read_text() == "embedded resource"
            answer()
            """)
            #expect(output.stdout == "42\n")
            await session.close()
        }
    }
}
