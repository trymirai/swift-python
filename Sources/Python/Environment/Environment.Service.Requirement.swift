//
//  Created by Anton Spivak
//

extension Environment.Service {
    struct Requirement: Decodable, Sendable {
        let name: String
        let declaration: String

        init(from decoder: borrowing Decoder) throws {
            name = try decoder.decode(String.self, forKey: "name")
            declaration = try decoder.decode(String.self, forKey: "declaration")
        }
    }
}
