//
//  Created by Anton Spivak
//

// MARK: - Date

/// A reference to a `datetime.date` in the current Python session.
/// Use its Swift members inside `Session.enqueue` or a synchronous Swift export.
@PythonImportedClass(module: "datetime", name: "date")
public struct Date {
    @PythonProperty(isReadOnly: true)
    public var year: Int
    @PythonProperty(isReadOnly: true)
    public var month: Int
    @PythonProperty(isReadOnly: true)
    public var day: Int

    /// Creates a calendar date in the attached interpreter.
    public init(year: Int, month: Int, day: Int) throws {
        self = try Self.withClass { type in
            try type.call(arguments: [year, month, day], keywords: []).decode()
        }
    }

    @PythonFunction
    public static func today() throws -> Date

    @PythonFunction("fromisoformat")
    public static func fromISOFormat(_ text: String) throws -> Date

    @PythonFunction("isoformat")
    public func isoFormat() throws -> String

    /// Returns the day of the week, with Monday as zero.
    @PythonFunction
    public func weekday() throws -> Int
}
