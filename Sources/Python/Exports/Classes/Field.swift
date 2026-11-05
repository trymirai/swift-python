//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization

/// A Python-owned field. Keep this token in the Swift peer and access it in an attached scope.
/// Python's cyclic collector sees the stored value, including callbacks that capture the peer.
public struct Field<Value>: Sendable {
    private final class Cell: Sendable {
        struct Location: Sendable {
            let identity: InstanceIdentity
            let key: String
        }

        let location: Mutex<Location?> = .init(nil)
    }

    private let cell: Cell = .init()

    public init() {}

    func bind(to identity: InstanceIdentity, key: String) throws {
        try cell.location.withLock { location in
            if let location {
                guard location.identity === identity, location.key == key else {
                    throw ExportCatalog
                        .failure("A Python Field token cannot be shared by different fields.")
                }
            } else {
                location = .init(identity: identity, key: key)
            }
        }
    }

    @_lifetime(borrow context)
    private func dictionary(in context: borrowing Context) throws -> Object {
        try context.checkAccess()
        guard
            let location = cell.location.withLock({ $0 }),
            let weak = location.identity.wrapper,
            let wrapper = try weak.resolve(in: context)
        else {
            throw Exception(
                name: "ReferenceError",
                message: "The Python field has no live wrapper.",
            )
        }
        return try wrapper.attribute("_swift_fields")
    }

    public func get(in context: borrowing Context) throws -> Value where Value: Decodable {
        let dictionary = try dictionary(in: context)
        let key = cell.location.withLock { $0!.key }
        let object = try Object(encoding: key, in: context)
        let contains = unsafe PyDict_Contains(dictionary.pointer, object.pointer)
        guard contains >= 0 else {
            throw Object.failure("Unable to read a Python field.")
        }
        if contains == 0 {
            let none = unsafe try Object.take(Py_GetConstant(UInt32(Py_CONSTANT_NONE)), in: context)
            return try none.decode(as: Value.self)
        }
        return try dictionary[key].get(as: Value.self)
    }

    public func set(_ value: borrowing Value, in context: borrowing Context) throws
        where Value: Encodable
    {
        let dictionary = try dictionary(in: context)
        let key = cell.location.withLock { $0!.key }
        try dictionary[key].set(value)
    }

    public func remove(in context: borrowing Context) throws {
        let dictionary = try dictionary(in: context)
        let key = cell.location.withLock { $0!.key }
        try dictionary[key].remove()
    }
}
