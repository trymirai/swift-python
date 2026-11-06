//
//  Created by Anton Spivak
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

// MARK: - Runtime.Failure

extension Runtime {
    struct Failure: Swift::Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}

#if canImport(FoundationEssentials) || canImport(Foundation)

// MARK: LocalizedError

extension Runtime.Failure: LocalizedError {
    var errorDescription: String? {
        description
    }
}

#endif
