//
//  Created by Anton Spivak
//

@_documentation(visibility: internal)
public func _makeInstanceIdentity<Instance: AnyObject>(
    for type: Instance.Type,
) -> (any AnyObject & Sendable)? {
    if let base = _getSuperclass(type), base is any _PythonClass.Type {
        return nil
    }
    return InstanceIdentity()
}
