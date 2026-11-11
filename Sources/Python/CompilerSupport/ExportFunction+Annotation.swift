//
//  Created by Anton Spivak
//

// MARK: - _ExportFunction.Annotation

public extension _ExportFunction {
    @_documentation(visibility: internal)
    struct Annotation: Sendable {
        let text: String
        let imports: [(module: String, name: String)]

        private let suffix: String
        // Exported class names resolve when encoding, after their modules have been selected.
        private let classKey: String?

        // The Swift binder injects Context before calling the function.
        let isContext: Bool

        init(
            text: String,
            suffix: String = "",
            classKey: String? = nil,
            imports: [(module: String, name: String)] = [],
            isContext: Bool = false,
        ) {
            self.text = text
            self.imports = imports

            self.suffix = suffix
            self.classKey = classKey

            self.isContext = isContext
        }

        public init<T: ~Copyable & ~Escapable>(_ type: T.Type) {
            self.init(reflecting: type)
        }

        public init<T>(_ type: T.Type) {
            self = Self.known(for: type) ?? Self(reflecting: type)
        }

        private init<T: ~Copyable & ~Escapable>(reflecting type: T.Type) {
            self.init(
                text: Self.reflectedText(for: type),
                isContext: ObjectIdentifier(type) == ObjectIdentifier(Context.self),
            )
        }

        private static func known(for type: Any.Type) -> Self? {
            if let imported = type as? any _PImported.Type {
                let binding = imported._pImport
                return .init(text: "\(binding.module).\(binding.name)", imports: [binding])
            }
            if let container = type as? any AnnotationContainer.Type {
                return container.annotation
            }
            if type is any _PClass.Type {
                return .init(text: "", classKey: String(reflecting: type))
            }
            if let raw = type as? any RawRepresentable.Type {
                return rawAnnotation(for: raw)
            }
            return nil
        }

        private static func rawAnnotation<T: RawRepresentable>(for _: T.Type) -> Self {
            Self(T.RawValue.self)
        }

        fileprivate func wrapped(prefix: String, suffix: String) -> Self {
            .init(
                text: prefix + text,
                suffix: self.suffix + suffix,
                classKey: classKey,
                imports: imports,
            )
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
        var text = self.text
        var imports = self.imports
        if let classKey {
            let storage = try Interpreter.Storage.requireCurrent()
            guard let binding = storage.classRegistry?.binding(for: classKey) else {
                throw Interpreter.ClassRegistry.unregistered()
            }
            text += "\(binding.module).\(binding.name)"
            imports.append(binding)
        }
        try encoder.encode(text + suffix, at: 0)
        try encoder.encode(imports.map { [$0.module, $0.name] }, at: 1)
    }
}

// MARK: - AnnotationContainer

private protocol AnnotationContainer {
    static var annotation: _ExportFunction.Annotation { get }
}

// MARK: - Optional + AnnotationContainer

extension Optional: AnnotationContainer where Wrapped: Copyable {
    fileprivate static var annotation: _ExportFunction.Annotation {
        _ExportFunction.Annotation(Wrapped.self).wrapped(prefix: "", suffix: " | None")
    }
}

// MARK: - Array + AnnotationContainer

extension Array: AnnotationContainer {
    fileprivate static var annotation: _ExportFunction.Annotation {
        _ExportFunction.Annotation(Element.self).wrapped(prefix: "list[", suffix: "]")
    }
}

// MARK: - Dictionary + AnnotationContainer

extension Dictionary: AnnotationContainer where Key == String {
    fileprivate static var annotation: _ExportFunction.Annotation {
        _ExportFunction.Annotation(Value.self).wrapped(prefix: "dict[str, ", suffix: "]")
    }
}
