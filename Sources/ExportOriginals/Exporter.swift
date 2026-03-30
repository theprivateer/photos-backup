import CryptoKit
import Foundation

struct Exporter {
    let config: Config
    private let fileManager = FileManager.default

    func run() throws -> ExportSummary {
        try validateInput()
        let stateDBURL = resolvedStateDBURL()
        let stateStore = try StateStore(databaseURL: stateDBURL)
        let run = try stateStore.beginRun()
        var summary = ExportSummary()

        do {
            let assets = try PhotosLibraryReader(libraryURL: config.libraryURL).loadAssets(since: config.sinceDate)
            summary.discoveredCount = assets.count
            Console.info("Discovered \(assets.count) original assets.")

            for (index, asset) in assets.enumerated() {
                Console.info("[\(index + 1)/\(assets.count)] \(asset.sourceURL.lastPathComponent)")
                do {
                    let outcome = try process(asset: asset, stateStore: stateStore)
                    switch outcome {
                    case .copied:
                        summary.copiedCount += 1
                    case .skipped:
                        summary.skippedCount += 1
                    case .resumed:
                        summary.resumedCount += 1
                    }
                } catch {
                    summary.failedCount += 1
                    stateStore.appendLog(event: [
                        "timestamp": ISO8601DateFormatter().string(from: Date()),
                        "stable_id": asset.stableID,
                        "source_path": asset.sourceURL.path,
                        "error": error.localizedDescription,
                    ])
                    try? stateStore.upsert(record: makeRecord(
                        for: asset,
                        destinationPath: "",
                        tempPath: nil,
                        status: .failed,
                        hashValue: nil,
                        lastError: error.localizedDescription
                    ))
                    Console.error("failed: \(asset.sourceURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            try? stateStore.finishRun(run, summary: summary)
            throw error
        }

        try stateStore.finishRun(run, summary: summary)
        return summary
    }

    private func process(asset: AssetResource, stateStore: StateStore) throws -> ProcessOutcome {
        let plan = try destinationPlan(for: asset)
        let record = try stateStore.fetchRecord(stableID: asset.stableID)

        if config.resumeEnabled, let record, try destinationStillValid(asset: asset, record: record) {
            return .resumed
        }

        if try finalDestinationAlreadyValid(plan: plan, asset: asset) {
            try stateStore.upsert(record: makeRecord(
                for: asset,
                destinationPath: plan.finalURL.path,
                tempPath: nil,
                status: .verified,
                hashValue: config.verifyMode == .hash ? try sha256(for: plan.finalURL) : nil,
                lastError: nil
            ))
            return .skipped
        }

        if config.dryRun {
            Console.info("dry-run: \(asset.sourceURL.path) -> \(plan.finalURL.path)")
            return .skipped
        }

        try fileManager.createDirectory(
            at: plan.finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        if let record, let tempPath = record.tempPath, fileManager.fileExists(atPath: tempPath) {
            let tempURL = URL(fileURLWithPath: tempPath)
            if try verify(url: tempURL, against: asset, finalURL: plan.finalURL) {
                try replaceItem(at: plan.finalURL, withItemAt: tempURL)
                try stateStore.upsert(record: makeRecord(
                    for: asset,
                    destinationPath: plan.finalURL.path,
                    tempPath: nil,
                    status: .verified,
                    hashValue: config.verifyMode == .hash ? try sha256(for: plan.finalURL) : nil,
                    lastError: nil
                ))
                return .resumed
            }
            try? fileManager.removeItem(at: tempURL)
        }

        try stateStore.upsert(record: makeRecord(
            for: asset,
            destinationPath: plan.finalURL.path,
            tempPath: plan.tempURL.path,
            status: .copying,
            hashValue: nil,
            lastError: nil
        ))

        try streamCopy(from: asset.sourceURL, to: plan.tempURL, fingerprint: asset.fingerprint)
        try stateStore.upsert(record: makeRecord(
            for: asset,
            destinationPath: plan.finalURL.path,
            tempPath: plan.tempURL.path,
            status: .copied,
            hashValue: nil,
            lastError: nil
        ))

        guard try verify(url: plan.tempURL, against: asset, finalURL: plan.finalURL) else {
            throw NSError(domain: "Exporter", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Verification failed for \(asset.sourceURL.lastPathComponent)"
            ])
        }

        try replaceItem(at: plan.finalURL, withItemAt: plan.tempURL)
        let hashValue = config.verifyMode == .hash ? try sha256(for: plan.finalURL) : nil
        try stateStore.upsert(record: makeRecord(
            for: asset,
            destinationPath: plan.finalURL.path,
            tempPath: nil,
            status: .verified,
            hashValue: hashValue,
            lastError: nil
        ))
        return .copied
    }

    private func validateInput() throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: config.libraryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PhotosLibraryError.invalidLibrary("Library package not found at \(config.libraryURL.path)")
        }
        if fileManager.fileExists(atPath: config.destinationURL.path, isDirectory: &isDirectory), isDirectory.boolValue == false {
            throw NSError(domain: "Exporter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Destination exists but is not a directory: \(config.destinationURL.path)"
            ])
        }
    }

