//
//  Created by Anton Spivak
//

// MARK: ExecutionControl + Object.Callable

extension ExecutionControl: Object.Callable {
    @_lifetime(borrow attachment)
    func call(
        _ arguments: borrowing Object,
        in attachment: borrowing ThreadState.Attachment,
    ) throws -> Object {
        switch try arguments.item(at: 0).string() {
        case "descriptor":
            return try Object(encoding: pipe.reader, in: attachment)
        case "capture":
            return try Object(encoding: hasOutputHandler, in: attachment)
        case "streams":
            let paths = [
                "stdin": standardIO.stdin,
                "stdout": standardIO.stdout,
                "stderr": standardIO.stderr,
                "traceback": standardIO.traceback,
            ]
            return try Object(encoding: paths, in: attachment)
        case "write":
            let stream = try arguments.item(at: 1).string()
            let text = try arguments.item(at: 2).string()
            write(stream == "stdout" ? .stdout : .stderr, text)
            return try Object(encoding: Value.none, in: attachment)
        default:
            throw Exception(name: "ValueError", message: "Unknown Swift execution command.")
        }
    }
}
