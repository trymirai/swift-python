//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import SystemPackage
import Testing

@Test(.timeLimit(.minutes(1)))
func sharedPreparationKeepsSourcesAndSessionStateIndependent() async throws {
    try await ProjectFixture.withFixture { fixture in
        let resources = try await fixture.prepareResources()
        let cache = try await fixture.runtime.paths
        let packages = try environmentPackagesDirectory(in: resources)

        #expect(resources.paths.directory == fixture.preparations.appending(resources.fingerprint))
        #expect(try await FileSystem.shared
            .info(forFileAt: resources.paths.manifestFile)?
            .type == .regular)
        #expect(try await FileSystem.shared.info(forFileAt: resources.paths.lockFile) == nil)
        #expect(packages.starts(with: cache.environmentsDirectory))

        let first = try await fixture.runtime.session(
            resources,
            module: ProjectFixture.projectModule,
        )
        defer { await first.close() }
        let second = try await fixture.runtime.session(resources)
        defer { await second.close() }

        #expect(await first.paths == nil)
        #expect(await second.paths == nil)

        try await expectStdout("42\n", from: "counter += 1; print(answer())", in: first)
        try await expectAnswer(41, in: second)

        await first.close()

        try await expectAnswer(41, in: second)
        #expect(try await FileSystem.shared.info(forFileAt: packages)?.type == .directory)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func concurrentSharedPreparationsPublishCompleteSources(_ separateRuntimes: Bool) async throws {
    try await ProjectFixture.withFixture { fixture in
        let other = separateRuntimes ? try await fixture.rebuildRuntime() : fixture.runtime
        let results = try await withThrowingTaskGroup(
            of: Python::Runtime.ProjectResources.self,
        ) { group in
            for index in 0 ..< 8 {
                let runtime = index.isMultiple(of: 2) ? fixture.runtime : other
                group.addTask { try await fixture.prepareResources(using: runtime) }
            }

            return try await group.reduce(into: [Python::Runtime.ProjectResources]()) {
                results, resources in
                results.append(resources)
            }
        }

        #expect(Set(results.map(\.fingerprint)).count == 1)
        #expect(Set(results.map(\.paths)).count == 1)
        for resources in results {
            try await withSession(fixture.runtime.session(resources)) { session in
                try await expectAnswer(41, in: session)
            }
        }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func sharedPreparationReopensOfflineAndRepairsEnvironment(
    removeUnpackedWheel: Bool,
) async throws {
    try await ProjectFixture.withFixture { fixture in
        let first = try await fixture.prepareResources()
        let initial = try await FileSystem.shared.info(forFileAt: first.paths.manifestFile)

        try await fixture.takeIndexOffline()
        let runtime = try await fixture.rebuildRuntime()
        let cached = try await fixture.prepareResources(using: runtime)
        let repeated = try await FileSystem.shared.info(forFileAt: cached.paths.manifestFile)

        #expect(first.fingerprint == cached.fingerprint)
        #expect(initial?.lastDataModificationTime == repeated?.lastDataModificationTime)

        let packages = try environmentPackagesDirectory(in: cached)
        try await FileSystem.shared.removeItem(at: packages.removingLastComponent())
        if removeUnpackedWheel {
            let paths = try await runtime.paths
            let digest = try #require(
                try await ProjectFixture.directoryNames(at: paths.wheelsDirectory).first,
            )
            try await FileSystem.shared.removeItem(
                at: paths.wheelPackagesDirectory(digest: digest.string),
            )
        }
        let repaired = try await fixture.prepareResources(using: runtime)

        try await withSession(runtime.session(repaired)) { session in
            try await expectAnswer(41, in: session)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func sharedDependencyUpdatesKeepOlderSourcesUsable() async throws {
    try await ProjectFixture.withFixture { fixture in
        let old = try await fixture.prepareResources()
        let first = try await fixture.runtime.session(old)
        defer { await first.close() }
        _ = try await first.evaluate("pass")

        try await fixture.addDependencyUpdate()
        let kept = try await fixture.prepareResources()
        #expect(kept.fingerprint == old.fingerprint)

        let updated = try await fixture.prepareResources(update: true)
        try await withSession(fixture.runtime.session(updated)) { session in
            try await expectAnswer(42, in: session)
            try await first.reset()
            try await expectAnswer(41, in: first)
        }

        try await fixture.write("sampleextra==1\n", to: "project/requirements.txt")
        let changed = try await fixture.prepareResources()
        #expect(changed.fingerprint != old.fingerprint)

        try await withSession(fixture.runtime.session(packages: changed.sources)) { session in
            try await expectStdout(
                "9\n",
                from: "import sampleextra; print(sampleextra.VALUE)",
                in: session,
            )
        }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func sharedPreparationKeepsProjectSourcePrecedence(_ explicit: Bool) async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.prepareProjectVirtualEnvironment()
        let sources: [Python::Runtime.PackageSource] = if explicit {
            [try await fixture.preparePackageSource("explicit", version: "4.0", value: 47)]
        } else {
            []
        }
        let resources = try await fixture.prepareResources(packages: sources)

        try await withSession(fixture.runtime.session(resources)) { session in
            try await expectStdout(
                explicit ? "47\n" : "27\n",
                from: "import sharedbase; print(sharedbase.VALUE)",
                in: session,
            )
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func sharedPreparationMergesWheelsExtendingOnePythonPackage() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.write("sampledep>=1\nsampleplugin==1\n", to: "project/requirements.txt")
        let resources = try await fixture.prepareResources()

        try await withSession(fixture.runtime.session(resources)) { session in
            try await expectStdout(
                "10\n",
                from: "import sampledep.plugin; print(sampledep.plugin.VALUE)",
                in: session,
            )
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func mutableSessionPackagesDoNotChangeSharedPreparation() async throws {
    try await ProjectFixture.withFixture { fixture in
        let resources = try await fixture.prepareResources()
        let original = try await fixture.readManifest(at: resources.paths.manifestFile)
        let session = try await fixture.runtime.session(
            resources,
            environmentDirectory: fixture.environment,
        )
        defer { await session.close() }

        #expect(try await session.packages.install(requirements: ["sampleextra"]) == .applied)

        let paths = try #require(await session.paths)
        #expect(paths.directory == fixture.environmentRoot)
        #expect(try await FileSystem.shared.info(forFileAt: paths.manifestFile)?.type == .regular)
        #expect(try await FileSystem.shared.info(forFileAt: paths.lockFile)?.type == .regular)
        #expect(try await FileSystem.shared
            .info(forFileAt: paths.packagesDirectory(for: .a))?
            .type == .directory)

        try await expectStdout(
            "9\n",
            from: "import sampleextra; print(sampleextra.VALUE)",
            in: session,
        )
        try await withSession(fixture.runtime.session(resources)) { other in
            try await expectStdout(
                "None\n",
                from: "import importlib.util; print(importlib.util.find_spec('sampleextra'))",
                in: other,
            )
            #expect(try await fixture.readManifest(at: resources.paths.manifestFile) == original)
        }
    }
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func cancelledSharedPreparationLeavesPublishedSourcesUnchanged() async throws {
    try await ProjectFixture.withFixture { fixture in
        let initial = try await fixture.prepareResources()
        let manifest = initial.paths.manifestFile
        let bytes = try await fixture.readManifest(at: manifest)

        let task = Task { @MainActor in try await fixture.prepareResources(update: true) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await fixture.readManifest(at: manifest) == bytes)
    }
}

@Test(.timeLimit(.minutes(1)))
func failedSharedUpdateKeepsPublishedSources() async throws {
    try await ProjectFixture.withFixture { fixture in
        let resources = try await fixture.prepareResources()
        let manifest = resources.paths.manifestFile
        let bytes = try await fixture.readManifest(at: manifest)

        try await fixture.takeIndexOffline()
        await #expect(throws: (any Swift::Error).self) {
            try await fixture.prepareResources(update: true)
        }
        #expect(try await fixture.readManifest(at: manifest) == bytes)

        let cached = try await fixture.prepareResources()
        try await withSession(fixture.runtime.session(cached)) { session in
            try await expectAnswer(41, in: session)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func sharedPackageCollisionsDoNotPublishIncompleteSources() async throws {
    try await ProjectFixture.withFixture { fixture in
        let resources = try await fixture.prepareResources()
        let manifest = resources.paths.manifestFile
        let bytes = try await fixture.readManifest(at: manifest)

        try await fixture.addConflictingDependency()
        try await fixture.write("sampledep>=1\nsampleconflict==1\n", to: "project/requirements.txt")
        let error = try await #require(throws: (any Swift::Error).self) {
            try await fixture.prepareResources()
        }
        #expect(String(describing: error).lowercased().contains("collision"))
        #expect(try await fixture.readManifest(at: manifest) == bytes)

        try await fixture.write("sampledep>=1\n", to: "project/requirements.txt")
        let cached = try await fixture.prepareResources()
        #expect(cached.fingerprint == resources.fingerprint)
    }
}

@Test(.timeLimit(.minutes(1)))
func sharedEnvironmentsReuseWheelUnpacks() async throws {
    try await ProjectFixture.withFixture { fixture in
        let original = try await fixture.prepareResources()
        let paths = try await fixture.runtime.paths
        let digests = try await ProjectFixture.directoryNames(at: paths.wheelsDirectory)
        #expect(digests.count == 2)
        var dependency: FilePath?
        for digest in digests {
            let directory = paths.wheelDirectory(digest: digest.string)
            let entries = try await ProjectFixture.directoryNames(at: directory)
            let archives = entries.filter { $0.string.hasSuffix(".whl") }
            let archive = try #require(archives.first)
            #expect(archives.count == 1)
            let expected: Set<String> = if archive.string.hasPrefix("sampledep-") {
                [archive.string, "site-packages", "data"]
            } else {
                [archive.string, "site-packages"]
            }
            #expect(Set(entries.map(\.string)) == expected)
            let packages = paths.wheelPackagesDirectory(digest: digest.string)
            #expect(try await FileSystem.shared.info(forFileAt: packages)?.type == .directory)
            if archive.string.hasPrefix("sampledep-") {
                dependency = packages.appending("sampledep/__init__.py")
                let data = try await [UInt8](
                    contentsOf: directory.appending("data/share/sampledep.txt"),
                    maximumSizeAllowed: .unlimited,
                )
                #expect(data == Array("embedded asset".utf8))
            }
        }
        let cachedFile = try #require(dependency)
        #expect(try await FileSystem.shared
            .info(forFileAt: paths.cacheDirectory.appending("installed")) == nil)
        #expect(try await FileSystem.shared
            .info(forFileAt: paths.cacheDirectory.appending("prepared")) == nil)

        let delegate = FileAccessDelegate { $0.path.starts(with: fixture.root) }
        let first = try await fixture.runtime.session(original, delegate: delegate)
        defer { await first.close() }
        try await first.set(cachedFile.string, forKey: "cached_file")
        _ = try await first.evaluate("""
        from pathlib import Path
        assert Path(sampledep.__file__).samefile(cached_file)
        assert not Path(sampledep.__file__).is_symlink()
        """)

        try await fixture.write(
            "sampledep>=1\nsampleextra==1\n",
            to: "project/requirements.txt",
        )
        let expanded = try await fixture.prepareResources()
        let originalPackages = try environmentPackagesDirectory(in: original)
        let expandedPackages = try environmentPackagesDirectory(in: expanded)
        #expect(originalPackages != expandedPackages)

        let second = try await fixture.runtime.session(expanded, delegate: delegate)
        defer { await second.close() }
        try await second.set(cachedFile.string, forKey: "cached_file")
        try await second.set(
            originalPackages.appending("sampledep/__init__.py").string,
            forKey: "original_file",
        )
        _ = try await second.evaluate("""
        from pathlib import Path
        assert Path(sampledep.__file__).samefile(cached_file)
        assert Path(sampledep.__file__).samefile(original_file)
        assert not Path(sampledep.__file__).is_symlink()
        """)
    }
}

@Test(.timeLimit(.minutes(1)))
func packageCacheClearsWheelArtifactsAndSharedEnvironments() async throws {
    try await ProjectFixture.withFixture { fixture in
        let resources = try await fixture.prepareResources()
        let manifest = try await fixture.readManifest(at: resources.paths.manifestFile)
        let paths = try await fixture.runtime.paths
        let files = FileSystem.shared
        let wheelStaging = paths.wheelStagingDirectory(
            digest: String(repeating: "a", count: 64),
            identifier: "abcdefgh",
        )
        let environmentStaging = paths.environmentStagingDirectory(
            identifier: String(repeating: "b", count: 32),
        )
        for directory in [wheelStaging, environmentStaging] {
            try await files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for directory in [paths.wheelsDirectory, paths.environmentsDirectory] {
            try await "keep".write(toFileAt: directory.appending("keep.txt"))
        }

        try await Python::Runtime.clearPackageCache(at: paths.cacheDirectory.string)
        #expect(try await ProjectFixture.directoryNames(at: paths.wheelsDirectory) == ["keep.txt"])
        #expect(try await ProjectFixture
            .directoryNames(at: paths.environmentsDirectory) == ["keep.txt"])
        #expect(try await fixture.readManifest(at: resources.paths.manifestFile) == manifest)
    }
}

private extension ProjectFixture {
    var preparations: FilePath {
        root.appending("shared")
    }

    func prepareResources(
        using runtime: Python::Runtime? = nil,
        packages: [Python::Runtime.PackageSource] = [],
        update: Bool = false,
    ) async throws -> Python::Runtime.ProjectResources {
        try await (runtime ?? self.runtime).prepare(
            project: project,
            in: preparations.string,
            packages: packages,
            update: update,
        )
    }
}

private func environmentPackagesDirectory(
    in resources: Python::Runtime.ProjectResources,
    sourceLocation: SourceLocation = #_sourceLocation,
) throws -> FilePath {
    let directory: FilePath? = if case let .directory(path)? = resources.sources.first {
        FilePath(path)
    } else {
        nil
    }
    return try #require(directory, sourceLocation: sourceLocation)
}

private func expectAnswer(
    _ value: Int,
    in session: Python::Session,
    sourceLocation: SourceLocation = #_sourceLocation,
) async throws {
    try await expectStdout(
        "\(value)\n",
        from: "print(answer())",
        in: session,
        sourceLocation: sourceLocation,
    )
}

private func expectStdout(
    _ expected: String,
    from source: String,
    in session: Python::Session,
    sourceLocation: SourceLocation = #_sourceLocation,
) async throws {
    let execution = try await session.evaluate(source)
    #expect(execution.output.stdout == expected, sourceLocation: sourceLocation)
}
