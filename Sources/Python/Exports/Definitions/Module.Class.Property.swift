//
//  Created by Anton Spivak
//

extension Module.Class {
    struct Property: Sendable {
        let name: String
        let documentation: String?

        let getter: Module.Function
        let setter: Module.Function?
    }
}
