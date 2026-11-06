//
//  Created by Anton Spivak
//

import Subprocess
import SystemPackage

extension StandardLibraryBuilder {
    func buildFreezer() async throws -> FilePath {
        // Host compilation must not inherit SwiftBuild's destination SDK/deployment
        // variables: a Linux/iOS build still needs a runnable host C freezer.
        let hostEnvironment = Environment.custom([
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "PYTHON_FOR_REGEN": "false",
            "PYTHONDONTWRITEBYTECODE": "1",
            "CONFIG_SITE": "/dev/null",
            "CC": "/usr/bin/cc",
            "CXX": "/usr/bin/c++",
            "AR": "/usr/bin/ar",
            "RANLIB": "/usr/bin/ranlib",
            "PKG_CONFIG": "/usr/bin/false",
        ])

        let bootstrap = workspace.outputDirectory.appending("Bootstrap")
        try await workspace.fileSystem.createDirectory(
            at: bootstrap,
            withIntermediateDirectories: true,
        )
        let host = try await hostTarget(in: bootstrap, environment: hostEnvironment)

        if try await configuredHost(in: bootstrap) != host {
            try await configureFreezer(for: host, in: bootstrap, environment: hostEnvironment)
        }

        try await workspace.run(
            "/usr/bin/make",
            [
                "-s",
                "-j\(jobCount)",
                "Programs/_freeze_module",
                "Python/frozen.o",
                "Python/frozen_modules/getpath.h",
            ],
            in: bootstrap,
            stage: "Build host freezer",
            environment: hostEnvironment,
        )

        return bootstrap.appending("Programs/_freeze_module")
    }

    private func configuredHost(in bootstrap: FilePath) async throws -> Substring? {
        let makefile = bootstrap.appending("Makefile")
        guard try await workspace.fileSystem.info(forFileAt: makefile) != nil else {
            return nil
        }

        let configuration = try await workspace.read(textFrom: makefile)
        let hostKey = "HOST_GNU_TYPE="
        return configuration.split(separator: "\n")
            .first { $0.hasPrefix(hostKey) }?
            .dropFirst(hostKey.count)
            .split(whereSeparator: \.isWhitespace)
            .first
    }

    private func hostTarget(
        in bootstrap: FilePath,
        environment: Environment,
    ) async throws -> Substring {
        // A build-tool process can run under Rosetta while its compiler targets arm64.
        let compilerTarget = try await workspace.run(
            "/usr/bin/cc",
            ["-dumpmachine"],
            in: bootstrap,
            stage: "Read host compiler target",
            environment: environment,
            output: .string(limit: 1 << 20),
        )
        guard let triple = compilerTarget.split(whereSeparator: \.isWhitespace).first else {
            throw BuildError("Missing host compiler target.")
        }

        let target = try await workspace.run(
            workspace.sourceDirectory.appending("config.sub"),
            [String(triple)],
            in: bootstrap,
            stage: "Resolve CPython host target",
            environment: environment,
            output: .string(limit: 1 << 20),
        )
        guard let host = target.split(whereSeparator: \.isWhitespace).first else {
            throw BuildError("Missing CPython host target.")
        }
        return host
    }

    private func configureFreezer(
        for host: Substring,
        in bootstrap: FilePath,
        environment: Environment,
    ) async throws {
        workspace.logger.info("Configuring the CPython host freezer")
        let result = try await Subprocess::run(
            .path(.init(workspace.sourceDirectory.appending("configure").string)),
            arguments: [
                "--quiet",
                "--build=\(host)",
                "--host=\(host)",
                "--without-ensurepip",
                "--without-mimalloc",
                "--disable-test-modules",
                "--disable-shared",
                "--with-pkg-config=no",
            ],
            environment: environment,
            workingDirectory: .init(bootstrap.string),
            output: .currentStandardOutput,
            error: .string(limit: 1 << 20),
        )
        guard result.terminationStatus == .exited(0) else {
            throw BuildError(
                "Configure host freezer failed (\(result.terminationStatus)).\n\(result.standardError)",
            )
        }

        // configure probes optional Python modules even when bootstrapping _freeze_module.
        // This step skips pkg-config because SwiftPM selects libraries for the final runtime.
        for line in result.standardError.split(whereSeparator: \.isNewline) {
            switch line {
            case "configure: WARNING: no system libmpdec found; falling back to pure-Python version for the decimal module",
                 "configure: WARNING: pkg-config is missing. Some dependencies may not be detected correctly.":
                workspace.logger.debug("\(line)")
            default:
                workspace.logger.warning("\(line)")
            }
        }
    }
}
