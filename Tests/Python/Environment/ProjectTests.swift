//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import SystemPackage
import Testing

@Test
func projectStartupSelectsOnlyProjectModules() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let project = root.appending("project")
        let files = FileSystem.shared
        try await files.createDirectory(
            at: project.appending("_without_initializer"),
            withIntermediateDirectories: true,
        )
        try await "pass".write(toFileAt: project.appending("a.py"))
        try await "raise AssertionError('loaded outside the project')"
            .write(toFileAt: root.appending("outside.py"))

        let runtime = try await Python::Runtime(cacheDirectory: root.appending("cache").string)
        let empty = try await runtime.session(.project(directory: project.string))
        try await withSession(empty) { session in
            let error = try await #require(throws: Python::ExecutionError.self) {
                try await session.initialize()
            }
            #expect(error.traceback.contains("ModuleNotFoundError: No startup package"))
        }

        for name in ["zeta", "0-invalid", "alpha"] {
            let package = project.appending(name)
            try await files.createDirectory(at: package, withIntermediateDirectories: false)
            try await "pass".write(toFileAt: package.appending("__init__.py"))
        }
        try await "pass".write(toFileAt: project.appending("zeta/entry.py"))
        let sources = project.appending("src")
        try await files.createDirectory(at: sources, withIntermediateDirectories: false)
        try await "pass".write(toFileAt: sources.appending("reporting.py"))

        let selections: [(module: String?, name: String)] = [
            (nil, "alpha"),
            ("zeta", "zeta"),
            ("zeta.entry", "zeta.entry"),
            ("a", "a"),
            ("reporting", "reporting"),
        ]
        for (module, name) in selections {
            let session = try await runtime.session(
                .project(directory: project.string, module: module),
                importPaths: [sources.string],
            )
            try await withSession(session) { session in
                let loaded = try await session.get("__name__", as: String.self)
                #expect(loaded == name)
            }
        }

        for module in ["missing", "alpha.missing", "outside", "sys"] {
            let session = try await runtime.session(
                .project(directory: project.string, module: module),
                importPaths: [root.string],
            )
            try await withSession(session) { session in
                let error = try await #require(throws: Python::ExecutionError.self) {
                    try await session.initialize()
                }
                #expect(error.traceback.contains("ModuleNotFoundError: Startup module '\(module)'"))
            }
        }
    }
}

@Test
func projectPreparesPackagesBeforeStartupAndKeepsModuleGlobals() async throws {
    try await ProjectFixture.withFixture { fixture in
        _ = try await fixture.write("""
        import sampleextra
        from .helpers import plus

        base = 23
        counter = 1

        def answer():
            return plus(base, counter) + sampleextra.VALUE

        print("project")
        """, to: "project/assistant/__init__.py")

        try await fixture.withProject { session in
            #expect(await session.startupOutput == nil)
            #expect(try await session.packages.installed()["sampledep"] == "1.0")
            #expect(try await session.packages.install(requirements: ["sampleextra"]) == .applied)
            #expect(await session.startupOutput == nil)

            let first = try await session.evaluate("counter = 10; answer()")
            #expect(first.output.stdout == "42\n")
            #expect(await session.startupOutput?.stdout == "project\n")

            try await session.reset()
            #expect(await session.startupOutput == nil)
            let restarted = try await session.evaluate("answer()")
            #expect(restarted.output.stdout == "33\n")
            #expect(await session.startupOutput?.stdout == "project\n")
        }
    }
}

@Test
func projectEnvironmentRequiresAnExclusiveLease() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.withProject { _ in
            let error = try await #require(throws: Python::Exception.self) {
                try await fixture.runtime.session(environmentDirectory: fixture.environment)
            }
            #expect(error.message.contains("already in use"))

            let invalidDirectory = try await #require(throws: FileSystemError.self) {
                try await fixture.runtime.session(
                    environmentDirectory: fixture.root.appending("project/pyproject.toml").string,
                )
            }
            #expect(invalidDirectory.code == .invalidArgument)
        }
    }
}

@Test
func environmentClaimsItsSlotsBeforeReapingStaging() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let runtime = try await Python::Runtime(cacheDirectory: root.appending("cache").string)
        let environment = root.appending("environment")
        let slot = environment.appending("site-packages-a")
        let marker = slot.appending("keep.txt")
        let files = FileSystem.shared

        try await files.createDirectory(at: slot, withIntermediateDirectories: true)
        try await "user data".write(toFileAt: marker)

        for _ in 0 ..< 2 {
            await #expect(throws: Python::Exception.self) {
                try await runtime.session(environmentDirectory: environment.string)
            }
            #expect(try await String(contentsOf: marker, maximumSizeAllowed: .unlimited) ==
                "user data")
        }

        try await files.removeItem(at: slot)
        let session = try await runtime.session(environmentDirectory: environment.string)
        await session.close()
        try await files.createDirectory(at: slot, withIntermediateDirectories: false)

        let reopened = try await runtime.session(environmentDirectory: environment.string)
        await reopened.close()
        #expect(try await ProjectFixture.directoryNames(at: environment) == ["environment.lock"])
    }
}

