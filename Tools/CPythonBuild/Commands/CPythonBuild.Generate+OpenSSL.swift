//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Subprocess
import SystemPackage

extension CPythonBuild.Generate {
    static func generateOpenSSL(
        in workspace: borrowing BuildWorkspace,
        jobs: Int,
    ) async throws {
        let package = workspace.packageDirectory
        let output = workspace.outputDirectory

        let source = package.appending("Submodules/openssl")
        let environment = Environment.custom([
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0",
            "SOURCE_DATE_EPOCH": "0",
        ])

        let revision = try await readRevision(at: source, in: workspace, environment: environment)
        workspace.logger.info("Generating OpenSSL \(revision)")

        let graph = try await prepareSourceGraph(
            at: source,
            in: workspace,
            jobs: jobs,
            environment: environment,
        )

        let installed = package.appending("Sources/libopenssl")
        let candidate = output.appending("PackageLayout")

        let paths = try await stageLayout(
            graph,
            at: candidate,
            from: source,
            revision: revision,
            workspace: workspace,
        )
        let exclusions = paths.filter {
            $0.hasSuffix(".inc") || ($0.hasSuffix(".c") && !graph.translationUnits.contains($0))
        }

        let manifest = package.appending("Package.swift")
        let updated = try await updateExclusions(exclusions, in: manifest, workspace: workspace)

        try await publish(
            candidate,
            at: installed,
            manifest: manifest,
            contents: updated,
        )

        workspace.logger
            .info(
                "Updated the layout for \(graph.translationUnits.count) OpenSSL translation units.",
            )
    }

    private static func prepareSourceGraph(
        at source: FilePath,
        in workspace: borrowing BuildWorkspace,
        jobs: Int,
        environment: Environment,
    ) async throws -> SourceGraph {
        let output = workspace.outputDirectory
        // Staging lives two levels below the package. Make requires a relative Configure path
        // when the package directory contains spaces.
        try await workspace.run(
            "perl",
            [
                "../../Submodules/openssl/Configure",
                "linux-generic64",
                "no-asm",
                "no-shared",
                "no-module",
                "no-dso",
                "no-engine",
                "no-async",
                "no-tests",
                "no-apps",
                "--prefix=/",
                "--openssldir=/etc/ssl",
            ],
            in: output,
            stage: "Configure portable 64-bit OpenSSL",
            environment: environment,
        )

        let plan = try await workspace.run(
            "perl",
            ["-I.", "-Mconfigdata", "-e", Self.sourceGraph],
            in: output,
            stage: "Read OpenSSL source graph",
            environment: environment,
            output: .string(limit: 1 << 20),
        )

        var graph = try SourceGraph(plan)

        // This header holds our build description. Configure's version describes its host compiler.
        graph.generated.remove("crypto/buildinf.h")
        try await workspace.run(
            "make",
            ["-s", "-j", String(jobs)] + graph.generated.sorted(),
            in: output,
            stage: "Generate OpenSSL headers and tables",
            environment: environment,
        )

        try await includeFragments(in: &graph, at: source, workspace: workspace)
        return graph
    }

    private static func readRevision(
        at source: FilePath,
        in workspace: borrowing BuildWorkspace,
        environment: Environment,
    ) async throws -> Substring {
        let checkout = try await workspace.run(
            "git",
            ["status", "--porcelain"],
            in: source,
            stage: "Inspect OpenSSL checkout",
            environment: environment,
            output: .string(limit: 1 << 20),
        )
        guard checkout.isEmpty else {
            throw BuildError("Use a clean OpenSSL checkout before generating its sources.")
        }

        let head = try await workspace.run(
            "git",
            ["rev-parse", "HEAD"],
            in: source,
            stage: "Read OpenSSL revision",
            environment: environment,
            output: .string(limit: 1 << 20),
        )
        guard let revision = head.split(whereSeparator: \.isNewline).first else {
            throw BuildError("Missing OpenSSL revision.")
        }
        return revision
    }

    private struct SourceGraph {
        var sourcePrefix: String = ""

        var translationUnits: Set<String> = []
        var links: Set<String> = []
        var generated: Set<String> = []

        init(_ plan: String) throws {
            for line in plan.split(whereSeparator: \.isNewline) {
                try addEntry(line)
            }

            guard
                !sourcePrefix.isEmpty, !translationUnits.isEmpty, !generated.isEmpty,
                links.union(generated)
                    .allSatisfy({ CPythonBuild.Generate.isRelativeSourcePath(FilePath($0)) }),
                links.isDisjoint(with: generated)
            else {
                throw BuildError("Invalid paths in the OpenSSL source graph.")
            }
        }

