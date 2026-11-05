//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Foundation
import Python
import SystemPackage

struct ProjectFixture {
    let root: FilePath
    let runtime: Python::Runtime
    private let builder: Python::Session

    var project: String {
        root.appending("project").string
    }

    var environment: String {
        root.appending("environment").string
    }

    static func withFixture(_ test: @Sendable (Self) async throws -> Void) async throws {
        try await FileSystem.shared.withTemporaryDirectory { _, root in
            let builderRuntime = try await Python::Runtime(
                cacheDirectory: root.appending("fixture-cache").string,
            )
            let builder = try await builderRuntime.session()
            do {
                try await builder.set("root_path", to: root.string)
                _ = try await builder.evaluate(Self.setup)
                let runtime = try await Python::Runtime(
                    packages: [.directory(root.appending("global").string)],
                    cacheDirectory: root.appending("cache").string,
                    packageIndex: URL(
                        fileURLWithPath: root.appending("simple").string,
                        isDirectory: true,
                    ).absoluteString,
                )
                try await test(Self(root: root, runtime: runtime, builder: builder))
            } catch {
                await builder.close()
                throw error
            }
            await builder.close()
        }
    }

    func withProject(
        moduleDefinitions: [Python::Module] = [],
        _ test: (Python::Session) async throws -> Void,
    ) async throws {
        let session = try await runtime.session(
            .project(directory: project, module: "assistant"),
            environmentDirectory: environment,
            moduleDefinitions: moduleDefinitions,
        )
        do {
            try await test(session)
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }

    func addDependencyUpdate() async throws {
        _ = try await builder.evaluate(#"wheel('sampledep', '2.0', 'VALUE = 2\n')"#)
    }

    func takeIndexOffline() throws {
        try FileManager.default.moveItem(
            atPath: root.appending("simple").string,
            toPath: root.appending("offline").string,
        )
    }

    func write(_ source: String, to name: String) throws -> String {
        let path = root.appending(name).string
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private static let setup = #"""
    import base64
    import csv
    import hashlib
    import io
    import json
    import zipfile
    from pathlib import Path

    root = Path(root_path)

    def wheel(name, version, source, requires=(), path=None):
        filename = f"{name}-{version}-py3-none-any.whl"
        metadata = f"{name}-{version}.dist-info"
        files = {
            path or f"{name}/__init__.py": source.encode(),
            f"{metadata}/METADATA": (
                f"Metadata-Version: 2.4\nName: {name}\nVersion: {version}\n"
                + "".join(f"Requires-Dist: {requirement}\n" for requirement in requires)
            ).encode(),
            f"{metadata}/WHEEL": (
                b"Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n"
            ),
        }
        records = io.StringIO()
        writer = csv.writer(records)
        for member, data in files.items():
            digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
            writer.writerow((member, "sha256=" + digest, len(data)))
        writer.writerow((f"{metadata}/RECORD", "", ""))
        files[f"{metadata}/RECORD"] = records.getvalue().encode()

        target = root / filename
        with zipfile.ZipFile(target, "w") as archive:
            for member, data in files.items():
                archive.writestr(member, data)

        index = root / "simple" / name / "index.json"
        index.parent.mkdir(parents=True, exist_ok=True)
        data = {"meta": {"api-version": "1.0"}, "files": []}
        if index.exists():
            data = json.loads(index.read_text())
        data["files"].append({
            "filename": filename,
            "url": target.as_uri(),
            "hashes": {"sha256": hashlib.sha256(target.read_bytes()).hexdigest()},
        })
        index.write_text(json.dumps(data))

    wheel("sampleleaf", "1.0", "VALUE = 1\n")
    wheel("sampledep", "1.0", "from sampleleaf import VALUE\n", ("sampleleaf>=1",))
    wheel("sampleextra", "1.0", "VALUE = 9\n")
    wheel("sampleplugin", "1.0", "VALUE = 10\n", ("sampledep>=1",), path="sampledep/plugin.py")

    project = root / "project"
    package = project / "assistant"
    package.mkdir(parents=True)
    (project / "pyproject.toml").write_text(
        '[project]\nname = "test-assistant"\nversion = "1.0"\ndependencies = ["sampledep>=1"]\n'
    )
    (package / "__init__.py").write_text(
        'import sampledep\nfrom .helpers import plus\ncounter = 40\n'
        'def answer():\n    return plus(counter, sampledep.VALUE)\nprint("ready")\n'
    )
    (package / "helpers.py").write_text('def plus(left, right):\n    return left + right\n')
    (package / "message.txt").write_text("embedded resource")

    base = root / "global"
    (base / "sharedbase").mkdir(parents=True)
    (base / "sharedbase/__init__.py").write_text("VALUE = 17\n")
    (base / "sharedbase-1.0.dist-info").mkdir()
    (base / "sharedbase-1.0.dist-info/METADATA").write_text(
        "Metadata-Version: 2.4\nName: sharedbase\nVersion: 1.0\n"
    )
    """#
}
