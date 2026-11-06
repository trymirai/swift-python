//
//  Created by Anton Spivak
//

internal import libcpython

public extension Object {
    borrowing func get<T: Decodable & ~Copyable>(
        _ key: String,
        as type: T.Type = T.self,
    ) throws -> T {
        try item(.string(key)).get(as: type)
    }

    borrowing func get<T: Decodable & ~Copyable>(
        _ index: Int,
        as type: T.Type = T.self,
    ) throws -> T {
        try item(.index(index)).get(as: type)
    }

    borrowing func set<T: Encodable & ~Copyable>(
        _ value: borrowing T,
        forKey key: String,
    ) throws {
        try item(.string(key)).set(value)
    }

    borrowing func set<T: Encodable & ~Copyable>(
        _ value: borrowing T,
        at index: Int,
    ) throws {
        try item(.index(index)).set(value)
    }

    borrowing func remove(_ key: String) throws {
        try item(.string(key)).remove()
    }

    borrowing func remove(_ index: Int) throws {
        try item(.index(index)).remove()
    }

    @_lifetime(copy self)
    borrowing func object(_ key: String) throws -> Object {
        try object(for: .string(key))
    }

    @_lifetime(copy self)
    borrowing func object(_ index: Int) throws -> Object {
        try object(for: .index(index))
    }

    @_lifetime(copy self)
    private borrowing func object(for key: Object.Item.Key) throws -> Object {
        let value = try item(key).object()
        return unsafe _overrideLifetime(consume value, copying: self)
    }
}

extension Object {
    @_lifetime(borrow self)
    borrowing func item(_ key: Object.Item.Key) -> Object.Item {
        unsafe Object.Item(container: pointer, key: key, in: self)
    }
}
