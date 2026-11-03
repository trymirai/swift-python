// swift-tools-version: 6.4;(experimentalCGen)

import PackageDescription

let package = Package(
    name: "swift-python",
    platforms: [
        .macOS("26.4"),
        .iOS("26.4"),
        .macCatalyst("26.4"),
    ],
    products: [
        .library(name: "Python", type: .static, targets: ["Python"]),
    ],
    traits: [
        .default(enabledTraits: [
            "OpenSSL",
            "libmpdec",
            "liblzma",
            "Zstandard",
            "libedit",
        ]),

        .trait(
            name: "OpenSSL",
            description: "Build the pinned OpenSSL sources.",
        ),

        .trait(
            name: "libffi",
            description: "Build the pinned libffi sources.",
        ),

        .trait(
            name: "libmpdec",
            description: "Build the pinned libmpdec sources.",
        ),

        .trait(
            name: "liblzma",
            description: "Build the pinned liblzma sources.",
        ),

        .trait(
            name: "Zstandard",
            description: "Build the pinned Zstandard sources.",
        ),

        .trait(
            name: "SQLite",
            description: "Build the pinned SQLite sources.",
        ),

        .trait(
            name: "libedit",
            description: "Build the pinned libedit and ncurses sources on Linux.",
        ),

        .trait(
            name: "RemoteDebugging",
            description: "Enable remote debugging on macOS and Linux.",
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-log", from: "1.15.1"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-system", from: "1.8.1"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", exact: "1.0.0", traits: []),
    ],
    targets: [
        // Plugins

        .plugin(
            name: "CPythonBuildPlugin",
            capability: .buildTool(),
            dependencies: [
                .byName(name: "CPythonBuild"),
            ],
        ),

        // Libraries

        .target(
            name: "Python",
            dependencies: [
                .byName(name: "libcpython"),
            ],
            swiftSettings: .default,
        ),
        .testTarget(
            name: "PythonTests",
            dependencies: [
                .byName(name: "libpythontestsupport"),
            ],
            swiftSettings: .default,
        ),

        .target(
            name: "_libcpython",
            dependencies: [
                // SwiftBuild flattens these edges without inheriting the parent platform filter.
                .byName(
                    name: "libffi",
                    condition: .when(platforms: [.iOS, .linux]),
                ),

                .byName(
                    name: "libsqlite",
                    condition: .when(platforms: [.linux]),
                ),
            ],
            publicHeadersPath: ".",
        ),

        .target(
            name: "libcpython",
            dependencies: [
                // SwiftBuild resolves explicit providers before traversing the fallbacks.
                .byName(
                    name: "_libcpython",
                    condition: .when(
                        platforms: [.iOS, .linux],
                        traits: ["default"],
                    ),
                ),

                .byName(
                    name: "libedit",
                    condition: .when(
                        platforms: [.linux],
                        traits: ["libedit"],
                    ),
                ),

                .byName(
                    name: "libffi",
                    condition: .when(traits: ["libffi"]),
                ),

                .byName(
                    name: "liblzma",
                    condition: .when(traits: ["liblzma"]),
                ),

                .byName(
                    name: "libmpdec",
                    condition: .when(traits: ["libmpdec"]),
                ),

                .byName(
                    name: "libncurses",
                    condition: .when(
                        platforms: [.linux],
                        traits: ["libedit"],
                    ),
                ),

                .byName(
                    name: "libopenssl",
                    condition: .when(traits: ["OpenSSL"]),
                ),

                .byName(
                    name: "libsqlite",
                    condition: .when(traits: ["SQLite"]),
                ),

                .byName(
                    name: "libzstd",
                    condition: .when(traits: ["Zstandard"]),
                ),
            ],
            path: "Sources/libcpython",
            exclude: [
                "LICENSE",
                "LICENSE.CPython-Incorporated.rst",
                "LICENSE.Expat",
                "LICENSE.HACL",

                "Compatibility/Importer.py",
                "Compatibility/module.modulemap",

                "src/Modules/cjkcodecs/README",
                "src/Modules/main.c",
                "src/Modules/_ctypes/_ctypes_test.c",
                "src/Modules/_ctypes/malloc_closure.c",
                "src/Modules/_io/winconsoleio.c",

                "src/Python/README",
                "src/Python/frozen_modules",
                "src/Python/slots.toml",
                "src/Python/tier2_engine.md",
                "src/Python/vm-state.md",
                "src/Python/asm_trampoline_aarch64.S",
                "src/Python/asm_trampoline_riscv64.S",
                "src/Python/asm_trampoline_x86_64.S",
                "src/Python/dynload_shlib.c",
                "src/Python/frozen.c",
                "src/Python/getplatform.c",
                "src/Python/sysmodule.c",
                "src/Python/bytecodes.c",
                "src/Python/dup2.c",
                "src/Python/dynload_hpux.c",
                "src/Python/dynload_stub.c",
                "src/Python/dynload_win.c",
                "src/Python/emscripten_signal.c",
                "src/Python/emscripten_syscalls.c",
                "src/Python/optimizer_bytecodes.c",
                "src/Python/wasm_trampoline.c",

                "src/Objects/README",
                "src/Objects/dictnotes.txt",
                "src/Objects/listsort.txt",
                "src/Objects/object_layout.md",
                "src/Objects/object_layout_312.gv",
                "src/Objects/object_layout_312.png",
                "src/Objects/object_layout_313.gv",
                "src/Objects/object_layout_313.png",
                "src/Objects/object_layout_full_312.gv",
                "src/Objects/object_layout_full_312.png",
                "src/Objects/object_layout_full_313.gv",
                "src/Objects/object_layout_full_313.png",
                "src/Objects/stringlib",
                "src/Objects/mimalloc",

                "src/Parser/Python.asdl",
                "src/Parser/asdl.py",
                "src/Parser/asdl_c.py",

            ],
            sources: [
                "Compatibility",
                // A file named main.c would make SwiftPM classify libcpython as an executable.
                "src/interpreter.c",
                "src/Objects",
                "src/Parser",
                "src/Python",

                "src/Modules/_ctypes",
                "src/Modules/_io",
                "src/Modules/_sqlite",
                "src/Modules/_zstd",
                "src/Modules/cjkcodecs",
            ] + [
                "_abc.c",
                "_asynciomodule.c",
                "_bisectmodule.c",
                "_bz2module.c",
                "_codecsmodule.c",
                "_collectionsmodule.c",
                "_csv.c",
                "_datetimemodule.c",
                "_decimal/_decimal.c",
                "_elementtree.c",
                "_functoolsmodule.c",
                "_hacl/Hacl_HMAC.c",
                "_hacl/Hacl_Hash_Blake2b.c",
                "_hacl/Hacl_Hash_Blake2s.c",
                "_hacl/Hacl_Hash_MD5.c",
                "_hacl/Hacl_Hash_SHA1.c",
                "_hacl/Hacl_Hash_SHA2.c",
                "_hacl/Hacl_Hash_SHA3.c",
                "_hacl/Hacl_Streaming_HMAC.c",
                "_hacl/Lib_Memzero0.c",
                "_hashopenssl.c",
                "_heapqmodule.c",
                "_interpchannelsmodule.c",
                "_interpqueuesmodule.c",
                "_interpretersmodule.c",
                "_json.c",
                "_localemodule.c",
                "_lsprof.c",
                "_lzmamodule.c",
                "_opcode.c",
                "_operator.c",
                "_pickle.c",
                "_queuemodule.c",
                "_randommodule.c",
                "_sre/sre.c",
                "_stat.c",
                "_statisticsmodule.c",
                "_struct.c",
                "_suggestions.c",
                "_sysconfig.c",
                "_threadmodule.c",
                "_tracemalloc.c",
                "_typesmodule.c",
                "_typingmodule.c",
                "_weakref.c",
                "_zoneinfo.c",
                "arraymodule.c",
                "atexitmodule.c",
                "binascii.c",
                "blake2module.c",
                "cmathmodule.c",
                "errnomodule.c",
                "expat/xmlparse.c",
                "expat/xmlrole.c",
                "expat/xmltok.c",
                "faulthandler.c",
                "fcntlmodule.c",
                "gcmodule.c",
                "getbuildinfo.c",
                "grpmodule.c",
                "hmacmodule.c",
                "itertoolsmodule.c",
                "mathintegermodule.c",
                "mathmodule.c",
                "md5module.c",
                "mmapmodule.c",
                "pwdmodule.c",
                "pyexpat.c",
                "resource.c",
                "rotatingtree.c",
                "selectmodule.c",
                "sha1module.c",
                "sha2module.c",
                "sha3module.c",
                "signalmodule.c",
                "symtablemodule.c",
                "syslogmodule.c",
                "termios.c",
                "timemodule.c",
                "unicodedata.c",
                "zlibmodule.c",
            ].map { "src/Modules/\($0)" },
            publicHeadersPath: "include",
            cSettings: [
                .disableWarning(
                    "shorten-64-to-32",
                    .when(platforms: [.macOS, .iOS, .macCatalyst]),
                ),

                .headerSearchPath("Compatibility"),

                .headerSearchPath("include/internal"),

                .headerSearchPath("src/Modules"),
                .headerSearchPath("src/Modules/_hacl"),
                .headerSearchPath("src/Modules/_hacl/include"),
                .headerSearchPath("src/Modules/expat"),

                .define(
                    "SWIFT_PYTHON_BUNDLED_OPENSSL",
                    .when(traits: ["OpenSSL"]),
                ),

                .define(
                    "SWIFT_PYTHON_BUNDLED_FFI",
                    .when(traits: ["libffi"]),
                ),

                .define(
                    "SWIFT_PYTHON_BUNDLED_MPDECIMAL",
                    .when(traits: ["libmpdec"]),
                ),

                .define(
                    "SWIFT_PYTHON_BUNDLED_LZMA",
                    .when(traits: ["liblzma"]),
                ),
                .define(
                    "SWIFT_PYTHON_BUNDLED_ZSTANDARD",
                    .when(traits: ["Zstandard"]),
                ),

                .define(
                    "SWIFT_PYTHON_BUNDLED_SQLITE",
                    .when(traits: ["SQLite"]),
                ),

                .define(
                    "SWIFT_PYTHON_BUNDLED_READLINE",
                    .when(traits: ["libedit"]),
                ),

                .define(
                    "SWIFT_PYTHON_DESKTOP_MODULES",
                    .when(platforms: [.macOS, .linux]),
                ),

                .define(
                    "SWIFT_PYTHON_REMOTE_DEBUGGING",
                    .when(
                        platforms: [.macOS, .linux],
                        traits: ["RemoteDebugging"],
                    ),
                ),

                .define(
                    "SWIFT_PYTHON_PROCESS_MODULES",
                    .when(platforms: [.macOS, .macCatalyst, .linux]),
                ),

                .define(
                    "SWIFT_PYTHON_SYSTEM_PROXY",
                    .when(platforms: [.macOS]),
                ),

                .define(
                    "_XOPEN_SOURCE_EXTENDED",
                    to: "1",
                    .when(platforms: [.macOS]),
                ),

                .define(
                    "_GNU_SOURCE",
                    to: "1",
                    .when(platforms: [.linux]),
                ),

                .define(
                    "_XOPEN_SOURCE",
                    to: "800",
                    .when(platforms: [.linux]),
                ),

                .define(
                    "_POSIX_C_SOURCE",
                    to: "202405L",
                    .when(platforms: [.linux]),
                ),

                .define("Py_BUILD_CORE"),
                .define("Py_BUILD_CORE_BUILTIN"),
                .define("NDEBUG"),

                // Clang modules must expose the SDK declaration used by HACL's memset_s.
                .define(
                    "__STDC_WANT_LIB_EXT1__",
                    to: "1",
                    .when(platforms: [.macOS, .iOS, .macCatalyst]),
                ),
            ],
            linkerSettings: [
                .linkedFramework(
                    "Security",
                    .when(platforms: [.macOS, .iOS, .macCatalyst]),
                ),

                .linkedFramework(
                    "SystemConfiguration",
                    .when(platforms: [.macOS]),
                ),

                .linkedFramework(
                    "CoreFoundation",
                    .when(platforms: [.macOS, .iOS, .macCatalyst]),
                ),

                .linkedLibrary("z"),
                .linkedLibrary("bz2"),

                .linkedLibrary(
                    "edit",
                    .when(platforms: [.macOS]),
                ),

                .linkedLibrary(
                    "iconv",
                    .when(platforms: [.macOS, .iOS, .macCatalyst]),
                ),

                .linkedLibrary(
                    "ncurses",
                    .when(platforms: [.macOS]),
                ),

                .linkedLibrary(
                    "panel",
                    .when(platforms: [.macOS]),
                ),

                .linkedLibrary(
                    "m",
                    .when(platforms: [.linux]),
                ),

                .linkedLibrary(
                    "dl",
                    .when(platforms: [.linux]),
                ),

                .linkedLibrary(
                    "pthread",
                    .when(platforms: [.linux]),
                ),
            ],
            plugins: [
                .plugin(name: "CPythonBuildPlugin"),
            ],
        ),

        .libedit,
        .libffi,
        .liblzma,
        .libmpdec,
        .libncurses,
        .libopenssl,
        .libsqlite,
        .libzstd,

        // Tools

        .executableTarget(
            name: "CPythonBuild",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Tools/CPythonBuild",
            swiftSettings: .default,
        ),

        // Supporting

        .libpythontestsupport,
    ],
    cLanguageStandard: .c11,
)

private extension Target {
    static var libedit: Target {
        .target(
            name: "libedit",
            dependencies: [
                .byName(
                    name: "libncurses",
                    condition: .when(platforms: [.linux]),
                ),
            ],
            exclude: [
                "LICENSE",
            ],
            sources: [
                "src",
            ],
            cSettings: [
                .headerSearchPath("Compatibility"),
                .headerSearchPath("src"),

                .define(
                    "HAVE_CONFIG_H",
                    to: "1",
                ),

                .define(
                    "_GNU_SOURCE",
                    .when(platforms: [.linux]),
                ),
            ],
        )
    }
}

private extension Target {
    static var libffi: Target {
        .target(
            name: "libffi",
            exclude: [
                "LICENSE",

                "src/aarch64/sysv.S",
                "src/dlmalloc.c",

                "Compatibility/module.modulemap",
            ],
            sources: [
                "src",
                "Compatibility",
            ],
            cSettings: [
                .headerSearchPath("Compatibility"),
                .headerSearchPath("src/include"),
            ],
        )
    }
}

private extension Target {
    static var liblzma: Target {
        .target(
            name: "liblzma",
            exclude: [
                "LICENSE",
            ],
            sources: [
                "src",
            ],
            cSettings: [
                .disableWarning(
                    "shorten-64-to-32",
                    .when(platforms: [.macOS, .iOS, .macCatalyst]),
                ),

                .headerSearchPath("Compatibility"),

                .headerSearchPath("src/common"),
                .headerSearchPath("src/liblzma/common"),
                .headerSearchPath("src/liblzma/check"),
                .headerSearchPath("src/liblzma/lz"),
                .headerSearchPath("src/liblzma/rangecoder"),
                .headerSearchPath("src/liblzma/lzma"),
                .headerSearchPath("src/liblzma/delta"),
                .headerSearchPath("src/liblzma/simple"),

                .define("HAVE_CONFIG_H", to: "1"),
                .define("HAVE_PTHREAD_CONDATTR_SETCLOCK", to: "1", .when(platforms: [.linux])),
            ],
            linkerSettings: [
                .linkedLibrary("pthread", .when(platforms: [.linux])),
            ],
        )
    }
}

private extension Target {
    static var libmpdec: Target {
        .target(
            name: "libmpdec",
            exclude: [
                "LICENSE",
            ],
            sources: [
                "src",
            ],
            cSettings: [
                .define("CONFIG_64"),
                .define("ANSI"),
                .define("HAVE_UINT128_T"),
                .define("NDEBUG"),
            ],
        )
    }
}

private extension Target {
    static var libncurses: Target {
        .target(
            name: "libncurses",
            exclude: [
                "LICENSE",
                "src/include/capdefaults.c",
            ],
            sources: [
                "src",
            ],
            cSettings: [
                .headerSearchPath("src/include"),
                .headerSearchPath("src/ncurses"),

                .define("HAVE_CONFIG_H", to: "1"),
                .define("BUILDING_NCURSES", to: "1"),
                .define("_GNU_SOURCE", .when(platforms: [.linux])),
                .define("NDEBUG"),
            ],
        )
    }
}

private extension Target {
    static var libopenssl: Target {
        .target(
            name: "libopenssl",
            exclude: [
                "LICENSE",

                "src/crypto/LPdir_nyi.c",
                "src/crypto/LPdir_unix.c",
                "src/crypto/LPdir_vms.c",
                "src/crypto/LPdir_win.c",
                "src/crypto/LPdir_win32.c",
                "src/crypto/LPdir_wince.c",
                "src/crypto/des/ncbc_enc.c",

                "src/providers/decoders.inc",
                "src/providers/encoders.inc",
                "src/providers/fips/include/fips_indicator_params.inc",
                "src/providers/fips/include/fips_selftest_params.inc",
                "src/providers/fips/self_test_data.inc",
                "src/providers/implementations/ciphers/cipher_aes_ccm_hw_aesni.inc",
                "src/providers/implementations/ciphers/cipher_aes_ccm_hw_rv32i.inc",
                "src/providers/implementations/ciphers/cipher_aes_ccm_hw_rv64i.inc",
                "src/providers/implementations/ciphers/cipher_aes_ccm_hw_s390x.inc",
                "src/providers/implementations/ciphers/cipher_aes_ccm_hw_t4.inc",
                "src/providers/implementations/ciphers/cipher_aes_cts.inc",
                "src/providers/implementations/ciphers/cipher_aes_gcm_hw_aesni.inc",
                "src/providers/implementations/ciphers/cipher_aes_gcm_hw_armv8.inc",
                "src/providers/implementations/ciphers/cipher_aes_gcm_hw_ppc.inc",
                "src/providers/implementations/ciphers/cipher_aes_gcm_hw_rv32i.inc",
                "src/providers/implementations/ciphers/cipher_aes_gcm_hw_rv64i.inc",
                "src/providers/implementations/ciphers/cipher_aes_gcm_hw_s390x.inc",
                "src/providers/implementations/ciphers/cipher_aes_gcm_hw_t4.inc",
                "src/providers/implementations/ciphers/cipher_aes_gcm_hw_vaes_avx512.inc",
                "src/providers/implementations/ciphers/cipher_aes_hw_aesni.inc",
                "src/providers/implementations/ciphers/cipher_aes_hw_armv8.inc",
                "src/providers/implementations/ciphers/cipher_aes_hw_rv32i.inc",
                "src/providers/implementations/ciphers/cipher_aes_hw_rv64i.inc",
                "src/providers/implementations/ciphers/cipher_aes_hw_s390x.inc",
                "src/providers/implementations/ciphers/cipher_aes_hw_t4.inc",
                "src/providers/implementations/ciphers/cipher_aes_xts_s390x.inc",
                "src/providers/implementations/ciphers/cipher_camellia_cts.inc",
                "src/providers/implementations/ciphers/cipher_camellia_hw_t4.inc",
                "src/providers/implementations/ciphers/cipher_sm4_ccm_hw_rv64i.inc",
                "src/providers/implementations/ciphers/cipher_sm4_gcm_hw_rv64i.inc",
                "src/providers/implementations/ciphers/cipher_sm4_hw_rv64i.inc",
                "src/providers/implementations/ciphers/cipher_sm4_xts_hw_rv64i.inc",
                "src/providers/implementations/keymgmt/ec_kmgmt_imexport.inc",
                "src/providers/implementations/macs/blake2_mac_impl.c",
                "src/providers/stores.inc",
            ],
            sources: ["src"],
            cSettings: [
                .disableWarning(
                    "shorten-64-to-32",
                    .when(platforms: [.macOS, .iOS, .macCatalyst]),
                ),

                .headerSearchPath("Compatibility"),
                .headerSearchPath("src"),
                .headerSearchPath("src/include"),
                .headerSearchPath("src/providers/common/include"),
                .headerSearchPath("src/providers/implementations/include"),
                .headerSearchPath("src/providers/fips/include"),

                .define("STATIC_LEGACY"),
                .define("NDEBUG"),

                .define(
                    "OPENSSLDIR",
                    to: "\"/etc/ssl\"",
                ),

                .define(
                    "ENGINESDIR",
                    to: "\"\"",
                ),

                .define(
                    "MODULESDIR",
                    to: "\"\"",
                ),

                .define(
                    "_GNU_SOURCE",
                    .when(platforms: [.linux]),
                ),
            ],
            linkerSettings: [
                .linkedLibrary(
                    "pthread",
                    .when(platforms: [.linux]),
                ),
            ],
        )
    }
}

private extension Target {
    static var libpythontestsupport: Target {
        .target(
            name: "libpythontestsupport",
            dependencies: [
                .byName(name: "libcpython"),
            ],
            path: "Tests/libpythontestsupport",
            sources: ["src"],
            linkerSettings: [
                .linkedLibrary(
                    "pthread",
                    .when(platforms: [.linux]),
                ),
            ],
        )
    }
}

private extension Target {
    static var libsqlite: Target {
        .target(
            name: "libsqlite",
            exclude: ["LICENSE.md"],
            sources: ["src/sqlite3.c"],
            cSettings: [
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_ENABLE_COLUMN_METADATA", to: "1"),
                .define("SQLITE_ENABLE_FTS5", to: "1"),
                .define("SQLITE_ENABLE_RTREE", to: "1"),
                .define("SQLITE_ENABLE_MATH_FUNCTIONS", to: "1"),
            ],
            linkerSettings: [
                .linkedLibrary(
                    "m",
                    .when(platforms: [.linux]),
                ),

                .linkedLibrary(
                    "dl",
                    .when(platforms: [.linux]),
                ),
            ],
        )
    }
}

private extension Target {
    static var libzstd: Target {
        .target(
            name: "libzstd",
            exclude: [
                "LICENSE",
                "src/decompress/huf_decompress_amd64.S",
            ],
            sources: [
                "src/common",
                "src/compress",
                "src/decompress",
                "src/dictBuilder",
            ],
            cSettings: [
                .define("ZSTD_DISABLE_ASM", to: "1"),
                .define("ZSTD_MULTITHREAD", to: "1"),
            ],
            linkerSettings: [
                .linkedLibrary(
                    "pthread",
                    .when(platforms: [.linux]),
                ),
            ],
        )
    }
}

// MARK: - SwiftSettings

private extension Array where Element == SwiftSetting {
    static var `default`: [SwiftSetting] {
        [
            .enableExperimentalFeature("Lifetimes"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            .strictMemorySafety(),
            .treatAllWarnings(as: .error),
        ]
    }
}
