//
//  Created by Anton Spivak
//

/// The exact Python exception class name, including application-defined classes.
public struct ExceptionName: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let attributeError: Self = .init(rawValue: "AttributeError")
    public static let bufferError: Self = .init(rawValue: "BufferError")
    public static let fileNotFoundError: Self = .init(rawValue: "FileNotFoundError")
    public static let importError: Self = .init(rawValue: "ImportError")
    public static let indexError: Self = .init(rawValue: "IndexError")
    public static let keyError: Self = .init(rawValue: "KeyError")
    public static let memoryError: Self = .init(rawValue: "MemoryError")
    public static let moduleNotFoundError: Self = .init(rawValue: "ModuleNotFoundError")
    public static let nameError: Self = .init(rawValue: "NameError")
    public static let osError: Self = .init(rawValue: "OSError")
    public static let overflowError: Self = .init(rawValue: "OverflowError")
    public static let permissionError: Self = .init(rawValue: "PermissionError")
    public static let referenceError: Self = .init(rawValue: "ReferenceError")
    public static let runtimeError: Self = .init(rawValue: "RuntimeError")
    public static let stopIteration: Self = .init(rawValue: "StopIteration")
    public static let syntaxError: Self = .init(rawValue: "SyntaxError")
    public static let typeError: Self = .init(rawValue: "TypeError")
    public static let valueError: Self = .init(rawValue: "ValueError")
    public static let zeroDivisionError: Self = .init(rawValue: "ZeroDivisionError")
}
