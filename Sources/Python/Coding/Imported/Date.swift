//
//  Created by Anton Spivak
//

#if canImport(Foundation)
public import Foundation
#endif

// MARK: - Date

/// A reference to a `datetime.date` in the current Python session.
/// Use its Swift members inside `Session.enqueue` or a Swift export.
@PythonImportedClass(module: "datetime", name: "date")
public struct Date {
    @PythonProperty(isReadOnly: true)
    public var year: Int
    @PythonProperty(isReadOnly: true)
    public var month: Int
    @PythonProperty(isReadOnly: true)
    public var day: Int

    /// Creates a calendar date in the supplied context.
    public init(year: Int, month: Int, day: Int, in context: Context) throws {
        self = try context.construct(Self.self, arguments: [year, month, day])
    }

    /// Parses a Python ISO calendar date in the supplied context.
    public init(isoFormat text: String, in context: Context) throws {
        self = try context.call(Self.self, method: "fromisoformat", arguments: [text])
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

#if canImport(Foundation)
public extension Date {
    /// Creates a calendar date in the supplied time zone, or the system time zone by default.
    init(_ instant: Foundation::Date, timeZone: TimeZone = .current, in context: Context) throws {
        let datetime = try DateTime(instant, timeZone: timeZone, in: context)
        self = try context.call(datetime, method: "date")
    }
}

// MARK: - Foundation.Date

public extension Foundation::Date {
    /// Creates midnight for a Python calendar date in the supplied time zone.
    init(_ date: Python::Date, timeZone: TimeZone = .current) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = try DateComponents(year: date.year, month: date.month, day: date.day)
        guard let instant = calendar.date(from: components) else {
            throw Exception(name: "ValueError", message: "Cannot represent this calendar date.")
        }
        self = instant
    }
}
#endif
