//
//  Created by Anton Spivak
//

// MARK: - StartupRequest

struct StartupRequest {
    let value: Session.Startup
}

// MARK: Encodable

extension StartupRequest: Encodable {
    func encode(to encoder: inout Encoder) throws {
        switch value {
        case let .source(source):
            try encoder.encode(source, forKey: "source")
        case let .module(module), let .project(_, module):
            try encoder.encode(module, forKey: "module")
        }
    }
}
