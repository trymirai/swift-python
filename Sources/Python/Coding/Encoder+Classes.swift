//
//  Created by Anton Spivak
//

public extension Encoder {
    /// Used only by a synthesized initializer. Binding happens after Python allocates its wrapper.
    @_documentation(visibility: internal)
    mutating func _encodeNewInstance<T: _PythonClass>(_ instance: T) throws {
        let storage = try InterpreterStorage.requireCurrent()
        guard let registry = storage.classRegistry else {
            throw ClassRegistry.unregistered()
        }
        let capsule = try registry.makeCapsule(for: instance, in: self)
        let pointer = unsafe capsule.release()
        unsafe try replace(pointer)
    }
}
