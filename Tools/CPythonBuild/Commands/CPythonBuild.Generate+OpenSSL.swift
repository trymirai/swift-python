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
        let fileSystem = workspace.fileSystem
        let environment = Environment.custom([
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0",
            "SOURCE_DATE_EPOCH": "0",
        ])

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

        workspace.logger.info("Generating OpenSSL \(revision)")
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

        var translationUnits = Set<String>()
        var links = Set<String>()

        var generated = Set<String>()
        var sourcePrefix = ""
        for line in plan.split(whereSeparator: \.isNewline) {
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

        guard
            !sourcePrefix.isEmpty, !translationUnits.isEmpty, !generated.isEmpty,
            links.union(generated).allSatisfy({ Self.isRelativeSourcePath(FilePath($0)) }),
            links.isDisjoint(with: generated)
        else {
            throw BuildError("Invalid paths in the OpenSSL source graph.")
        }

        // This header holds our build description. Configure's version describes its host compiler.
        generated.remove("crypto/buildinf.h")
        try await workspace.run(
            "make",
            ["-s", "-j", String(jobs)] + generated.sorted(),
            in: output,
            stage: "Generate OpenSSL headers and tables",
            environment: environment,
        )

        // Included C fragments stay next to their callers without becoming separate translation units.
        var pending = translationUnits.sorted()
        var index = 0
        while index < pending.count {
            let name = pending[index]
            index += 1

            let directory = generated.contains(name) ? output : source
            let text = try await workspace.read(textFrom: directory.appending(name))

            for match in text.matches(of: #/(?m)^[ \t]*#[ \t]*include[ \t]+"([^"\n]+\.c)"/#) {
                let fragment = FilePath(name)
                    .removingLastComponent()
                    .appending(String(match.1))
                    .lexicallyNormalized()

                guard Self.isRelativeSourcePath(fragment) else {
                    throw BuildError("Invalid included C fragment in \(name).")
                }

                if
                    !translationUnits.contains(fragment.string),
                    !generated.contains(fragment.string),
                    links.insert(fragment.string).inserted
                {
                    pending.append(fragment.string)
                }
            }
        }

        let installed = package.appending("Sources/libopenssl")
        let candidate = output.appending("PackageLayout")

        let sources = candidate.appending("src")
        let generatedFiles = candidate.appending("Generated")

        for name in generated.sorted() {
            let path = generatedFiles.appending(name)
            let contents = try await workspace.read(textFrom: output.appending(name))
            let normalized = contents
                .replacing(sourcePrefix + "/", with: "Submodules/openssl/")
                .replacing(source.string + "/", with: "Submodules/openssl/")

            try await fileSystem.createDirectory(
                at: path.removingLastComponent(),
                withIntermediateDirectories: true,
            )

            try await workspace.write(normalized, to: path)
        }

        // Preserve upstream include paths while storing generated files separately.
        let paths = links.union(generated).sorted()
        for name in paths {
            let link = sources.appending(name)
            let depth = FilePath(name).components.count

            let destination: FilePath
            if generated.contains(name) {
                destination = FilePath(String(repeating: "../", count: depth) + "Generated/" + name)
            } else {
                guard try await fileSystem.info(forFileAt: source.appending(name)) != nil else {
                    throw BuildError("Missing OpenSSL source \(name).")
                }
                destination = FilePath(
                    String(repeating: "../", count: depth + 2) + "Submodules/openssl/" + name,
                )
            }

            try await fileSystem.createDirectory(
                at: link.removingLastComponent(),
                withIntermediateDirectories: true,
            )

            try await fileSystem.createSymbolicLink(at: link, withDestination: destination)
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

        let exclusions = paths.filter {
            $0.hasSuffix(".inc") || ($0.hasSuffix(".c") && !translationUnits.contains($0))
        }

        let manifest = package.appending("Package.swift")
        let original = try await workspace.read(textFrom: manifest)

        // Keep the LICENSE exclusion in Package.swift when replacing the src/ exclusions.
        let pattern = #/(?m)^[ \t]*name: "libopenssl",\n([ \t]*)exclude: \[\n(?:[ \t]*"(?!src\/)[^"\n]+",\n)*((?:[ \t]*"src\/[^"\n]+",\n|[ \t]*\n)*)[ \t]*\],/#
        guard let list = original.firstMatch(of: pattern) else {
            throw BuildError("Missing the libopenssl exclude list in Package.swift.")
        }

        let entries = list.2
        let previous = entries.matches(of: #/"src\/([^"\n]+)"/#).map { String($0.1) }

        let updated: String?
        if previous.sorted() == exclusions {
            updated = nil
        } else {
            let lines = exclusions.map { "\(list.1)    \"src/\($0)\",\n" }.joined()
            updated = String(original[..<entries.startIndex]) + lines +
                original[entries.endIndex...]
        }

        try await publish(
            candidate,
            at: installed,
            manifest: manifest,
            contents: updated,
        )

        workspace.logger
            .info("Updated the layout for \(translationUnits.count) OpenSSL translation units.")
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

        do {
            for name in Self.generatedDirectories {
                let path = installed.appending(name)
                if try await fileSystem.info(forFileAt: path, infoAboutSymbolicLink: true) != nil {
                    try await fileSystem.moveItem(at: path, to: backup.appending(name))
                    saved.append(name)
                }
            }

            for name in Self.generatedDirectories {
                try await fileSystem.moveItem(
                    at: candidate.appending(name),
                    to: installed.appending(name),
                )
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
                try await fileSystem.moveItem(
                    at: installed.appending(name),
                    to: candidate.appending(name),
                )
            }

            for name in saved.reversed() {
                try await fileSystem.moveItem(
                    at: backup.appending(name),
                    to: installed.appending(name),
                )
            }

            try await fileSystem.removeItem(at: backup, strategy: .platformDefault)
            throw error
        }

        try await fileSystem.removeItem(at: backup, strategy: .platformDefault, recursively: true)
    }

    // Configure owns the archive membership and generated-file rules. Export only the paths SwiftPM uses.
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
