//
//  Created by Anton Spivak
//

// MARK: - PreparedValue

struct PreparedValue<Value: ~Copyable & ~Escapable>: ~Copyable, ~Escapable, _PythonArgument {
    private var value: Value?
    private let error: (any Swift.Error)?

    @_lifetime(copy value)
    init(value: consuming Value?, error: (any Swift.Error)? = nil) {
        self.value = consume value
        self.error = error
    }

    mutating func validate() throws {
        if let error {
            throw error
        }
    }

    mutating func withValue<Result: ~Copyable>(
        _ body: (inout Value) throws -> Result,
    ) throws -> Result {
        try validate()
        return try body(&value!)
    }
}

// MARK: Escapable

extension PreparedValue: Escapable where Value: Escapable & ~Copyable {}
