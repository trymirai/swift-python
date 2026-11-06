//
//  Created by Anton Spivak
//

import SystemPackage

extension StandardLibraryBuilder {
    func makeConfigurationModules() async throws -> [(String, String)] {
        let root = workspace.packageDirectory
        let configuration = root.appending("Sources/libcpython/Generated/Configuration")
        let version = try await pythonVersion()

        var result = [(String, String)]()
        for header in try await workspace.entries(configuration) where header.hasSuffix(".h") {
            guard let profile = try Profile(header: header) else {
                continue
            }

            let text = try await workspace.read(textFrom: configuration.appending(header))
            let defines = integerDefines(in: text)
            result.append((
                profile.moduleName,
                Self.moduleSource(for: profile, version: version, defines: defines),
            ))
        }
        return result
    }

    private func pythonVersion() async throws -> String {
        let versionHeader = try await workspace.read(
            textFrom: workspace.sourceDirectory.appending("Include/patchlevel.h"),
        )

        let versionConstants = integerDefines(in: versionHeader)
        guard
            let major = versionConstants["PY_MAJOR_VERSION"],
            let minor = versionConstants["PY_MINOR_VERSION"]
        else {
            throw BuildError("Missing Python version in Include/patchlevel.h")
        }

        return "\(major).\(minor)"
    }

    private struct Profile {
        let family: String
        let platform: String

        let moduleName: String

        init?(header: String) throws {
            let profile = String(header.dropLast(2))
            let parts = profile.split(separator: "-").map(String.init)
            guard parts.count == 2 || (parts.count == 3 && parts[0] == "linux") else {
                return nil
            }

            family = parts[0]
            let architecture = parts[parts.count - 1]
            let abi: String
            switch family {
            case "linux":
                platform = "linux"
                abi = "linux-" + parts[1]
            case "macos":
                platform = "darwin"
                abi = "darwin"
            case "ios":
                platform = "ios"
                abi = "iphoneos"
            case "simulator":
                platform = "ios"
                abi = "iphonesimulator"
            case "catalyst":
                platform = "ios"
                abi = "macabi"
            default:
                throw BuildError("Unsupported configuration profile: \(profile)")
            }

            let cpu = family == "linux" && architecture == "arm64" ? "aarch64" : architecture
            moduleName = "_sysconfigdata__\(platform)_\(cpu)-\(abi)"
        }
    }

    private static func moduleSource(
        for profile: Profile,
        version: String,
        defines: [String: String],
    ) -> String {
        var values = defines
        let strings = [
            "VERSION": version,
            "LDVERSION": version,
            "py_version_short": version,

            "CC": "clang",
            "CXX": "clang++",
            "AR": "ar",
            "RANLIB": "ranlib",
            "CFLAGS": "",
            "LDFLAGS": "",
            "LDSHARED": profile.family == "linux"
                ? "clang -shared"
                : "clang -bundle -undefined dynamic_lookup",

            "LIBRARY": "libcpython.a",
            "LDLIBRARY": "libcpython.a",
            "SHLIB_SUFFIX": ".so",

            "MACOSX_DEPLOYMENT_TARGET": profile.family == "macos" ? "26.4" : "",
            "IPHONEOS_DEPLOYMENT_TARGET": profile.platform == "ios" ? "26.4" : "",
            "srcdir": "",
            "CONFIG_ARGS": "",

            "prefix": "/",
            "exec_prefix": "/",
            "LIBDIR": "/lib",
            "LIBPL": "/lib/python\(version)/config",
            "INCLUDEPY": "/include/python\(version)",
            "PYTHONFRAMEWORK": "",
        ]

        for (key, value) in strings {
            values[key] = value.quotedSourceLiteral
        }
        values["Py_ENABLE_SHARED"] = "0"
        values["Py_DEBUG"] = "0"
        values.removeValue(forKey: "Py_REMOTE_DEBUG")

        let runtime = """
        # ABI and trait-dependent values come from the running interpreter.
        import _imp
        import sys

        _suffix = next(iter(_imp.extension_suffixes()), "")
        build_time_vars = {
            "ABIFLAGS": sys.abiflags,
            "MULTIARCH": sys.implementation._multiarch,
            "SOABI": _suffix.removeprefix(".").removesuffix(".so"),
            "EXT_SUFFIX": _suffix,
            "MACHDEP": sys.platform,
            "Py_REMOTE_DEBUG": int("_remote_debugging" in sys.builtin_module_names),

        """

        return runtime + values.sorted { $0.key < $1.key }
            .map { "    " + $0.key.quotedSourceLiteral + ": " + $0.value + "," }
            .joined(separator: "\n") + "\n}\n"
    }

    private func integerDefines(in header: String) -> [String: String] {
        var values = [String: String]()
        for line in header.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if words.count >= 3, words[0] == "#define", Int(words[2]) != nil {
                values[String(words[1])] = String(words[2])
            }
        }
        return values
    }
}
