//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct ExportRegistration {
    private let name: TokenSyntax
    private let definition: String

    init(name base: String, definition: String, in context: some MacroExpansionContext) {
        name = context.makeUniqueName("__p_" + base)
        self.definition = definition
    }

    init(
        method: FunctionDeclSyntax,
        definition: String,
        in context: some MacroExpansionContext,
    ) {
        let signature = Self.signatureHash(method.signature.trimmedDescription)
        self.init(
            name: method.name.text + "_" + String(signature, radix: 16),
            definition: definition,
            in: context,
        )
    }

    var declaration: DeclSyntax {
        """
        private enum \(name): Python::_ExportProvider {
            nonisolated static func _pExport<Collector: Python::_ExportSink>(to collector: inout Collector) {
                \(raw: definition)
            }
            \(raw: registration)
        }
        """
    }

    private var registration: String {
        """
        #if objectFormat(MachO)
        @used
        @section("__DATA,__pyexports")
        #elseif objectFormat(ELF)
        @used
        @section("swift_python_exports")
        #endif
        private nonisolated static let __registration: @convention(c) @Sendable (
            Swift::UnsafeMutableRawPointer,
            @convention(c) (Swift::UnsafeMutableRawPointer, Swift::UnsafeRawPointer) -> Swift::Void
        ) -> Swift::Void = { collector, consume in
            let provider: any Python::_ExportProvider.Type = Self.self
            Swift::withUnsafePointer(to: provider) { pointer in
                unsafe consume(collector, Swift::UnsafeRawPointer(pointer))
            }
        }
        #if objectFormat(ELF)
        @used
        @section(".init_array")
        private nonisolated static let __bootstrap: @convention(c) @Sendable () -> Swift::Void = {
            unsafe Self._registerExport(Self.__registration)
        }
        #endif
        """
    }

    private static func signatureHash(_ signature: String) -> UInt64 {
        // Swift 6.4 gives overloads the same expansion-name base. FNV-1a keeps
        // registration names distinct and stable across compiler processes.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in signature.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return hash
    }
}
