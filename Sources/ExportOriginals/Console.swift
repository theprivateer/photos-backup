import Foundation

enum Console {
    static func info(_ message: String) {
        print(message)
    }

    static func warning(_ message: String) {
        FileHandle.standardError.write(Data(("warning: " + message + "\n").utf8))
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func printSummary(_ summary: ExportSummary) {
        print(
            """
            Summary
              discovered: \(summary.discoveredCount)
              copied: \(summary.copiedCount)
              skipped: \(summary.skippedCount)
              resumed: \(summary.resumedCount)
              failed: \(summary.failedCount)
            """
        )
    }
}
