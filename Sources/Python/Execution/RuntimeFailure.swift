//
//  Created by Anton Spivak
//

struct RuntimeFailure: Swift.Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
