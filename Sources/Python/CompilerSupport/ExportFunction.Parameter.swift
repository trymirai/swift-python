//
//  Created by Anton Spivak
//

// MARK: - _ExportFunction.Parameter

public extension _ExportFunction {
    @_documentation(visibility: internal)
    struct Parameter: Sendable {
        let name: String
        let kind: Kind

        public static var receiver: Self {
            Self(name: "self", kind: .receiver)
        }

        private init(name: String, kind: Kind) {
            self.name = name
            self.kind = kind
        }

        package init(
            _ name: String,
            annotation: String? = nil,
            default defaultValue: Value? = nil,
        ) {
            self.init(
                name: name,
                kind: .argument(
                    annotation: annotation,
                    defaultValue.map(Default.literal) ?? .required,
                ),
            )
        }

        public init<T: ~Copyable & ~Escapable>(
            _ name: String,
            as type: T.Type,
            hasDefaultValue: Bool = false,
        ) {
            let kind: Kind = if ObjectIdentifier(type) == ObjectIdentifier(Context.self) {
                .context
            } else {
                .argument(
                    annotation: _ExportFunction.pAnnotation(for: type),
                    hasDefaultValue ? .swift : .required,
                )
            }
            self.init(name: name, kind: kind)
        }

        var isInjected: Bool {
            if case .context = kind {
                true
            } else {
                false
            }
        }

        var annotation: String? {
            if case let .argument(annotation, _) = kind {
                annotation
            } else {
                nil
            }
        }

        var defaultValue: Default {
            if case let .argument(_, value) = kind {
                value
            } else {
                .required
            }
        }
    }
}

// MARK: - _ExportFunction.Parameter.Kind

extension _ExportFunction.Parameter {
    enum Kind: Sendable {
        case receiver
        case context
        case argument(annotation: String?, Default)
    }
}

// MARK: - _ExportFunction.Parameter.Default

extension _ExportFunction.Parameter {
    enum Default: Sendable {
        case required
        case swift
        case literal(Value)

        var isRequired: Bool {
            if case .required = self {
                true
            } else {
                false
            }
        }

        var literal: Value? {
            if case let .literal(value) = self {
                value
            } else {
                nil
            }
        }
    }
}
