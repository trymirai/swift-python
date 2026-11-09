//
//  Created by Anton Spivak
//

// MARK: - _PClass

/// Compiler support synthesized by PythonClass. A Python wrapper owns one Swift instance.
@_documentation(visibility: internal)
public protocol _PClass: AnyObject, SendableMetatype, Encodable, Decodable {
    var _pIdentity: Object.Identity { get }
}

public extension _PClass {
    func encode(to encoder: inout Encoder) throws {
        let storage = try Interpreter.Storage.requireCurrent()
        guard let registry = storage.classRegistry else {
            throw Interpreter.ClassRegistry.unregistered()
        }

        let object = try registry.wrapper(for: self, in: encoder)
        let pointer = unsafe object.release()

        unsafe try encoder.replace(pointer)
    }

    init(from decoder: borrowing Decoder) throws {
        let storage = try Interpreter.Storage.requireCurrent()
        guard
            let registry = storage.classRegistry,
            let instance = unsafe try registry.instance(for: decoder.pointer) as? Self
        else {
            throw decoder.mismatch(String(reflecting: Self.self))
        }
        self.init(existing: instance)
    }
}
