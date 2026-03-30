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
    FileHandle.standardError.write(Data((render(error: error) + "\n").utf8))
    CLI.printHelp()
    exit(EXIT_FAILURE)
} catch {
    FileHandle.standardError.write(Data(("error: \(render(error: error))\n").utf8))
    exit(EXIT_FAILURE)
}

private func render(error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription, description.isEmpty == false {
        return description
    }
    let description = String(describing: error)
    if description.isEmpty == false,
       description != String(reflecting: type(of: error)) {
        return description
    }
    return error.localizedDescription
}