@Test
func packageChangesRequireResetAndPublishOneSlot() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.withProject { session in
            let root = fixture.environmentRoot
            let cache = fixture.root.appending("cache/installed")
            let alternateSlot = root.appending("site-packages-b")
            let files = FileSystem.shared
            let packages = session.packages

            let installed = try await packages.installed()
            let unpacked = try await ProjectFixture.directoryNames(at: cache)
            #expect(installed == ["sampledep": "1.0", "sampleleaf": "1.0", "sharedbase": "1.0"])
            #expect(try await session.evaluate("counter = 41; answer()").output.stdout == "42\n")
            let previous = try await fixture.readManifest()

            #expect(try await packages.install(requirements: ["sampleextra"]) == .requiresReset)
            try await fixture.addDependencyUpdate()
            #expect(try await packages.update() == .requiresReset)
            #expect(try await ProjectFixture.directoryNames(at: cache) == unpacked)
            #expect(try await packages.installed() == installed)
            #expect(try await fixture.readManifest() == previous)
            #expect(try await files.info(forFileAt: alternateSlot) == nil)
            #expect(try await session.evaluate("answer()").output.stdout == "42\n")

            try await session.reset()
            #expect(try await packages.update() == .applied)
            #expect(try await packages.install(requirements: ["sampleextra"]) == .applied)
            #expect(try await packages.installed()["sampledep"] == "2.0")
            #expect(try await session.evaluate("answer()").output.stdout == "42\n")
            #expect(try await packages.uninstall(["sampleextra"]) == .requiresReset)

            await #expect(throws: Python::Exception.self) {
                try await packages.install(requirements: ["sharedbase>=2"])
            }

            try await session.reset()
            #expect(try await packages.uninstall(["sampleextra"]) == .applied)
            #expect(try await packages.installed()["sampleextra"] == nil)
            #expect(try await ProjectFixture.directoryNames(at: root) == [
                "environment.json",
                "environment.lock",
                "site-packages-b",
            ])
        }
    }
}

@Test
func failedPackagePublicationKeepsThePreviousSlot() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.withProject { session in
            let root = fixture.environmentRoot
            let blockedWrite = root.appending(".environment.json.tmp")
            let files = FileSystem.shared
            let previous = try await fixture.readManifest()
            let installed = try await session.packages.installed()

            try await session.reset()
            try await files.createDirectory(at: blockedWrite, withIntermediateDirectories: false)
            await #expect(throws: FileSystemError.self) {
                try await session.packages.install(requirements: ["sampleextra"])
            }

            #expect(try await session.packages.installed() == installed)
            #expect(try await fixture.readManifest() == previous)
            #expect(try await files.info(forFileAt: root.appending("site-packages-b")) == nil)
            #expect(try await session.evaluate("answer()").output.stdout == "41\n")
        }
    }
}

@Test
func savedProjectEnvironmentReopensOffline() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.addDependencyUpdate()
        try await fixture.withProject { session in
            let installed = try await session.packages.installed()
            #expect(installed["sampledep"] == "2.0")
            try await session.reset()
            #expect(try await session.packages.install(requirements: ["sampleextra"]) == .applied)
        }

        _ = try await fixture.write(
            "# Project requirements\nsampledep>=1\n",
            to: "project/requirements.txt",
        )
        _ = try await fixture.write("""
        [project]
        name = "test-assistant"
        version = "1.0"
        dependencies = ["sampledep>=99"]
        """, to: "project/pyproject.toml")
        let cache = fixture.root.appending("cache")
        let userFile = cache.appending("wheels/keep.txt")
        try await "keep".write(toFileAt: userFile)
        try await Python::Runtime.clearPackageCache(at: cache.string)
        #expect(try await ProjectFixture
            .directoryNames(at: cache.appending("wheels")) == ["keep.txt"])
        #expect(try await ProjectFixture.directoryNames(at: cache.appending("installed")).isEmpty)
        try await fixture.takeIndexOffline()

        try await fixture.withProject { session in
            let change = try await session.packages.resolve()
            #expect(change == .applied)
            let answer = try await session.evaluate("answer()")
            #expect(answer.output.stdout == "42\n")
            let extra = try await session.evaluate("import sampleextra; print(sampleextra.VALUE)")
            #expect(extra.output.stdout == "9\n")
        }
    }
}

@Test
func reusedEnvironmentChecksCollisionsWithChangedBasePackages() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.withProject { _ in }
        let files = FileSystem.shared
        try await files.createDirectory(
            at: fixture.root.appending("global/overlap-1.0.dist-info"),
            withIntermediateDirectories: false,
        )
        _ = try await fixture.write(
            "Metadata-Version: 2.4\nName: overlap\nVersion: 1.0\n",
            to: "global/overlap-1.0.dist-info/METADATA",
        )
        _ = try await fixture.write(
            "sampledep/__init__.py,,\n",
            to: "global/overlap-1.0.dist-info/RECORD",
        )
        try await files.createDirectory(
            at: fixture.root.appending("global/sampledep"),
            withIntermediateDirectories: false,
        )
        _ = try await fixture.write("VALUE = 0\n", to: "global/sampledep/__init__.py")

        let runtime = try await fixture.rebuildRuntime()
        let error = try await #require(throws: Python::Exception.self) {
            try await runtime.session(
                fixture.projectStartup,
                environmentDirectory: fixture.environment,
            )
        }
        #expect(error.message.contains("conflicts with the application base"))
    }
}

