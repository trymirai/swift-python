//
//  Created by Anton Spivak
//

public extension Module.Function {
    struct Parameter: Sendable {
        let name: String
        let annotation: String?

        let defaultValue: Value?
        let hasDefaultValue: Bool

        let isInjected: Bool

        public init(
            _ name: String,
            annotation: String? = nil,
            default defaultValue: Value? = nil,
        ) {
            self.name = name
            self.annotation = annotation
            self.defaultValue = defaultValue
            self.hasDefaultValue = defaultValue != nil
            self.isInjected = false
        }

        public init<T: ~Copyable & ~Escapable>(
            _ name: String,
            as type: T.Type,
            hasDefaultValue: Bool = false,
        ) {
            self.name = name
            self.annotation = pythonAnnotation(type)
            self.defaultValue = nil
            self.hasDefaultValue = hasDefaultValue
            self.isInjected = ObjectIdentifier(type) == ObjectIdentifier(Context.self)
        }
    }
}
