//
//  Created by Anton Spivak
//

public extension Arguments {
    @_lifetime(borrow self)
    @_documentation(visibility: internal)
    borrowing func prepare<Element: BitwiseCopyable>(
        _ type: Span<Element>.Type,
        parameter: Int,
    ) throws -> some _PythonArgument<Span<Element>> & ~Copyable & ~Escapable {
        do {
            let lease = unsafe try BufferLease<Element>(
                element(position(parameter)),
                isWritable: false,
                in: self,
            )
            return SpanArgument(lease: .some(consume lease), error: nil)
        } catch {
            return SpanArgument<Element>(lease: nil, error: error)
        }
    }

    @_lifetime(borrow self)
    @_documentation(visibility: internal)
    borrowing func prepare<Element: BitwiseCopyable>(
        _ type: MutableSpan<Element>.Type,
        parameter: Int,
    ) throws -> some _PythonArgument<MutableSpan<Element>> & ~Copyable & ~Escapable {
        do {
            let lease = unsafe try BufferLease<Element>(
                element(position(parameter)),
                isWritable: true,
                in: self,
            )
            return MutableSpanArgument(lease: .some(consume lease), error: nil)
        } catch {
            return MutableSpanArgument<Element>(lease: nil, error: error)
        }
    }
}
