//
//  Created by Anton Spivak
//

struct PreparedDistribution: Decodable, Sendable {
    let record: InstalledPackage
    let directory: String
    let files: [String]

    init(from decoder: borrowing Decoder) throws {
        record = try decoder.decode(InstalledPackage.self, forKey: "record")
        directory = try decoder.decode(String.self, forKey: "directory")
        files = try decoder.decode([String].self, forKey: "files")
    }
}