@Test
func movingARequirementToLocalInstallPreservesItAcrossReopen() async throws {
    try await ProjectFixture.withFixture { fixture in
        let root = fixture.environmentRoot
        try await fixture.withProject { session in
            _ = try await fixture.write("""
            [project]
            name = "test-assistant"
            version = "1.0"
            dependencies = []
            """, to: "project/pyproject.toml")
            #expect(try await session.packages.install(requirements: ["sampledep>=1"]) == .applied)
            #expect(try await ProjectFixture.directoryNames(at: root) == [
                "environment.json",
                "environment.lock",
                "site-packages-a",
            ])
        }
        try await fixture.takeIndexOffline()
        try await fixture.withProject { session in
            let installed = try await session.packages.installed()
            #expect(installed["sampledep"] == "1.0")
        }
    }
}

@Test
func invalidSavedManifestKeepsCurrentSlot() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.withProject { _ in }

        let files = FileSystem.shared
        let root = fixture.environmentRoot
        let manifest = fixture.manifest
        let contents = try await fixture.readManifest()
        let replace = OpenOptions.Write.newFile(replaceExisting: true)

        var invalidWheel = String(decoding: contents, as: UTF8.self)
        let digest = try #require(invalidWheel.firstRange(of: #""digest":""#))
        invalidWheel.insert(contentsOf: "../", at: digest.upperBound)
        for invalid in ["{", invalidWheel] {
            try await invalid.write(toFileAt: manifest, options: replace)
            await #expect(throws: Python::Exception.self) {
                try await fixture.withProject { _ in }
            }
            #expect(try await files.info(forFileAt: root.appending("site-packages-a"))?
                .type == .directory)
            #expect(try await files.info(forFileAt: manifest)?.type == .regular)
        }

        try await contents.write(toFileAt: manifest, options: replace)
        try await fixture.withProject { session in
            let output = try await session.evaluate("answer()").output
            #expect(output.stdout == "41\n")
        }
    }
}

@Test
func projectBundleLoadsFromEmbeddedBytesAndDisk() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.addDependencyUpdate()
        let archive = fixture.root.appending("packages.zip")

        func buildArchive() async throws {
            try await fixture.runtime.bundle(
                project: fixture.project,
                module: ProjectFixture.projectModule,
                to: archive.string,
            )
        }

        try await buildArchive()
        let initial = try await FileSystem.shared.info(forFileAt: archive)
        try await buildArchive()
        let repeated = try await FileSystem.shared.info(forFileAt: archive)
        #expect(initial?.lastDataModificationTime == repeated?.lastDataModificationTime)

        let bytes = try await [UInt8](contentsOf: archive, maximumSizeAllowed: .unlimited)
        let resources = fixture.root.appending("resources")
        try await FileSystem.shared.createDirectory(
            at: resources,
            withIntermediateDirectories: false,
        )

        let cache = fixture.root.appending("bundle-cache")
        let packageIndex = try await fixture.fileURL(for: "missing-index")
        let application = Python::Runtime.PackageSource
            .directory(fixture.root.appending("global").string)
        let delegate = FileAccessDelegate { $0.path.starts(with: resources) }
        let sources: [Python::Runtime.PackageSource] = [.embedded(bytes), .archive(archive.string)]
        for source in sources {
            let runtime = try await Python::Runtime(
                packages: [application, source],
                cacheDirectory: cache.string,
                packageIndex: packageIndex,
            )
            let session = try await runtime.session(
                .module(ProjectFixture.projectModule),
                delegate: delegate,
            )
            try await withSession(session) { session in
                try await session.set(resources.string, forKey: "resources_directory")
                try await checkBundledProject(in: session)
            }

            #expect(try await FileSystem.shared.info(forFileAt: cache) == nil)
        }
    }
}

private func checkBundledProject(in session: Python::Session) async throws {
    let execution = try await session.evaluate("""
    import inspect, pkgutil, tempfile
    from importlib.metadata import version, files as distribution_files, packages_distributions
    from importlib.resources import as_file, files

    assert version("sampledep") == "2.0"
    assert "sampledep" in packages_distributions()
    assert any(str(path).endswith("__init__.py") for path in distribution_files("sampledep"))
    assert "def answer" in inspect.getsource(answer)
    assert "helpers" in {name for _, name, _ in pkgutil.iter_modules(__path__)}
    tempfile.tempdir = resources_directory
    with as_file(files("\(ProjectFixture.projectModule)").joinpath("message.txt")) as resource:
        assert resource.read_text() == "embedded resource"
    answer()
    """)
    #expect(execution.output.stdout == "42\n")
}
