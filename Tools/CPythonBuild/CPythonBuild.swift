//
//  Created by Anton Spivak
//

import ArgumentParser
import Logging

// MARK: - CPythonBuild

@main
struct CPythonBuild: AsyncParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "cpython-build",
        abstract: "Build the embedded CPython standard library.",
        subcommands: [Prepare.self, Generate.self],
        defaultSubcommand: Prepare.self,
    )

    @Option(
        name: [.customShort("l"), .long],
        help: .init("Minimum log level.", valueName: "level"),
    )
    var logLevel: Logger.Level = .info
}

extension CPythonBuild {
    func makeLogger() -> Logger {
        var logger = Logger(
            label: "cpython-build",
            factory: StreamLogHandler.standardError(label:),
        )
        logger.logLevel = logLevel
        return logger
    }
}

// MARK: - Logger.Level + @retroactive ExpressibleByArgument

extension Logger.Level: @retroactive ExpressibleByArgument {}
