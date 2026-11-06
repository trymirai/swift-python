//
//  Created by Anton Spivak
//

// MARK: - Session.Control + Object.Callable

extension Session.Control: Object.Callable {
    @_lifetime(borrow attachment)
    func call(
        _ arguments: borrowing Object,
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        switch try arguments.item(at: 0).string() {
        case "descriptor":
            return try Object(encoding: pipe.readDescriptor().rawValue, in: attachment)
        case "capture":
            return try Object(encoding: hasOutputHandler, in: attachment)
        case "streams":
            return try Object(encoding: redirects, in: attachment)
        case "interrupted":
            return try Object(encoding: interruption != nil, in: attachment)
        case "write":
            let name = try arguments.item(at: 1).string()
            guard let stream = Output.Stream(rawValue: name) else {
                throw Exception(
                    name: "ValueError",
                    message: "Unknown Python output stream: \(name).",
                )
            }
            let text = try arguments.item(at: 2).string()
            write(stream, text)
            return try Object(encoding: Value.none, in: attachment)
        default:
            throw Exception(name: "ValueError", message: "Unknown Swift execution command.")
        }
    }
}