        private mutating func addEntry(_ line: Substring) throws {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else {
                throw BuildError("Unexpected entry in the OpenSSL source graph.")
            }

            let name = String(fields[1])
            switch fields[0] {
            case "prefix":
                sourcePrefix = name
            case "source":
                translationUnits.insert(name)
                links.insert(name)
            case "generated-source":
                translationUnits.insert(name)
                generated.insert(name)
            case "generated-header":
                generated.insert(name)
            case "header":
                links.insert(name)
            default:
                throw BuildError("Unknown entry in the OpenSSL source graph.")
            }
        }
    }

    private static func includeFragments(
        in graph: inout SourceGraph,
        at source: FilePath,
        workspace: borrowing BuildWorkspace,
    ) async throws {
        let output = workspace.outputDirectory
        // Keep included C fragments beside their callers so SwiftPM compiles each only once.
        var pending = graph.translationUnits.sorted()
        var index = 0
        while index < pending.count {
            let name = pending[index]
            index += 1

            let directory = graph.generated.contains(name) ? output : source
            let text = try await workspace.read(textFrom: directory.appending(name))

            for match in text.matches(of: #/(?m)^[ \t]*#[ \t]*include[ \t]+"([^"\n]+\.c)"/#) {
                let fragment = FilePath(name)
                    .removingLastComponent()
                    .appending(String(match.1))
                    .lexicallyNormalized()

                guard Self.isRelativeSourcePath(fragment) else {
                    throw BuildError("Invalid included C fragment in \(name).")
                }

                let relative = fragment.string
                if
                    !graph.translationUnits.contains(relative),
                    !graph.generated.contains(relative),
                    graph.links.insert(relative).inserted
                {
                    pending.append(relative)
                }
            }
        }
    }

    private static func stageLayout(
        _ graph: SourceGraph,
        at candidate: FilePath,
        from source: FilePath,
        revision: Substring,
        workspace: borrowing BuildWorkspace,
    ) async throws -> [String] {
        let output = workspace.outputDirectory
        let fileSystem = workspace.fileSystem

        let sources = candidate.appending("src")
        let generatedFiles = candidate.appending("Generated")

        func createParent(of path: FilePath) async throws {
            try await fileSystem.createDirectory(
                at: path.removingLastComponent(),
                withIntermediateDirectories: true,
            )
        }

        func linkSource(_ name: String) async throws {
            let link = sources.appending(name)
            let depth = FilePath(name).components.count

            let destination: FilePath
            if graph.generated.contains(name) {
                destination = FilePath(String(repeating: "../", count: depth) + "Generated/" + name)
            } else {
                guard try await fileSystem.info(forFileAt: source.appending(name)) != nil else {
                    throw BuildError("Missing OpenSSL source \(name).")
                }
                destination = FilePath(
                    String(repeating: "../", count: depth + 2) + "Submodules/openssl/" + name,
                )
            }

            try await createParent(of: link)
            try await fileSystem.createSymbolicLink(at: link, withDestination: destination)
        }

        let configuredSource = graph.sourcePrefix + "/"
        let absoluteSource = source.string + "/"

        func copyGeneratedFile(_ name: String) async throws {
            let path = generatedFiles.appending(name)
            let contents = try await workspace.read(textFrom: output.appending(name))
            let normalized = contents
                .replacing(configuredSource, with: "Submodules/openssl/")
                .replacing(absoluteSource, with: "Submodules/openssl/")

            try await createParent(of: path)
            try await workspace.write(normalized, to: path)
        }

        for name in graph.generated.sorted() {
            try await copyGeneratedFile(name)
        }

        // Preserve upstream include paths while storing generated files separately.
        let paths = graph.links.union(graph.generated).sorted()
        for name in paths {
            try await linkSource(name)
        }

        let headers = paths
            .filter { $0.hasPrefix("include/openssl/") && $0.hasSuffix(".h") }

        let moduleMap =
            [
                "// OpenSSL \(revision). Generated by CPythonBuild generate.",
                "module libopenssl {",
            ]
            + headers.map { "    textual header \"\($0.dropFirst("include/".count))\"" }
            + ["    export *", "}", ""]

        try await workspace.write(
            moduleMap.joined(separator: "\n"),
            to: generatedFiles.appending("module.modulemap"),
        )
        return paths
    }

