import Foundation
import Darwin

do {
    let config = try CLI.parse(arguments: Array(CommandLine.arguments.dropFirst()))
    if config.showHelp {
        CLI.printHelp()
        exit(EXIT_SUCCESS)
    }

    let exporter = Exporter(config: config)
    let summary = try exporter.run()
    Console.printSummary(summary)
    exit(summary.failedCount == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
} catch let error as CLIError {
    FileHandle.standardError.write(Data((error.description + "\n").utf8))
    CLI.printHelp()
    exit(EXIT_FAILURE)
} catch {
    FileHandle.standardError.write(Data(("error: \(error.localizedDescription)\n").utf8))
    exit(EXIT_FAILURE)
}
