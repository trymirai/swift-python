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

            if let resolution {
                updated.fingerprint = resolution.fingerprint
                updated.packages = resolution.distributions.mapValues(\.record)
            }
            return updated
        }

        func hasSameWheels(as other: Self) -> Bool {
            packages.count == other.packages.count && packages.allSatisfy { name, record in
                other.packages[name]?.digest == record.digest
            }
        }
    }
}

// MARK: - Environment.Slot

extension Environment {
    enum Slot: String, CaseIterable, Sendable {
        case a
        case b

        var other: Self {
            self == .a ? .b : .a
        }
    }
}

// MARK: - Environment.Publication

extension Environment {
    struct Publication: Sendable {
        let active: Slot?
        let manifest: Manifest
    }
}

// MARK: - Environment.Publication + Encodable

extension Environment.Publication: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(manifest.abi, forKey: "abi")
        try encoder.encode(manifest.fingerprint, forKey: "fingerprint")
        try encoder.encode(manifest.local, forKey: "local")
        try encoder.encode(manifest.packages, forKey: "packages")
        try encoder.encode(active?.rawValue, forKey: "active")
    }
}

// MARK: - Environment.Publication + Decodable

extension Environment.Publication: Decodable {
    init(from decoder: borrowing Decoder) throws {
        let manifest = try Environment.Manifest(
            abi: decoder.decode([String].self, forKey: "abi"),
            fingerprint: decoder.decode(String?.self, forKey: "fingerprint"),
            local: decoder.decode([String: String].self, forKey: "local"),
            packages: decoder.decode(
                [String: Environment.InstalledPackage].self,
                forKey: "packages",
            ),
        )

        let raw = try decoder.decode(String?.self, forKey: "active")
        let active = raw.flatMap(Environment.Slot.init(rawValue:))
        let hasActiveSlot = active != nil
        let needsActiveSlot = !manifest.packages.isEmpty
        guard raw == nil || hasActiveSlot, hasActiveSlot == needsActiveSlot else {
            throw Exception(name: "ValueError", message: "Invalid active package directory.")
        }
        self.init(active: active, manifest: manifest)
    }
}
