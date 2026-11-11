//
//  Created by Anton Spivak
//

extension Session.Control {
    struct Callback: Object.Callable {
        let execution: Session.Control
        let streamsOutput: Bool

        @_lifetime(borrow attachment)
        func call(
            _ arguments: borrowing Object,
            in attachment: borrowing PThread.Attachment,
        ) throws -> Object {
            switch try arguments.item(at: 0).string() {
            case "descriptor":
                return try Object(
                    encoding: execution.pipe.readDescriptor().rawValue,
                    in: attachment,
                )
            case "capture":
                return try Object(encoding: streamsOutput, in: attachment)
            case "interrupted":
                return try Object(encoding: execution.interruption != nil, in: attachment)
            case "write":
                try write(arguments)
                return try Object(encoding: Value.none, in: attachment)
            default:
                throw Exception(name: "ValueError", message: "Unknown Swift execution command.")
            }
        }

        private func write(_ arguments: borrowing Object) throws {
            guard streamsOutput else {
                return
            }

            let name = try arguments.item(at: 1).string()
            guard let stream = Output.Stream(rawValue: name) else {
                throw Exception(
                    name: "ValueError",
                    message: "Unknown Python output stream: \(name).",
                )
            }
            try execution.write(stream, arguments.item(at: 2).string())
        }
    }
}
