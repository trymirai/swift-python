//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import SystemPackage

struct ProjectFixture {
    static let projectModule: String = "assistant"

    let root: FilePath
    let runtime: Python::Runtime

    private let builder: Python::Session

    var project: String {
        root.appending("project").string
    }

    var projectStartup: Python::Session.Startup {
        .project(directory: project, module: Self.projectModule)
    }

    var environmentRoot: FilePath {
        root.appending("environment")
    }

    var environment: String {
        environmentRoot.string
    }

    var manifest: FilePath {
        environmentRoot.appending("environment.json")
    }

    // MARK: Session fixtures

    static func withFixture(_ test: @Sendable (Self) async throws -> Void) async throws {
        try await FileSystem.shared.withTemporaryDirectory { _, root in
            let builderRuntime = try await Python::Runtime(
                cacheDirectory: root.appending("fixture-cache").string,
            )
            let builder = try await builderRuntime
                .session(delegate: FileAccessDelegate { $0.path.starts(with: root) })
            try await withSession(builder) { builder in
                try await builder.set(root.string, forKey: "root_path")
                _ = try await builder.evaluate(Self.setup)

                let runtime = try await makeRuntime(at: root, using: builder)
                try await test(Self(root: root, runtime: runtime, builder: builder))
            }
        }
    }

    func withProject(
        environmentDirectory: String? = nil,
        delegate: (any Python::Session.Delegate)? = nil,
        _ test: (Python::Session) async throws -> Void,
    ) async throws {
        let session = try await runtime.session(
            projectStartup,
            environmentDirectory: environmentDirectory ?? environment,
            delegate: delegate,
        )
        try await withSession(session, test)
    }

    // MARK: Package artifacts

    func readManifest() async throws -> [UInt8] {
        try await [UInt8](contentsOf: manifest, maximumSizeAllowed: .unlimited)
    }

    func rebuildRuntime() async throws -> Python::Runtime {
        try await Self.makeRuntime(at: root, using: builder)
    }

    func addDependencyUpdate() async throws {
        _ = try await builder.evaluate(#"wheel('sampledep', '2.0', 'VALUE = 2\n')"#)
    }

    func addSharedPackageWheels() async throws {
        _ = try await builder.evaluate(#"""
        wheel('sharedbase', '2.0', 'VALUE = 22\n')
        wheel('sharedbase', '3.0', 'VALUE = 33\n')
        """#)
    }

    func preparePackageSource(
        _ name: String,
        version: String,
        value: Int,
        archived: Bool = false,
    ) async throws -> Python::Runtime.PackageSource {
        let path = root.appending(name + (archived ? ".zip" : "")).string
        try await builder.set(path, forKey: "source_path")
        try await builder.set(version, forKey: "source_version")
        try await builder.set(value, forKey: "source_value")
        _ = try await builder
            .evaluate("write_base(Path(source_path), source_version, source_value)")
        return archived ? .archive(path) : .directory(path)
    }

    func takeIndexOffline() async throws {
        try await FileSystem.shared.moveItem(
            at: root.appending("simple"),
            to: root.appending("offline"),
        )
    }

    func write(_ source: String, to name: String) async throws -> String {
        let path = root.appending(name)
        try await source.write(toFileAt: path, options: .newFile(replaceExisting: true))
        return path.string
    }

    func fileURL(for name: String) async throws -> String {
        try await Self.fileURL(for: root.appending(name), using: builder)
    }

    static func directoryNames(at path: FilePath) async throws -> Set<FilePath.Component> {
        try await FileSystem.shared.withDirectoryHandle(atPath: path) { handle in
            var names = Set<FilePath.Component>()
            for try await entry in handle.listContents() {
                names.insert(entry.name)
            }
            return names
        }
    }

    private static func fileURL(
        for path: FilePath,
        using builder: Python::Session,
    ) async throws -> String {
        try await builder.enqueue { context in
            let pathlib = try context.import(module: "pathlib")
            let url = try pathlib.attribute("Path").call(path.string).attribute("as_uri").call()
            return try url.decode(as: String.self)
        }
    }

    private static func makeRuntime(
        at root: FilePath,
        using builder: Python::Session,
    ) async throws -> Python::Runtime {
        try await Python::Runtime(
            packages: [.directory(root.appending("global").string)],
            cacheDirectory: root.appending("cache").string,
            packageIndex: fileURL(for: root.appending("simple"), using: builder),
        )
    }

    // MARK: Fixture source

    private static let setup = #"""
    import base64
    import csv
    import hashlib
    import io
    import json
    import zipfile
    from pathlib import Path

    root = Path(root_path)

    def write_record(files, metadata):
        records = io.StringIO()
        writer = csv.writer(records)
        for member, data in files.items():
            digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
            writer.writerow((member, "sha256=" + digest, len(data)))
        writer.writerow((f"{metadata}/RECORD", "", ""))
        files[f"{metadata}/RECORD"] = records.getvalue().encode()

    def index_wheel(name, target):
        index = root / "simple" / name / "index.json"
        index.parent.mkdir(parents=True, exist_ok=True)
        data = {"meta": {"api-version": "1.0"}, "files": []}
        if index.exists():
            data = json.loads(index.read_text())
        data["files"].append({
            "filename": target.name,
            "url": target.as_uri(),
            "hashes": {"sha256": hashlib.sha256(target.read_bytes()).hexdigest()},
        })
        index.write_text(json.dumps(data))

    def write_zip(target, files):
        with zipfile.ZipFile(target, "w") as archive:
            for member, data in files.items():
                archive.writestr(member, data)

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
        write_record(files, metadata)

        target = root / filename
        write_zip(target, files)
        index_wheel(name, target)

    def write_project():
        project = root / "project"
        package = project / "\#(projectModule)"
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

    def write_base(base, version, value, legacy=False):
        metadata = f"sharedbase-{version}.dist-info"
        files = {
            "sharedbase/__init__.py": f"VALUE = {value}\n".encode(),
            f"{metadata}/METADATA": (
                f"Metadata-Version: 2.4\nName: sharedbase\nVersion: {version}\n"
            ).encode(),
        }
        if legacy:
            files["sharedbase_old.py"] = b"VALUE = 17\n"
        write_record(files, metadata)

        if base.suffix == ".zip":
            write_zip(base, files)
            return

        for member, data in files.items():
            file = base / member
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)

    wheel("sampleleaf", "1.0", "VALUE = 1\n")
    wheel("sampledep", "1.0", "from sampleleaf import VALUE\n", ("sampleleaf>=1",))
    wheel("sampleextra", "1.0", "VALUE = 9\n")
    wheel("sampleplugin", "1.0", "VALUE = 10\n", ("sampledep>=1",), path="sampledep/plugin.py")

    write_project()
    write_base(root / "global", "1.0", 17, legacy=True)
    (root / "global" / "unrelated.py").write_text("VALUE = 19\n")
    """#
}
