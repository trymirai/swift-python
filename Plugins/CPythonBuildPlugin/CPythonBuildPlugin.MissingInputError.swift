//
//  Created by Anton Spivak
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

// MARK: - CPythonBuildPlugin.MissingInputError

extension CPythonBuildPlugin {
    struct MissingInputError: Error {
        let path: String
    }
}

// MARK: - CPythonBuildPlugin.MissingInputError + CustomStringConvertible

extension CPythonBuildPlugin.MissingInputError: CustomStringConvertible {
    var description: String {
        "Cannot inspect package input: \(path)"
    }
}

#if canImport(FoundationEssentials) || canImport(Foundation)

// MARK: LocalizedError

extension CPythonBuildPlugin.MissingInputError: LocalizedError {
    var errorDescription: String? {
        description
    }
}

#endif
