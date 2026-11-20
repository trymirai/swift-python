//
//  Created by Anton Spivak
//

extension Module.Function {
    // Run blocking DNS on an export worker so the event loop can still process cancellation.
    static let resolveHost: Self = .init(
        "resolve_host",
        parameters: [.init("reverse"), .init("arguments")],
        start: { arguments, context in
            let reverse = try arguments.get(0, as: Bool.self)
            let values = try arguments.get(1, as: Reference.self)
            let origin = context
            let method = reverse ? "resolve_name" : "resolve_address"

            return {
                try origin.withAccess { current in
                    let module = try current.import(module: "_swift_python_runtime.async_support")
                    return try module(methodNamed: method)(current.object(values))
                        .retain(in: current)
                }
            }
        },
    )
}
