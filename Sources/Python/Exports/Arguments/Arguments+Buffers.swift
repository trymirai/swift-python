//
//  Created by Anton Spivak
//

public extension Arguments {
    @_lifetime(borrow self)
    @_documentation(visibility: internal)
    borrowing func prepare<Element: BitwiseCopyable>(
        _ type: Span<Element>.Type,
        parameter: Int,
    ) throws -> some _PArgument<Span<Element>> & ~Copyable & ~Escapable {
        do {
            let lease = unsafe try BufferLease<Element>(
                element(position(parameter)),
                in: self,
            )
            return Arguments.PreparedSpan(.ready(consume lease))
        } catch {
            return Arguments.PreparedSpan<Element>(.failed(error))
        }
    }

    @_lifetime(borrow self)
    @_documentation(visibility: internal)
    borrowing func prepare<Element: BitwiseCopyable>(
        _ type: MutableSpan<Element>.Type,
        parameter: Int,
    ) throws -> some _PArgument<MutableSpan<Element>> & ~Copyable & ~Escapable {
        do {
            let lease = unsafe try BufferLease<Element>.Mutable(
                element(position(parameter)),
                in: self,
            )
            return Arguments.PreparedMutableSpan(.ready(consume lease))
        } catch {
            return Arguments.PreparedMutableSpan<Element>(.failed(error))
        }
    }
}
