//
//  Created by Anton Spivak
//

#if canImport(Foundation)
public import Foundation
#endif

// MARK: - DateTime

/// A reference to a `datetime.datetime` in the current Python session.
/// Use its Swift members inside `Session.enqueue` or a synchronous Swift export.
@PythonImportedClass(module: "datetime", name: "datetime")
public struct DateTime {
    @PythonProperty(isReadOnly: true)
    public var year: Int
    @PythonProperty(isReadOnly: true)
    public var month: Int
    @PythonProperty(isReadOnly: true)
    public var day: Int

    @PythonProperty(isReadOnly: true)
    public var hour: Int
    @PythonProperty(isReadOnly: true)
    public var minute: Int
    @PythonProperty(isReadOnly: true)
    public var second: Int
    @PythonProperty(isReadOnly: true)
    public var microsecond: Int

    /// Identifies the earlier (0) or later (1) occurrence of a repeated local time.
    @PythonProperty(isReadOnly: true)
    public var fold: Int

    /// Creates a naive datetime from its calendar and clock components.
    public init(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0,
        microsecond: Int = 0,
        fold: Int = 0,
    ) throws {
        self = try Self.withClass { type in
            try type.call(
                arguments: [year, month, day, hour, minute, second, microsecond],
                keywords: [("fold", fold)],
            )
            .decode()
        }
    }

    /// Creates a UTC datetime from seconds since the Unix epoch.
    public init(utcTimestamp seconds: Double) throws {
        self = try Self.withClass { type in
            let utc = try Object.import(module: "datetime", in: type).attribute("UTC")
            let timestamp = try Object(encoding: seconds, in: type)
            return try type.attribute("fromtimestamp").call(timestamp, utc).decode()
        }
    }

    /// Returns the current local time as a naive datetime.
    @PythonFunction
    public static func now() throws -> DateTime

    @PythonFunction("fromisoformat")
    public static func fromISOFormat(_ text: String) throws -> DateTime

    @PythonFunction
    public func date() throws -> Python::Date

    @PythonFunction("isoformat")
    public func isoFormat() throws -> String

    /// Returns seconds since the Unix epoch. Python interprets naive datetimes in local time.
    @PythonFunction
    public func timestamp() throws -> Double

    /// Returns the name supplied by the Python time zone, or nil for a naive datetime.
    @PythonFunction("tzname")
    public func timeZoneName() throws -> String?
}

#if canImport(Foundation)
public extension DateTime {
    /// Creates a UTC datetime for a Foundation instant.
    init(_ instant: Foundation::Date) throws {
        try self.init(utcTimestamp: instant.timeIntervalSince1970)
    }

    /// Converts to a Foundation instant using Python's timestamp semantics.
    func foundationDate() throws -> Foundation::Date {
        try .init(timeIntervalSince1970: timestamp())
    }
}
#endif
