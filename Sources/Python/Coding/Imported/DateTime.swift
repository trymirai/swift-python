//
//  Created by Anton Spivak
//

#if canImport(Foundation)
public import Foundation
#endif

// MARK: - DateTime

/// A reference to a `datetime.datetime` in the current Python session.
/// Access its synchronous properties and methods inside `Session.enqueue` or a Swift export.
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
    @PythonInit
    public init(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0,
        microsecond: Int = 0,
        fold: Int = 0,
        in context: Context,
    ) throws

    @PythonInit
    public init(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0,
        microsecond: Int = 0,
        fold: Int = 0,
        in session: Session,
    ) async throws

    /// Creates a UTC datetime from seconds since the Unix epoch.
    public init(utcTimestamp seconds: Double, in context: Context) throws {
        try self.init(timestamp: seconds, utcOffset: 0, in: context)
    }

    /// Parses a Python ISO datetime in the supplied context.
    public init(isoFormat text: String, in context: Context) throws {
        self = try context.call(Self.self, method: "fromisoformat", arguments: [text])
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

private extension DateTime {
    init(timestamp: Double, utcOffset: Int, in context: Context) throws {
        self = try context.withAccess { context in
            let module = try context.import(module: "datetime")
            let delta = try module.value(forAttribute: "timedelta")
            let timeZone = try module.value(forAttribute: "timezone")

            let offset = try delta(keywords: [("seconds", utcOffset)])
            let zone = try timeZone(offset)

            let dateTime = try Self.pythonClass(in: context)
            return try dateTime(methodNamed: "fromtimestamp")(context.encode(timestamp), zone)
                .decode(as: Self.self)
        }
    }
}

#if canImport(Foundation)
public extension DateTime {
    /// Creates a UTC datetime for a Foundation instant.
    init(_ instant: Foundation::Date, in context: Context) throws {
        try self.init(utcTimestamp: instant.timeIntervalSince1970, in: context)
    }

    /// Creates a datetime with the zone's UTC offset at this instant.
    init(_ instant: Foundation::Date, timeZone: TimeZone, in context: Context) throws {
        try self.init(
            timestamp: instant.timeIntervalSince1970,
            utcOffset: timeZone.secondsFromGMT(for: instant),
            in: context,
        )
    }

    /// Converts to a Foundation instant using Python's timestamp semantics.
    func foundationDate() throws -> Foundation::Date {
        try Foundation::Date(self)
    }
}

// MARK: - Foundation.Date

public extension Foundation::Date {
    /// Converts a Python datetime using its timestamp semantics.
    init(_ datetime: Python::DateTime) throws {
        self.init(timeIntervalSince1970: try datetime.timestamp())
    }
}

// MARK: - Foundation.TimeZone

public extension Foundation::TimeZone {
    /// Reads an IANA time zone or UTC offset. Returns nil for a naive datetime.
    init?(_ datetime: Python::DateTime) throws {
        guard let zone = try datetime(Self.timeZone(of:)) else {
            return nil
        }
        self = zone
    }

    private static func timeZone(of datetime: borrowing Object) throws -> TimeZone? {
        let offset = try datetime(methodNamed: "utcoffset")()
        guard try offset.decode(as: Python::Reference?.self) != nil else {
            return nil
        }

        // A named zone preserves its transition rules when Foundation recognizes its key.
        let identifier = try? datetime.value(forAttribute: "tzinfo")
            .value(forAttribute: "key")
            .decode(as: String.self)
        if let identifier, let zone = TimeZone(identifier: identifier) {
            return zone
        }

        let seconds = try offset(methodNamed: "total_seconds")().decode(as: Double.self)
        guard
            let seconds = Int(exactly: seconds),
            let zone = TimeZone(secondsFromGMT: seconds)
        else {
            throw Failure(.valueError, message: "Cannot represent this UTC offset.")
        }
        return zone
    }
}
#endif