    private static func updateExclusions(
        _ exclusions: [String],
        in manifest: FilePath,
        workspace: borrowing BuildWorkspace,
    ) async throws -> String? {
        let original = try await workspace.read(textFrom: manifest)

        // Keep the LICENSE exclusion in Package.swift when replacing the src/ exclusions.
        let pattern = #/(?m)^[ \t]*name: "libopenssl",\n([ \t]*)exclude: \[\n(?:[ \t]*"(?!src\/)[^"\n]+",\n)*((?:[ \t]*"src\/[^"\n]+",\n|[ \t]*\n)*)[ \t]*\],/#
        guard let list = original.firstMatch(of: pattern) else {
            throw BuildError("Missing the libopenssl exclude list in Package.swift.")
        }

        let entries = list.2
        let previous = entries.matches(of: #/"src\/([^"\n]+)"/#).map { String($0.1) }

        guard previous.sorted() != exclusions else {
            return nil
        }
        let lines = exclusions.map { "\(list.1)    \"src/\($0)\",\n" }.joined()
        return String(original[..<entries.startIndex]) + lines + original[entries.endIndex...]
    }

    private static func isRelativeSourcePath(_ path: FilePath) -> Bool {
        !path.isAbsolute
            && !path.components.isEmpty
            && path.components.allSatisfy { $0.kind == .regular }
    }

    private static let generatedDirectories: [String] = ["Generated", "src"]

    private static func publish(
        _ candidate: FilePath,
        at installed: FilePath,
        manifest: FilePath,
        contents: String?,
    ) async throws {
        let fileSystem = FileSystem.shared
        // A failed restore must leave the backup outside the auto-cleaned staging directory.
        let backup = FilePath(candidate.removingLastComponent().string + "-previous")
        try await fileSystem.createDirectory(at: backup, withIntermediateDirectories: false)

        var saved = [String]()
        var replaced = [String]()

        func moveDirectory(
            _ name: String,
            from source: FilePath,
            to target: FilePath,
        ) async throws {
            try await fileSystem.moveItem(at: source.appending(name), to: target.appending(name))
        }

        do {
            for name in Self.generatedDirectories {
                let path = installed.appending(name)
                if try await fileSystem.info(forFileAt: path, infoAboutSymbolicLink: true) != nil {
                    try await moveDirectory(name, from: installed, to: backup)
                    saved.append(name)
                }
            }

            for name in Self.generatedDirectories {
                try await moveDirectory(name, from: candidate, to: installed)
                replaced.append(name)
            }

            if let contents {
                try await contents.write(
                    toFileAt: manifest,
                    options: .newFile(replaceExisting: true),
                )
            }
        } catch {
            for name in replaced.reversed() {
                try await moveDirectory(name, from: installed, to: candidate)
            }

            for name in saved.reversed() {
                try await moveDirectory(name, from: backup, to: installed)
            }

            try await fileSystem.removeItem(at: backup, strategy: .platformDefault)
            throw error
        }

        try await fileSystem.removeItem(at: backup, strategy: .platformDefault, recursively: true)
    }

    // Configure owns archive membership and generation. Export the paths SwiftPM uses.
    private static let sourceGraph: String = #"""
    use Cwd qw(abs_path);
    use File::Find;
    use File::Spec;
    my $root = abs_path($config{sourcedir});
    print "prefix\t$config{sourcedir}\n";
    my %seen;
    sub visit {
        my ($entry) = @_;
        return if $seen{$entry}++;
        if (my $children = $unified_info{sources}{$entry}) {
            visit($_) for @$children;
        } else {
            die "Unexpected translation unit: $entry" unless $entry =~ /\.c$/;
            if (exists $unified_info{generate}{$entry}) {
                print "generated-source\t$entry\n";
            } else {
                my $path = abs_path($entry) or die "Missing source: $entry";
                print "source\t", File::Spec->abs2rel($path, $root), "\n";
            }
        }
    }
    visit($_) for @{$unified_info{libraries}};
    for my $file (keys %{$unified_info{generate}}) {
        print "generated-header\t$file\n" if $file =~ /\.h$/;
    }
    find({no_chdir => 1, wanted => sub {
        return unless -f $_ && /\.(?:h|inc)$/;
        print "header\t", File::Spec->abs2rel($_, $root), "\n";
    }}, map { "$root/$_" } qw(include crypto ssl providers));
    """#
}
