import Foundation

struct AssetResource: Sendable {
    let stableID: String
    let assetID: String
    let originalFilename: String
    let sourceURL: URL
    let captureDate: Date
    let mediaKind: MediaKind
    let resourceRole: ResourceRole
    let fingerprint: SourceFingerprint
}

enum MediaKind: String, Sendable {
    case image
    case video
    case other
}

enum ResourceRole: String, Sendable {
    case primary
    case pairedVideo
    case alternate
}

struct SourceFingerprint: Sendable {
    let size: UInt64
    let creationDate: Date?
    let modificationDate: Date?
}

enum AssetStatus: String {
    case discovered
    case copying
    case copied
    case verified
    case failed
    case skipped
}

struct ExportSummary {
    var discoveredCount: Int = 0
    var copiedCount: Int = 0
    var skippedCount: Int = 0
    var failedCount: Int = 0
    var resumedCount: Int = 0
}

struct AssetRecord {
    let stableID: String
    let assetID: String
    let sourcePath: String
    let sourceSize: UInt64
    let sourceCreationDate: Date?
    let sourceModificationDate: Date?
    let captureDate: Date
    let destinationPath: String
    let tempPath: String?
    let status: AssetStatus
    let verificationMode: VerificationMode
    let hashValue: String?
    let lastError: String?
    let updatedAt: Date
}

struct RunRecord {
    let id: Int64
    let startedAt: Date
}

enum MetadataDateSource: String {
    case database
    case exif
    case filesystem
}

struct MetadataValue {
    let captureDate: Date
    let source: MetadataDateSource
}
