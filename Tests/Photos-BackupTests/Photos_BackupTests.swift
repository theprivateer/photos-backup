import Foundation
import Testing
@testable import ExportOriginals

struct PhotosBackupTests {
    @Test func parsesCLIFlags() throws {
        let config = try CLI.parse(arguments: [
            "--library", "/tmp/Test.photoslibrary",
            "--destination", "/tmp/out",
            "--verify", "hash",
            "--dry-run",
            "--no-resume",
            "--since", "2024-07-21",
            "--state-db", "/tmp/state.sqlite",
        ])

        #expect(config.libraryURL.path == "/tmp/Test.photoslibrary")
        #expect(config.destinationURL.path == "/tmp/out")
        #expect(config.verifyMode == .hash)
        #expect(config.dryRun)
        #expect(config.resumeEnabled == false)
        #expect(config.stateDBURL?.path == "/tmp/state.sqlite")
        #expect(config.sinceDate != nil)
    }

    @Test func stateStorePersistsAssetRecords() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let stateURL = temporaryDirectory.appendingPathComponent("state.sqlite")
        let store = try StateStore(databaseURL: stateURL)
        let asset = AssetRecord(
            stableID: "asset-1",
            assetID: "asset-1",
            sourcePath: "/tmp/source.jpg",
            sourceSize: 42,
            sourceCreationDate: nil,
            sourceModificationDate: nil,
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            destinationPath: "/tmp/dest.jpg",
            tempPath: "/tmp/dest.partial",
            status: .copying,
            verificationMode: .fast,
            hashValue: nil,
            lastError: nil,
            updatedAt: Date()
        )

        try store.upsert(record: asset)
        let fetched = try store.fetchRecord(stableID: "asset-1")
        #expect(fetched?.stableID == "asset-1")
        #expect(fetched?.destinationPath == "/tmp/dest.jpg")
        #expect(fetched?.status == .copying)
    }

    @Test func exporterCopiesAndResumes() throws {
        let root = try makeTemporaryDirectory()
        let library = root.appendingPathComponent("Sample.photoslibrary", isDirectory: true)
        let originals = library.appendingPathComponent("originals/2024/07", isDirectory: true)
        let databaseDirectory = library.appendingPathComponent("database", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        let stateURL = root.appendingPathComponent("state.sqlite")

        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)

        let photoURL = originals.appendingPathComponent("IMG_0001.JPG")
        let videoURL = originals.appendingPathComponent("IMG_0001.MOV")
        try Data("photo".utf8).write(to: photoURL)
        try Data("video".utf8).write(to: videoURL)

        let database = try SQLiteDatabase(path: databaseDirectory.appendingPathComponent("Photos.sqlite").path)
        try database.exec(
            """
            CREATE TABLE ZGENERICASSET (
                Z_PK INTEGER PRIMARY KEY,
                ZUUID TEXT,
                ZDATECREATED DOUBLE
            );
            CREATE TABLE ZADDITIONALASSETATTRIBUTES (
                Z_PK INTEGER PRIMARY KEY,
                ZASSET INTEGER,
                ZORIGINALFILENAME TEXT
            );
            CREATE TABLE ZASSETRESOURCE (
                Z_PK INTEGER PRIMARY KEY,
                ZASSET INTEGER,
                ZUUID TEXT,
                ZFILENAME TEXT,
                ZRESOURCETYPE TEXT
            );
            INSERT INTO ZGENERICASSET(Z_PK, ZUUID, ZDATECREATED) VALUES (1, 'asset-1', 742867200.0);
            INSERT INTO ZADDITIONALASSETATTRIBUTES(Z_PK, ZASSET, ZORIGINALFILENAME) VALUES (1, 1, 'IMG_0001.JPG');
            INSERT INTO ZASSETRESOURCE(Z_PK, ZASSET, ZUUID, ZFILENAME, ZRESOURCETYPE) VALUES
                (1, 1, 'resource-photo', 'IMG_0001.JPG', 'photo'),
                (2, 1, 'resource-video', 'IMG_0001.MOV', 'pairedVideo');
            """
        )

        let config = Config(
            libraryURL: library,
            destinationURL: destination,
            resumeEnabled: true,
            verifyMode: .fast,
            dryRun: false,
            sinceDate: nil,
            stateDBURL: stateURL,
            showHelp: false
        )

        let firstRun = try Exporter(config: config).run()
        #expect(firstRun.copiedCount == 2)
        #expect(firstRun.failedCount == 0)

        let secondRun = try Exporter(config: config).run()
        #expect(secondRun.resumedCount == 2 || secondRun.skippedCount == 2)

        let exportedFiles = try FileManager.default.contentsOfDirectory(
            at: destination.appendingPathComponent("2024/07", isDirectory: true),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        #expect(exportedFiles.count == 2)
        #expect(exportedFiles.contains(where: { $0.hasSuffix(".jpg") }))
        #expect(exportedFiles.contains(where: { $0.hasSuffix("_live.mov") }))
    }

    @Test func metadataFallsBackToFilesystemDate() throws {
        let file = try makeTemporaryDirectory().appendingPathComponent("fallback.txt")
        try Data("test".utf8).write(to: file)
        let metadata = try MetadataResolver.resolveCaptureDate(sourceURL: file, databaseDate: nil)
        #expect(metadata.source == .filesystem)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }
}
