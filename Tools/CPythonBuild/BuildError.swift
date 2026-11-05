//
//  Created by Anton Spivak
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

// MARK: - BuildError

struct BuildError: Error {
    init(_ description: String) {
        self.description = description
    }

    let description: String
}

// MARK: CustomStringConvertible

extension BuildError: CustomStringConvertible {}

#if canImport(FoundationEssentials) || canImport(Foundation)

// MARK: LocalizedError

extension BuildError: LocalizedError {
    var errorDescription: String? {
        description
    }
}

#endif
