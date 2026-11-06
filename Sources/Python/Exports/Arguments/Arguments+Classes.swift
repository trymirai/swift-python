//
//  Created by Anton Spivak
//

public extension Arguments {
    @_documentation(visibility: internal)
    borrowing func receiver<T: _PythonClass>(as type: T.Type) throws -> T {
        try get(0, as: type)
    }
}
