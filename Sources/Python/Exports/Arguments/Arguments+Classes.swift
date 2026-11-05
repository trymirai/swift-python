//
//  Created by Anton Spivak
//

public extension Arguments {
    @_documentation(visibility: internal)
    borrowing func receiver<T: _PythonClass>(as type: T.Type) throws -> T {
        let decoder = unsafe try Decoder(element(0), in: self)
        return try decoder.get(as: type)
    }
}
