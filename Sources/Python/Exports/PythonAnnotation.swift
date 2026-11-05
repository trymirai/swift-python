//
//  Created by Anton Spivak
//

/// Compiler support for annotations; custom value codecs need no metadata requirements.
func pythonAnnotation<T: ~Copyable & ~Escapable>(_ type: T.Type) -> String {
    let name = String(reflecting: type)
    if name == "()" {
        return "None"
    }
    if name == "Swift.Bool" {
        return "bool"
    }
    if name == "Swift.String" {
        return "str"
    }
    if name == "Swift.Double" || name == "Swift.Float" {
        return "float"
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
