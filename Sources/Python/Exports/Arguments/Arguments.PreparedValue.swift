//
//  Created by Anton Spivak
//

// MARK: - Arguments.PreparedValue

extension Arguments {
    enum PreparedValue<Value: ~Copyable & ~Escapable>: ~Copyable, ~Escapable, _PArgument {
        case ready(Value)
        case failed(any Swift.Error)
        case used

        borrowing func validate() throws {
            switch self {
            case .ready:
                break
            case let .failed(error):
                throw error
            case .used:
                throw Self.alreadyUsed
            }
        }

        mutating func withValue<Result: ~Copyable>(
            _ body: (inout Value) throws -> Result,
        ) throws -> Result {
            let previous = consume self
            self = .used
            switch consume previous {
            case var .ready(value):
                return try body(&value)
            case let .failed(error):
                throw error
            case .used:
                throw Self.alreadyUsed
            }
        }

        private static var alreadyUsed: Runtime.Failure {
            Runtime.Failure("The prepared Python argument has already been used.")
        }
    }
}

// MARK: - Arguments.PreparedValue + Escapable

extension Arguments.PreparedValue: Escapable where Value: Escapable & ~Copyable {
    init(catching makeValue: () throws -> Value) {
        do {
            self = .ready(try makeValue())
        } catch {
            self = .failed(error)
        }
    }
}
