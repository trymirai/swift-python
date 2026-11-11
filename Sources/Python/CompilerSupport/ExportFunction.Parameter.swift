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

        package init(
            _ name: String,
            annotation: String? = nil,
            default defaultValue: Value? = nil,
        ) {
            self.init(
                name: name,
                kind: .argument(
                    annotation: annotation.map { Annotation(text: $0) },
                    defaultValue.map(Default.literal) ?? .required,
                ),
            )
        }

        public init<T: ~Copyable & ~Escapable>(
            _ name: String,
            as type: T.Type,
            hasDefaultValue: Bool = false,
            isUnlabeled: Bool = false,
        ) {
            self.init(
                name,
                as: Annotation(type),
                hasDefaultValue: hasDefaultValue,
                isUnlabeled: isUnlabeled,
            )
        }

        public init(
            _ name: String,
            as annotation: Annotation,
            hasDefaultValue: Bool = false,
            isUnlabeled: Bool = false,
        ) {
            let kind: Kind = if annotation.isContext {
                .context(isUnlabeled: isUnlabeled)
            } else {
                .argument(
                    annotation: annotation,
                    hasDefaultValue ? .swift : .required,
                )
            }

            self.init(name: name, kind: kind)
        }

        private init(name: String, kind: Kind) {
            self.name = name
            self.kind = kind
        }

        var isInjected: Bool {
            if case .context = kind {
                true
            } else {
                false
            }
        }

        var annotation: Annotation? {
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
        case context(isUnlabeled: Bool)
        case argument(annotation: _ExportFunction.Annotation?, Default)
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
