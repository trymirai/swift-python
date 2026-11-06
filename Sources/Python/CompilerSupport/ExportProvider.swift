//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - _ExportProvider

/// A private provider emitted by an export macro into its registration section.
@_documentation(visibility: internal)
public protocol _ExportProvider {
    static func _pExport<Collector: _ExportSink>(to collector: inout Collector)
}

public extension _ExportProvider {
    /// The generated ELF initializer only records an address; it executes no export code.
    @unsafe
    static func _registerExport(_ registration: @convention(c) @Sendable (
        UnsafeMutableRawPointer,
        @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void,
    ) -> Void) {
        unsafe CPython_RegisterExport(registration)
    }
}
