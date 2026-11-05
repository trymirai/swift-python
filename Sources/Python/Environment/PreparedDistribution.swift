//
//  Created by Anton Spivak
//

struct PreparedDistribution: Decodable, Sendable {
    let record: InstalledPackage
    let directory: String
    let files: [String]

    init(from decoder: borrowing Decoder) throws {
        record = try decoder["record"].get()
        directory = try decoder["directory"].get()
        files = try decoder["files"].get()
    }
}
