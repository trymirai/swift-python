//
//  Created by Anton Spivak
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

// MARK: - Failure

struct Failure: Error, CustomStringConvertible {
    init(_ description: String) {
        self.description = description
    }

    let description: String
}

#if canImport(FoundationEssentials) || canImport(Foundation)

// MARK: LocalizedError

extension Failure: LocalizedError {
    var errorDescription: String? {
        description
    }
}

#endif
