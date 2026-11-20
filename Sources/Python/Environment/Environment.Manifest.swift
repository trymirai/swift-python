//
//  Created by Anton Spivak
//

// MARK: - Environment.Manifest

extension Environment {
    struct Manifest: Sendable, Equatable {
        let abi: [String]
        var fingerprint: String?

        var local: [String: String] = [:]
        var packages: [String: InstalledPackage] = [:]

        func updating(local: [String: String], resolution: Preparation.Resolution?) -> Self {
            var updated = self
            updated.local = local

            guard let resolution else {
                return updated
            }

            updated.fingerprint = resolution.fingerprint
            updated.packages = resolution.distributions.mapValues(\.record)
            return updated
        }

        func hasSameWheels(as other: Self) -> Bool {
            packages.count == other.packages.count && packages.allSatisfy { name, record in
                other.packages[name]?.digest == record.digest
            }
        }
    }
}

// MARK: - Environment.Manifest + Encodable

extension Environment.Manifest: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(abi, forKey: "abi")
        try encoder.encode(fingerprint, forKey: "fingerprint")

        try encoder.encode(local, forKey: "local")
        try encoder.encode(packages, forKey: "packages")
    }
}

// MARK: - Environment.Manifest + Decodable

extension Environment.Manifest: Decodable {
    init(from decoder: borrowing Decoder) throws {
        abi = try decoder.decode([String].self, forKey: "abi")
        fingerprint = try decoder.decode(String?.self, forKey: "fingerprint")

        local = try decoder.decode([String: String].self, forKey: "local")
        packages = try decoder.decode(
            [String: Environment.InstalledPackage].self,
            forKey: "packages",
        )
    }
}

// MARK: - Environment.Publication

extension Environment {
    typealias Slot = Runtime.Paths.Environment.Slot

    // A single rename publishes the active slot and its package records together.
    struct Publication: Sendable {
        let active: Slot?
        let manifest: Manifest
    }
}

// MARK: - Environment.Publication + Encodable

extension Environment.Publication: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try manifest.encode(to: &encoder)
        try encoder.encode(active?.rawValue, forKey: "active")
    }
}

// MARK: - Environment.Publication + Decodable

extension Environment.Publication: Decodable {
    init(from decoder: borrowing Decoder) throws {
        let manifest = try Environment.Manifest(from: decoder)
        let name = try decoder.decode(String?.self, forKey: "active")
        let active = name.flatMap(Environment.Slot.init(rawValue:))

        guard
            name == nil || active != nil,
            manifest.packages.isEmpty == (active == nil)
        else {
            throw Failure(.valueError, message: "Invalid active package directory.")
        }

        self.init(active: active, manifest: manifest)
    }
}
