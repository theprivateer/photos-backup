import Foundation

enum PhotosLibraryError: Error, LocalizedError, CustomStringConvertible {
    case invalidLibrary(String)
    case databaseNotFound(String)

    var description: String {
        switch self {
        case .invalidLibrary(let message), .databaseNotFound(let message):
            return message
        }
    }

    var errorDescription: String? {
        description
    }
}

struct PhotosLibraryReader {
    let libraryURL: URL
    private let fileManager = FileManager.default

    func loadAssets(since sinceDate: Date?) throws -> [AssetResource] {
        try validateLibrary()
        let originalFiles = try scanOriginalFiles()
        let metadata = loadMetadataIndexWithFallback()
        var groupedByFilename = Dictionary(grouping: metadata, by: \.normalizedFilename)

        var resources: [AssetResource] = []
        resources.reserveCapacity(originalFiles.count)

        for url in originalFiles {
            let filename = url.lastPathComponent.lowercased()
            let fingerprint = try fingerprint(for: url)
            let matchedMetadata = selectMetadata(
                candidates: groupedByFilename[filename] ?? [],
                url: url,
                fingerprint: fingerprint
            )
            if let matchedMetadata {
                var remaining = groupedByFilename[filename] ?? []
                remaining.removeAll(where: { $0.rowID == matchedMetadata.rowID })
                groupedByFilename[filename] = remaining
            }

            let metadataValue = try MetadataResolver.resolveCaptureDate(
                sourceURL: url,
                databaseDate: matchedMetadata?.captureDate
            )
            if let sinceDate, metadataValue.captureDate < sinceDate {
                continue
            }

            let assetID = matchedMetadata?.assetID ?? fallbackAssetID(for: url)
            let role = matchedMetadata?.resourceRole ?? inferredRole(for: url)
            let resourceID = matchedMetadata?.resourceID ?? fallbackResourceID(for: url, assetID: assetID)

            resources.append(
                AssetResource(
                    stableID: resourceID,
                    assetID: assetID,
                    originalFilename: matchedMetadata?.originalFilename ?? url.lastPathComponent,
                    sourceURL: url,
                    captureDate: metadataValue.captureDate,
                    mediaKind: MetadataResolver.mediaKind(for: url),
                    resourceRole: role,
                    fingerprint: fingerprint
                )
            )
        }

        return resources.sorted {
            if $0.captureDate == $1.captureDate {
                return $0.stableID < $1.stableID
            }
            return $0.captureDate < $1.captureDate
        }
    }

    private func loadMetadataIndexWithFallback() -> [MetadataRow] {
        do {
            return try loadMetadataIndex()
        } catch let error as PhotosLibraryError {
            Console.warning("\(error.description) Falling back to EXIF and filesystem metadata.")
            return []
        } catch let error as SQLiteError {
            Console.warning("Failed to read Photos metadata database: \(error.description). Falling back to EXIF and filesystem metadata.")
            return []
        } catch {
            Console.warning("Failed to inspect Photos metadata database: \(error.localizedDescription). Falling back to EXIF and filesystem metadata.")
            return []
        }
    }

