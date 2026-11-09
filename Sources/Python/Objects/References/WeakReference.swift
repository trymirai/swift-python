//
//  Created by Anton Spivak
//

internal import libcpython

/// Resolves to `nil` once the Python object is collected.
public struct WeakReference: Sendable {
    private let reference: Reference

    /// Throws `TypeError` if the Python object does not support weak references.
    public init(_ object: borrowing Object, in context: borrowing Context) throws {
        try context.checkAccess()
        let weak = unsafe try Object.take(CPython_NewWeakReference(object.pointer), in: context)
        reference = unsafe try context.references.retain(weak.pointer)
    }

    @_lifetime(borrow context)
    func resolve(in context: borrowing Context) throws -> Object? {
        let reference = try reference.resolve(in: context)
        let object = unsafe try Object.take(
            CPython_ResolveWeakReference(reference.pointer),
            in: context,
        )
        if unsafe CPython_ValueTypeOf(object.pointer) == CPython_ValueNone {
            return nil
        }
        return consume object
    }
}
