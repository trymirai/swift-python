//
//  Created by Anton Spivak
//

struct PackageRequirement: Decodable, Sendable {
    let name: String
    let declaration: String

    init(from decoder: borrowing Decoder) throws {
        name = try decoder["name"].get()
        declaration = try decoder["declaration"].get()
    }
}