    private func resolvedStateDBURL() -> URL {
        if let stateDBURL = config.stateDBURL {
            return stateDBURL
        }
        let appSupport = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/export-originals", isDirectory: true)
        let libraryHash = Insecure.MD5.hash(data: Data(config.libraryURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return appSupport.appendingPathComponent("\(libraryHash).sqlite")
    }

    private func destinationPlan(for asset: AssetResource) throws -> DestinationPlan {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy/MM"
        let folder = formatter.string(from: asset.captureDate)

        let nameFormatter = DateFormatter()
        nameFormatter.locale = Locale(identifier: "en_US_POSIX")
        nameFormatter.timeZone = TimeZone.current
        nameFormatter.dateFormat = "yyyy-MM-dd_HHmmss"

        let suffix = roleSuffix(asset.resourceRole)
        let baseName = nameFormatter.string(from: asset.captureDate) + suffix
        let ext = asset.sourceURL.pathExtension.isEmpty ? "" : ".\(asset.sourceURL.pathExtension.lowercased())"
        let folderURL = config.destinationURL.appendingPathComponent(folder, isDirectory: true)

        var counter = 0
        while true {
            let candidateName = counter == 0 ? baseName : "\(baseName)-\(counter + 1)"
            let finalURL = folderURL.appendingPathComponent(candidateName + ext)
            let tempURL = folderURL.appendingPathComponent(".\(candidateName).partial\(ext)")
            if try destinationAvailable(finalURL: finalURL, asset: asset) {
                return DestinationPlan(finalURL: finalURL, tempURL: tempURL)
            }
            counter += 1
        }
    }

    private func destinationAvailable(finalURL: URL, asset: AssetResource) throws -> Bool {
        if fileManager.fileExists(atPath: finalURL.path) == false {
            return true
        }
        return try verify(url: finalURL, against: asset, finalURL: finalURL)
    }

    private func destinationStillValid(asset: AssetResource, record: AssetRecord) throws -> Bool {
        guard record.status == .verified || record.status == .skipped else { return false }
        return try verify(url: URL(fileURLWithPath: record.destinationPath), against: asset, finalURL: URL(fileURLWithPath: record.destinationPath))
    }

    private func finalDestinationAlreadyValid(plan: DestinationPlan, asset: AssetResource) throws -> Bool {
        guard fileManager.fileExists(atPath: plan.finalURL.path) else { return false }
        return try verify(url: plan.finalURL, against: asset, finalURL: plan.finalURL)
    }

    private func verify(url: URL, against asset: AssetResource, finalURL: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        guard let fileSize = values.fileSize, fileSize >= 0, UInt64(fileSize) == asset.fingerprint.size else {
            return false
        }
        if config.verifyMode == .hash {
            return try sha256(for: url) == sha256(for: asset.sourceURL)
        }
        if let sourceModified = asset.fingerprint.modificationDate,
           let destinationModified = values.contentModificationDate,
           abs(destinationModified.timeIntervalSince(sourceModified)) > 1 {
            return false
        }
        return finalURL.pathExtension.lowercased() == asset.sourceURL.pathExtension.lowercased()
    }

    private func streamCopy(from sourceURL: URL, to destinationURL: URL, fingerprint: SourceFingerprint) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        guard let input = InputStream(url: sourceURL),
              let output = OutputStream(url: destinationURL, append: false) else {
            throw NSError(domain: "Exporter", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Unable to open streams for \(sourceURL.lastPathComponent)"
            ])
        }
        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }

        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while input.hasBytesAvailable {
            let bytesRead = input.read(buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                throw input.streamError ?? NSError(domain: "Exporter", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Read failed for \(sourceURL.path)"
                ])
            }
            if bytesRead == 0 {
                break
            }
            var bytesWritten = 0
            while bytesWritten < bytesRead {
                let written = output.write(buffer + bytesWritten, maxLength: bytesRead - bytesWritten)
                if written <= 0 {
                    throw output.streamError ?? NSError(domain: "Exporter", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "Write failed for \(destinationURL.path)"
                    ])
                }
                bytesWritten += written
            }
        }

        var attributes: [FileAttributeKey: Any] = [:]
        if let creationDate = fingerprint.creationDate {
            attributes[.creationDate] = creationDate
        }
        if let modificationDate = fingerprint.modificationDate {
            attributes[.modificationDate] = modificationDate
        }
        if attributes.isEmpty == false {
            try fileManager.setAttributes(attributes, ofItemAtPath: destinationURL.path)
        }
    }

    private func replaceItem(at finalURL: URL, withItemAt tempURL: URL) throws {
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: tempURL, to: finalURL)
    }

    private func sha256(for url: URL) throws -> String {
        guard let input = InputStream(url: url) else {
            throw NSError(domain: "Exporter", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Unable to open \(url.path) for hashing"
            ])
        }
        input.open()
        defer { input.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while input.hasBytesAvailable {
            let bytesRead = input.read(buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                throw input.streamError ?? NSError(domain: "Exporter", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "Hash read failed for \(url.path)"
                ])
            }
            if bytesRead == 0 {
                break
            }
            hasher.update(data: Data(bytes: buffer, count: bytesRead))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func makeRecord(
        for asset: AssetResource,
        destinationPath: String,
        tempPath: String?,
        status: AssetStatus,
        hashValue: String?,
        lastError: String?
    ) -> AssetRecord {
        AssetRecord(
            stableID: asset.stableID,
            assetID: asset.assetID,
            sourcePath: asset.sourceURL.path,
            sourceSize: asset.fingerprint.size,
            sourceCreationDate: asset.fingerprint.creationDate,
            sourceModificationDate: asset.fingerprint.modificationDate,
            captureDate: asset.captureDate,
            destinationPath: destinationPath,
            tempPath: tempPath,
            status: status,
            verificationMode: config.verifyMode,
            hashValue: hashValue,
            lastError: lastError,
            updatedAt: Date()
        )
    }

    private func roleSuffix(_ role: ResourceRole) -> String {
        switch role {
        case .primary:
            return ""
        case .pairedVideo:
            return "_live"
        case .alternate:
            return "_alt"
        }
    }
}

private enum ProcessOutcome {
    case copied
    case skipped
    case resumed
}

private struct DestinationPlan {
    let finalURL: URL
    let tempURL: URL
}
