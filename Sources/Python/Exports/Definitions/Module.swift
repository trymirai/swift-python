//
//  Created by Anton Spivak
//

/// A module made available to the session by the host.
public struct Module: Sendable {
    let name: String
    let documentation: String?

    let source: String?

    let functions: [Function]
    var classes: [Module.Class] = []

    public init(
        _ name: String,
        documentation: String? = nil,
        source: String? = nil,
        functions: [Function] = [],
    ) {
        self.name = name
        self.documentation = documentation
        self.source = source
        self.functions = functions
    }
}
