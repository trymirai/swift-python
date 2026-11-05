//
//  Created by Anton Spivak
//

// Matches existing environment.json files. Python version semantics stay in PackageService.
struct EnvironmentState: Swift.Codable, Sendable {
    let abi: [String]
    let fingerprint: String?
    let requirements: [String]
    let local: [String: String]
    let packages: [String: InstalledPackage]
    let files: [String: [String]]

    init(abi: [String]) {
        self.abi = abi
        fingerprint = nil
        requirements = []
        local = [:]
        packages = [:]
        files = [:]
    }

    init(
        abi: [String],
        fingerprint: String,
        requirements: [String],
        local: [String: String],
        packages: [String: InstalledPackage],
        files: [String: [String]],
    ) {
        self.abi = abi
        self.fingerprint = fingerprint
        self.requirements = requirements
        self.local = local
        self.packages = packages
        self.files = files
    }
}
