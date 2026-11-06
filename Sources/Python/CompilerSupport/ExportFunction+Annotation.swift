//
//  Created by Anton Spivak
//

extension _ExportFunction {
    /// Compiler support for annotations; custom value codecs need no metadata requirements.
    static func pAnnotation<T: ~Copyable & ~Escapable>(for type: T.Type) -> String {
        let name = String(reflecting: type)
        switch name {
        case "()":
            return "None"
        case "Swift.Bool":
            return "bool"
        case "Swift.String":
            return "str"
        case "Swift.Double", "Swift.Float":
            return "float"
        default:
            break
        }

        if name.hasPrefix("Swift.Int") || name.hasPrefix("Swift.UInt") {
            return "int"
        }

        if name.hasPrefix("Swift.Array<") {
            return "list"
        }
        if name.hasPrefix("Swift.Dictionary<") {
            return "dict"
        }
        if name.hasPrefix("Swift.Optional<") {
            return "object | None"
        }

        return "object"
    }
}
