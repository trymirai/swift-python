//
//  Created by Anton Spivak
//

// MARK: - _PythonClass

/// Compiler support synthesized by PythonClass. A Python wrapper owns one Swift instance.
@_documentation(visibility: internal)
public protocol _PythonClass: AnyObject, SendableMetatype, Encodable, Decodable {
    var _pythonIdentity: any AnyObject & Sendable { get }
    var _pythonContext: Context { get }
}

extension _PythonClass {
    var pythonIdentity: InstanceIdentity {
        get throws {
            guard let identity = _pythonIdentity as? InstanceIdentity else {
                throw ExportCatalog.failure("Invalid Swift instance identity.")
            }
            return identity
        }
    }
}

public extension _PythonClass {
    func encode(to encoder: inout Encoder) throws {
        let storage = try InterpreterStorage.requireCurrent()
        guard let registry = storage.classRegistry else {
            throw ClassRegistry.unregistered()
        }

        let object = try registry.wrapper(for: self, in: encoder)
        let pointer = unsafe object.release()

        unsafe try encoder.replace(pointer)
    }

    init(from decoder: borrowing Decoder) throws {
        let storage = try InterpreterStorage.requireCurrent()
        guard
            let registry = storage.classRegistry,
            let instance = unsafe try registry.instance(for: decoder.pointer) as? Self
        else {
            throw decoder.mismatch(String(reflecting: Self.self))
        }
        self.init(existing: instance)
    }
}
