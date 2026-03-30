import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MetadataResolver {
    static func resolveCaptureDate(
        sourceURL: URL,
        databaseDate: Date?,
        fileManager: FileManager = .default
    ) throws -> MetadataValue {
        if let databaseDate {
            return MetadataValue(captureDate: databaseDate, source: .database)
        }
        if let exifDate = try readEXIFDate(sourceURL: sourceURL) {
            return MetadataValue(captureDate: exifDate, source: .exif)
        }
        let values = try sourceURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        if let filesystemDate = values.creationDate ?? values.contentModificationDate {
            return MetadataValue(captureDate: filesystemDate, source: .filesystem)
        }
        throw NSError(domain: "MetadataResolver", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Unable to determine capture date for \(sourceURL.path)"
        ])
    }

    static func mediaKind(for sourceURL: URL) -> MediaKind {
        let type = UTType(filenameExtension: sourceURL.pathExtension)
        if type?.conforms(to: .image) == true {
            return .image
        }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .audiovisualContent) == true {
            return .video
        }
        return .other
    }

    private static func readEXIFDate(sourceURL: URL) throws -> Date? {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = exifDateFormatter.date(from: original) {
            return date
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let original = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = exifDateFormatter.date(from: original) {
            return date
        }

        return nil
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}
