import Foundation

enum VerificationMode: String {
    case fast
    case hash
}

struct Config {
    let libraryURL: URL
    let destinationURL: URL
    let resumeEnabled: Bool
    let verifyMode: VerificationMode
    let dryRun: Bool
    let sinceDate: Date?
    let stateDBURL: URL?
    let showHelp: Bool
}

enum CLIError: Error, LocalizedError, CustomStringConvertible {
    case missingValue(String)
    case missingRequired(String)
    case invalidValue(flag: String, value: String)
    case unknownFlag(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "Missing value for \(flag)."
        case .missingRequired(let flag):
            return "Missing required flag \(flag)."
        case .invalidValue(let flag, let value):
            return "Invalid value '\(value)' for \(flag)."
        case .unknownFlag(let flag):
            return "Unknown flag \(flag)."
        }
    }

    var errorDescription: String? {
        description
    }
}

enum CLI {
    static func parse(arguments: [String]) throws -> Config {
        var library: URL?
        var destination: URL?
        var resumeEnabled = true
        var verifyMode: VerificationMode = .fast
        var dryRun = false
        var sinceDate: Date?
        var stateDBURL: URL?
        var showHelp = false

        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--help", "-h":
                showHelp = true
            case "--library":
                guard let value = iterator.next() else { throw CLIError.missingValue(argument) }
                library = URL(fileURLWithPath: value)
            case "--destination":
                guard let value = iterator.next() else { throw CLIError.missingValue(argument) }
                destination = URL(fileURLWithPath: value)
            case "--verify":
                guard let value = iterator.next() else { throw CLIError.missingValue(argument) }
                guard let mode = VerificationMode(rawValue: value) else {
                    throw CLIError.invalidValue(flag: argument, value: value)
                }
                verifyMode = mode
            case "--state-db":
                guard let value = iterator.next() else { throw CLIError.missingValue(argument) }
                stateDBURL = URL(fileURLWithPath: value)
            case "--since":
                guard let value = iterator.next() else { throw CLIError.missingValue(argument) }
                sinceDate = try DateParser.parse(value)
            case "--dry-run":
                dryRun = true
            case "--resume":
                resumeEnabled = true
            case "--no-resume":
                resumeEnabled = false
            default:
                throw CLIError.unknownFlag(argument)
            }
        }

        if showHelp {
            return Config(
                libraryURL: library ?? URL(fileURLWithPath: "/path/to/Photos Library.photoslibrary"),
                destinationURL: destination ?? URL(fileURLWithPath: "/path/to/backup"),
                resumeEnabled: resumeEnabled,
                verifyMode: verifyMode,
                dryRun: dryRun,
                sinceDate: sinceDate,
                stateDBURL: stateDBURL,
                showHelp: true
            )
        }

        guard let libraryURL = library else { throw CLIError.missingRequired("--library") }
        guard let destinationURL = destination else { throw CLIError.missingRequired("--destination") }

        return Config(
            libraryURL: libraryURL,
            destinationURL: destinationURL,
            resumeEnabled: resumeEnabled,
            verifyMode: verifyMode,
            dryRun: dryRun,
            sinceDate: sinceDate,
            stateDBURL: stateDBURL,
            showHelp: false
        )
    }

    static func printHelp() {
        let help = """
        Usage: export-originals --library <path> --destination <path> [options]

        Required:
          --library <path>         Path to a Photos Library.photoslibrary package
          --destination <path>     Destination root for organized originals

        Options:
          --resume                 Resume from state database (default)
          --no-resume              Ignore previous state and build a fresh run
          --verify <fast|hash>     Verification mode (default: fast)
          --dry-run                Print intended work without copying files
          --since <date>           Only export assets captured on or after the given date
          --state-db <path>        Override the state database location
          --help                   Show this help

        Supported date formats for --since:
          2024-07-21
          2024-07-21T14:32:05Z
          2024-07-21 14:32:05
        """
        print(help)
    }
}

enum DateParser {
    private static func formatters() -> [ISO8601DateFormatter] {
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let internetNoFraction = ISO8601DateFormatter()
        internetNoFraction.formatOptions = [.withInternetDateTime]
        return [internet, internetNoFraction]
    }

    private static func manualFormatters() -> [DateFormatter] {
        let formats = [
            "yyyy-MM-dd",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
        ]
        return formats.map {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = $0
            return formatter
        }
    }

    static func parse(_ raw: String) throws -> Date {
        for formatter in formatters() {
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        for formatter in manualFormatters() {
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        throw CLIError.invalidValue(flag: "--since", value: raw)
    }
}
