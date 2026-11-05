//
//  Created by Anton Spivak
//

import Synchronization

public extension Module {
    @_documentation(visibility: internal)
    static func _makeInstanceIdentity<Instance: AnyObject>(
        for type: Instance.Type,
    ) -> (any AnyObject & Sendable)? {
        if let base = _getSuperclass(type), base is any _PythonClass.Type {
            return nil as InstanceIdentity?
        }
        return InstanceIdentity()
    }
}
