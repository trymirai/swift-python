//
//  Created by Anton Spivak
//

// MARK: - _ExportFunction.Annotation

public extension _ExportFunction {
    @_documentation(visibility: internal)
    struct Annotation: Sendable {
        let text: String
        let imports: [(module: String, name: String)]

        // The Swift binder injects Context before calling the function.
        let isContext: Bool

        init(
            text: String,
            imports: [(module: String, name: String)] = [],
            isContext: Bool = false,
        ) {
            self.text = text
            self.imports = imports

            self.isContext = isContext
        }

        public init<T: ~Copyable & ~Escapable>(_ type: T.Type) {
            self.init(reflecting: type)
        }

        // This overload can inspect imported types and their containers through Any.Type.
        public init<T>(_ type: T.Type) {
            self = Self.imported(for: type) ?? Self(reflecting: type)
        }

        private init<T: ~Copyable & ~Escapable>(reflecting type: T.Type) {
            self.init(
                text: Self.reflectedText(for: type),
                isContext: ObjectIdentifier(type) == ObjectIdentifier(Context.self),
            )
        }

        private static func imported(for type: Any.Type) -> Self? {
            if let imported = type as? any _PImported.Type {
                let binding = imported._pImport
                return .init(text: "\(binding.module).\(binding.name)", imports: [binding])
            }

            return (type as? any ImportedAnnotationContainer.Type)?.importedAnnotation
        }

        // A container only spells its element type when that type requires an import.
        fileprivate static func imported(
            for type: Any.Type,
            wrapping format: (String) -> String,
        ) -> Self? {
            imported(for: type).map { .init(text: format($0.text), imports: $0.imports) }
        }

        private static func reflectedText<T: ~Copyable & ~Escapable>(for type: T.Type) -> String {
            switch String(reflecting: type) {
            case "()":
                "None"
            case "Swift.Bool":
                "bool"
            case "Swift.String":
                "str"
            case "Swift.Double", "Swift.Float":
                "float"
            case let name where name.hasPrefix("Swift.Int") || name.hasPrefix("Swift.UInt"):
                "int"
            case let name where name.hasPrefix("Swift.Array<"):
                "list"
            case let name where name.hasPrefix("Swift.Dictionary<"):
                "dict"
            case let name where name.hasPrefix("Swift.Optional<"):
                "object | None"
            default:
                "object"
            }
        }
    }
}

// MARK: - _ExportFunction.Annotation + Encodable

extension _ExportFunction.Annotation: Encodable {
    public func encode(to encoder: inout Encoder) throws {
        try encoder.encode(text, at: 0)
        try encoder.encode(imports.map { [$0.module, $0.name] }, at: 1)
    }
}

// MARK: - ImportedAnnotationContainer

private protocol ImportedAnnotationContainer {
    static var importedAnnotation: _ExportFunction.Annotation? { get }
}

// MARK: - Optional + ImportedAnnotationContainer

extension Optional: ImportedAnnotationContainer where Wrapped: Copyable {
    fileprivate static var importedAnnotation: _ExportFunction.Annotation? {
        _ExportFunction.Annotation.imported(for: Wrapped.self) { "\($0) | None" }
    }
}

// MARK: - Array + ImportedAnnotationContainer

extension Array: ImportedAnnotationContainer {
    fileprivate static var importedAnnotation: _ExportFunction.Annotation? {
        _ExportFunction.Annotation.imported(for: Element.self) { "list[\($0)]" }
    }
}

// MARK: - Dictionary + ImportedAnnotationContainer

extension Dictionary: ImportedAnnotationContainer where Key == String {
    fileprivate static var importedAnnotation: _ExportFunction.Annotation? {
        _ExportFunction.Annotation.imported(for: Value.self) { "dict[str, \($0)]" }
    }
}