    private func validateLibrary() throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: libraryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PhotosLibraryError.invalidLibrary("Library path is not a package directory: \(libraryURL.path)")
        }
        guard libraryURL.pathExtension == "photoslibrary" else {
            throw PhotosLibraryError.invalidLibrary("Expected a .photoslibrary package: \(libraryURL.path)")
        }
    }

    private func scanOriginalFiles() throws -> [URL] {
        let candidates = [
            libraryURL.appendingPathComponent("originals"),
            libraryURL.appendingPathComponent("Masters"),
        ]
        let roots = candidates.filter {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard roots.isEmpty == false else {
            throw PhotosLibraryError.invalidLibrary("No originals directory found inside \(libraryURL.path)")
        }

        var results: [URL] = []
        for root in roots {
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            while let item = enumerator?.nextObject() as? URL {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                results.append(item)
            }
        }
        return results
    }

    private func libraryDatabaseURL() throws -> URL {
        let candidates = [
            libraryURL.appendingPathComponent("database/Photos.sqlite"),
            libraryURL.appendingPathComponent("database/photos.db"),
            libraryURL.appendingPathComponent("Photos.sqlite"),
        ]
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw PhotosLibraryError.databaseNotFound("Could not find Photos metadata database inside \(libraryURL.path)")
    }

    private func loadMetadataIndex() throws -> [MetadataRow] {
        let databaseURL = try libraryDatabaseURL()
        let database = try SQLiteDatabase(path: databaseURL.path, readOnly: true)

        let assetTable = try findTable(
            database: database,
            candidates: [
                TableRequirement(name: "ZASSET", requiredColumns: ["ZUUID"]),
                TableRequirement(name: "ZGENERICASSET", requiredColumns: ["ZUUID"]),
                TableRequirement(name: "RKMASTER", requiredColumns: ["UUID"]),
            ]
        )
        let additionalTable = try findOptionalTable(
            database: database,
            candidates: [
                TableRequirement(name: "ZADDITIONALASSETATTRIBUTES", requiredColumns: ["ZORIGINALFILENAME"]),
                TableRequirement(name: "RKVERSION", requiredColumns: ["FILENAME"]),
            ]
        )
        let resourceTable = try findOptionalTable(
            database: database,
            candidates: [
                TableRequirement(name: "ZCLOUDRESOURCE", requiredColumns: ["ZASSET"]),
                TableRequirement(name: "ZINTERNALRESOURCE", requiredColumns: ["ZASSET"]),
                TableRequirement(name: "ZASSETRESOURCE", requiredColumns: ["ZASSET"]),
                TableRequirement(name: "RKRESOURCE", requiredColumns: ["MASTERUUID"]),
            ]
        )

        return try fetchMetadata(
            database: database,
            assetTable: assetTable,
            additionalTable: additionalTable,
            resourceTable: resourceTable
        )
    }

    private func fetchMetadata(
        database: SQLiteDatabase,
        assetTable: TableMatch,
        additionalTable: TableMatch?,
        resourceTable: TableMatch?
    ) throws -> [MetadataRow] {
        let assetIDColumn = assetTable.firstExisting(["ZUUID", "UUID"])!
        let assetPKColumn = assetTable.firstExisting(["Z_PK", "MODELID", "ROWID"]) ?? "Z_PK"
        let captureDateColumn = assetTable.firstExisting(["ZDATECREATED", "DATECREATED", "CREATIONDATE"])
        let sortDateColumn = assetTable.firstExisting(["ZSORTTOKEN", "ZADDEDDATE", "IMPORTDATE"])
        let assetFilenameColumn = assetTable.firstExisting(["ZFILENAME", "FILENAME"])

        var joins: [String] = []
        var selects = [
            "a.\(assetPKColumn) AS asset_pk",
            "a.\(assetIDColumn) AS asset_id",
        ]

        if let captureDateColumn {
            selects.append("a.\(captureDateColumn) AS capture_date")
        } else {
            selects.append("NULL AS capture_date")
        }
        if let sortDateColumn {
            selects.append("a.\(sortDateColumn) AS sort_date")
        } else {
            selects.append("NULL AS sort_date")
        }

        if let additionalTable {
            let filenameColumn = additionalTable.firstExisting(["ZORIGINALFILENAME", "FILENAME"])!
            let joinColumn = additionalTable.firstExisting(["ZASSET", "MASTERMODELID", "VERSIONMODELID"])!
            joins.append("LEFT JOIN \(additionalTable.name) aa ON aa.\(joinColumn) = a.\(assetPKColumn)")
            selects.append("aa.\(filenameColumn) AS original_filename")
        } else if let assetFilenameColumn {
            selects.append("a.\(assetFilenameColumn) AS original_filename")
        } else {
            selects.append("NULL AS original_filename")
        }

        if let resourceTable {
            let assetJoinColumn = resourceTable.firstExisting(["ZASSET", "MASTERMODELID", "MASTERUUID"])!
            let resourceFileColumn = resourceTable.firstExisting(["ZFILEPATH", "ZFILENAME", "FILENAME", "ZNORMALIZEDFILENAME"])
            let resourceUUIDColumn = resourceTable.firstExisting(["ZUUID", "UUID", "ZITEMIDENTIFIER", "ZFINGERPRINT", "ZSTABLEHASH"])
            let resourceTypeColumn = resourceTable.firstExisting(["ZRESOURCETYPE", "RESOURCEKIND", "ZTYPE"])
            if assetJoinColumn == "MASTERUUID" {
                joins.append("LEFT JOIN \(resourceTable.name) r ON r.\(assetJoinColumn) = a.\(assetIDColumn)")
            } else {
                joins.append("LEFT JOIN \(resourceTable.name) r ON r.\(assetJoinColumn) = a.\(assetPKColumn)")
            }
            selects.append(resourceFileColumn.map { "r.\($0) AS resource_filename" } ?? "NULL AS resource_filename")
            selects.append(resourceUUIDColumn.map { "r.\($0) AS resource_uuid" } ?? "NULL AS resource_uuid")
            selects.append(resourceTypeColumn.map { "r.\($0) AS resource_type" } ?? "NULL AS resource_type")
        } else {
            selects.append("NULL AS resource_filename")
            selects.append("NULL AS resource_uuid")
            selects.append("NULL AS resource_type")
        }

        let sql = """
        SELECT \(selects.joined(separator: ", "))
        FROM \(assetTable.name) a
        \(joins.joined(separator: "\n"))
        WHERE a.\(assetIDColumn) IS NOT NULL;
        """

        let statement = try database.prepare(sql)
        defer { statement.reset() }

        var rows: [MetadataRow] = []
        var syntheticIndex = 0
        while try statement.step() {
            syntheticIndex += 1
            let assetID = statement.string(at: 1) ?? "asset-\(syntheticIndex)"
            let matchingFilename = normalizedFilenameComponent(statement.string(at: 5))
                ?? normalizedFilenameComponent(statement.string(at: 4))
                ?? ""
            let normalizedFilename = matchingFilename.lowercased()
            guard normalizedFilename.isEmpty == false else { continue }

            let captureDate = decodeApplePhotoDate(statement.double(at: 2))
                ?? decodeApplePhotoDate(statement.double(at: 3))
            let resourceTypeRaw = statement.string(at: 7)
            rows.append(
                MetadataRow(
                    rowID: Int64(syntheticIndex),
                    assetID: assetID,
                    resourceID: statement.string(at: 6) ?? "\(assetID):\(normalizedFilename)",
                    originalFilename: normalizedFilenameComponent(statement.string(at: 4)) ?? matchingFilename,
                    normalizedFilename: normalizedFilename,
                    captureDate: captureDate,
                    resourceRole: resourceRole(from: resourceTypeRaw, filename: normalizedFilename)
                )
            )
        }
        return rows
    }

    private func findTable(database: SQLiteDatabase, candidates: [TableRequirement]) throws -> TableMatch {
        if let match = try findOptionalTable(database: database, candidates: candidates) {
            return match
        }
        throw PhotosLibraryError.databaseNotFound("The Photos metadata database schema is not recognized.")
    }

    private func findOptionalTable(database: SQLiteDatabase, candidates: [TableRequirement]) throws -> TableMatch? {
        for candidate in candidates {
            let columns = try columnsForTable(candidate.name, in: database)
            if candidate.requiredColumns.allSatisfy(columns.contains) {
                return TableMatch(name: candidate.name, columns: columns)
            }
        }
        return nil
    }

    private func columnsForTable(_ tableName: String, in database: SQLiteDatabase) throws -> Set<String> {
        let statement = try database.prepare("PRAGMA table_info(\(tableName));")
        defer { statement.reset() }

        var columns = Set<String>()
        while try statement.step() {
            if let name = statement.string(at: 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    private func fingerprint(for url: URL) throws -> SourceFingerprint {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        return SourceFingerprint(
            size: UInt64(values.fileSize ?? 0),
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate
        )
    }

    private func decodeApplePhotoDate(_ value: Double) -> Date? {
        guard value != 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    private func selectMetadata(candidates: [MetadataRow], url: URL, fingerprint _: SourceFingerprint) -> MetadataRow? {
        if candidates.count <= 1 {
            return candidates.first
        }
        let basename = url.deletingPathExtension().lastPathComponent.lowercased()
        if let liveMatch = candidates.first(where: { row in
            switch row.resourceRole {
            case .pairedVideo:
                return basename.hasSuffix("_mov") || basename.hasSuffix("mov")
            case .primary, .alternate:
                return true
            }
        }) {
            return liveMatch
        }
        return candidates.sorted {
            if $0.captureDate == $1.captureDate {
                return $0.resourceID < $1.resourceID
            }
            return ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast)
        }.first
    }

    private func inferredRole(for url: URL) -> ResourceRole {
        let lowercase = url.deletingPathExtension().lastPathComponent.lowercased()
        if lowercase.hasSuffix("_mov") || lowercase.hasSuffix("mov") {
            return .pairedVideo
        }
        return .primary
    }

    private func resourceRole(from rawType: String?, filename: String) -> ResourceRole {
        if let rawType {
            let lowercase = rawType.lowercased()
            if lowercase.contains("paired") || lowercase.contains("video") || lowercase == "6" {
                return .pairedVideo
            }
        }
        return inferredRole(for: URL(fileURLWithPath: filename))
    }

    private func fallbackAssetID(for url: URL) -> String {
        let relativePath = url.path.replacingOccurrences(of: libraryURL.path, with: "")
        return relativePath
            .split(separator: "/")
            .dropLast()
            .joined(separator: "-")
    }

    private func fallbackResourceID(for url: URL, assetID: String) -> String {
        "\(assetID):\(url.lastPathComponent.lowercased())"
    }

    private func normalizedFilenameComponent(_ raw: String?) -> String? {
        guard let raw, raw.isEmpty == false else { return nil }
        return URL(fileURLWithPath: raw).lastPathComponent
    }
}

private struct TableRequirement {
    let name: String
    let requiredColumns: [String]
}

private struct TableMatch {
    let name: String
    let columns: Set<String>

    func firstExisting(_ candidates: [String]) -> String? {
        candidates.first(where: columns.contains)
    }
}

private struct MetadataRow {
    let rowID: Int64
    let assetID: String
    let resourceID: String
    let originalFilename: String
    let normalizedFilename: String
    let captureDate: Date?
    let resourceRole: ResourceRole
}
