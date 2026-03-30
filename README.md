# Photos Library Originals Export CLI

`export-originals` is a native macOS command-line tool for extracting original media from an Apple Photos library package and copying those files into a predictable, filesystem-friendly backup structure.

The project is designed for long-running exports, external-drive backups, and safe restart behavior. It reads the Photos library package directly, uses Photos metadata when available, falls back to EXIF or filesystem dates when necessary, and writes files into a destination layout organized by capture date.

## Purpose

Apple Photos libraries are convenient for day-to-day use, but they are not ideal as a plain-files backup format:

- originals are stored inside a package bundle
- the folder layout inside the package is optimized for Photos, not for humans
- filenames and media relationships are not always obvious from the package structure alone
- a long copy process can be painful to restart if it fails halfway through

This tool solves that by:

- scanning a `Photos Library.photoslibrary` package for original files
- reading the Photos metadata database to improve asset identity and capture-date accuracy
- copying originals into a destination tree like `YYYY/MM`
- naming files from capture time so the output is easy to browse
- preserving paired Live Photo video naming with a `_live` suffix
- keeping a SQLite state database so interrupted runs can resume safely

The intended outcome is an archive-style backup of original media assets that is easy to inspect outside Photos and easy to store on an external drive.

## Current Behavior

The current implementation is intentionally conservative and archive-oriented.

- It copies original media assets, not Photos-edited renditions.
- It never deletes files from the destination.
- It processes assets sequentially to keep memory usage stable.
- It writes each file to a temporary destination first, then promotes it to the final path after verification.
- It records progress and errors in a local SQLite state database.

By default, copied files are organized like this:

```text
Destination/
  2024/
    07/
      2024-07-21_143205.jpg
      2024-07-21_143205_live.mov
```

## Why Swift

Swift was chosen for a few reasons:

- it is already available on a standard macOS developer machine
- it offers solid Foundation-based filesystem APIs
- it is well suited to a native macOS CLI
- it performs well enough for long-running local copy jobs
- it avoids requiring a Python environment or third-party runtime on the destination machine

The implementation keeps dependencies minimal. It relies on system frameworks and links directly to `sqlite3`.

## High-Level Design

The exporter follows a simple pipeline:

1. Parse CLI arguments and validate the library and destination paths.
2. Inspect the Photos library package for original media files.
3. Open the Photos metadata database and build an index of known assets/resources.
4. Match media files to metadata rows where possible.
5. Resolve the best capture date using this order:
   1. Photos database date
   2. EXIF/TIFF metadata
   3. filesystem timestamps
6. Derive the destination folder and filename.
7. Check the state database and destination to decide whether the asset is already complete.
8. Copy to a temporary file using streaming I/O.
9. Verify the copied file.
10. Atomically move the temporary file into place.
11. Persist the final state and continue to the next asset.

This approach keeps the memory profile flat and makes restart behavior predictable.

## Project Structure

The package is intentionally split into small modules with single responsibilities.

### Package Layout

```text
Package.swift
README.md
Sources/
  ExportOriginals/
    CLI.swift
    Console.swift
    Exporter.swift
    Metadata.swift
    Models.swift
    PhotosLibraryReader.swift
    SQLiteSupport.swift
    StateStore.swift
    main.swift
Tests/
  Photos-BackupTests/
    Photos_BackupTests.swift
```

### Source Files

`Sources/ExportOriginals/main.swift`

- program entrypoint
- parses arguments
- runs the exporter
- prints summary and exit status

`Sources/ExportOriginals/CLI.swift`

- defines CLI configuration
- parses flags and values
- prints usage/help text
- handles `--since` date parsing

`Sources/ExportOriginals/Console.swift`

- very small wrapper for human-readable console output
- keeps log and summary printing consistent

`Sources/ExportOriginals/Models.swift`

- shared data models
- asset/resource identity
- export summary
- state record types

`Sources/ExportOriginals/SQLiteSupport.swift`

- lightweight SQLite wrapper around `sqlite3`
- statement preparation, binding, stepping, and error handling
- intentionally minimal to avoid external dependencies

`Sources/ExportOriginals/StateStore.swift`

- manages the local resume database
- creates and migrates tables
- records per-run and per-asset progress
- stores last-known destination path, temp path, verification mode, and last error
- appends structured log lines for failures

`Sources/ExportOriginals/Metadata.swift`

- resolves capture dates
- prefers Photos database dates
- falls back to EXIF/TIFF metadata
- falls back again to filesystem timestamps
- classifies file types into image/video/other

`Sources/ExportOriginals/PhotosLibraryReader.swift`

- validates the `.photoslibrary` package
- discovers original media files in `originals` or `Masters`
- locates the Photos SQLite database
- adapts to a few known table/column layouts
- builds metadata rows and matches them to source files

`Sources/ExportOriginals/Exporter.swift`

- orchestrates the full export process
- resolves destination paths and filenames
- handles collision suffixing
- manages temp-file copying and final promotion
- checks state for resumable or already-complete work
- performs verification in `fast` or `hash` mode

`Tests/Photos-BackupTests/Photos_BackupTests.swift`

- verifies CLI parsing
- verifies state persistence
- verifies copy/resume behavior with a small synthetic library
- verifies metadata fallback behavior

## Data and Resume Model

One of the main design goals is restart safety.

### State Database

The exporter uses a SQLite database to track progress across runs.

By default, the state database lives under:

```text
~/Library/Application Support/export-originals/<library-hash>.sqlite
```

You can override that location with `--state-db`.

The database stores:

- a `runs` table with start/end time and summary counters
- an `assets` table keyed by a stable asset/resource identifier

Each asset record stores:

- source path
- source size
- source timestamps
- capture date used for naming
- destination path
- temp path, if an in-progress copy exists
- status
- verification mode
- optional hash
- last error
- last update timestamp

### Asset Status Lifecycle

The exporter uses a simple state progression:

- `discovered`
- `copying`
- `copied`
- `verified`
- `failed`
- `skipped`

In practice, the important transitions are:

- `copying` before bytes are streamed
- `copied` after temp-file copy completes
- `verified` after verification and final move succeed
- `failed` if processing errors out

### Restart Behavior

On restart, the exporter checks both:

- the state database
- the destination filesystem

This matters because either source of truth can be stale by itself.

Examples:

- If a file was already verified and still matches the source, the exporter can resume without recopying.
- If a temp file exists from an interrupted copy, the exporter can verify it and promote it if valid.
- If the state database is stale but the final destination file already matches, the exporter can skip recopying.

This dual-check model is more resilient than relying on only filenames or only a progress DB.

## Naming and Organization

The current naming strategy is meant to be readable first, while still being deterministic enough for repeated runs.

### Folder Structure

Folders are created from the resolved capture date:

```text
YYYY/MM
```

Examples:

- `2024/07`
- `2019/12`

### Filename Format

The base filename format is:

```text
YYYY-MM-DD_HHMMSS
```

Examples:

- `2024-07-21_143205.jpg`
- `2024-07-21_143205.mov`

Paired video resources currently receive a suffix:

- `_live` for Live Photo motion components
- `_alt` for alternate resources when identified that way

Examples:

- `2024-07-21_143205.jpg`
- `2024-07-21_143205_live.mov`

### Collision Handling

If the computed destination filename is already taken by a different asset, the exporter appends a numeric suffix:

- `2024-07-21_143205.jpg`
- `2024-07-21_143205-2.jpg`
- `2024-07-21_143205-3.jpg`

If the existing file already verifies as the same asset, it is treated as complete rather than as a collision.

## Verification Strategy

The tool supports two verification modes.

### Fast Verification

`--verify fast`

This is the default mode. It checks:

- file size
- file extension consistency
- modification timestamp alignment when available

This is much cheaper than hashing and is a good default for large libraries.

### Hash Verification

`--verify hash`

This mode computes a SHA-256 hash for both source and destination content and compares them.

Use this when:

- correctness matters more than throughput
- you are exporting to a flaky destination
- you want a stronger end-to-end integrity check

## Photos Library Assumptions

Apple Photos internals have changed over time. The current reader is built to tolerate some schema variation, but it is still based on informed heuristics rather than a guaranteed Apple API contract.

Today the reader:

- looks for originals in `originals` and `Masters`
- looks for a library database in a few common locations
- attempts to match against known table names such as `ZGENERICASSET`, `ZADDITIONALASSETATTRIBUTES`, and `ZASSETRESOURCE`
- falls back gracefully when certain metadata is missing

This means the exporter should work best on common modern Photos libraries, but additional schema adaptation may still be useful for older or unusual libraries.

## Build and Run

### Requirements

- macOS
- Xcode or a compatible Swift toolchain
- local access to a `Photos Library.photoslibrary` package

This package currently declares:

- Swift tools version `6.3`
- macOS deployment target `13`

### Build

```bash
swift build
```

If your environment needs explicit Xcode toolchain selection and local cache paths, this is a reliable form:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.build/ModuleCache \
CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-cache \
TMPDIR=$PWD/.build/tmp \
swift build
```

### Run

Basic usage:

```bash
swift run export-originals \
  --library "/path/to/Photos Library.photoslibrary" \
  --destination "/Volumes/ExternalDrive/PhotosBackup"
```

With stronger verification:

```bash
swift run export-originals \
  --library "/path/to/Photos Library.photoslibrary" \
  --destination "/Volumes/ExternalDrive/PhotosBackup" \
  --verify hash
```

Dry run:

```bash
swift run export-originals \
  --library "/path/to/Photos Library.photoslibrary" \
  --destination "/Volumes/ExternalDrive/PhotosBackup" \
  --dry-run
```

Using a custom state database:

```bash
swift run export-originals \
  --library "/path/to/Photos Library.photoslibrary" \
  --destination "/Volumes/ExternalDrive/PhotosBackup" \
  --state-db "/Volumes/ExternalDrive/export-state.sqlite"
```

Filtering by date:

```bash
swift run export-originals \
  --library "/path/to/Photos Library.photoslibrary" \
  --destination "/Volumes/ExternalDrive/PhotosBackup" \
  --since 2024-01-01
```

### Help

```bash
swift run export-originals --help
```

## CLI Reference

### Required Flags

`--library <path>`

- path to the Photos library package

`--destination <path>`

- path to the backup destination root

### Optional Flags

`--resume`

- enables state-aware resume behavior
- currently the default

`--no-resume`

- ignores previous resume state

`--verify <fast|hash>`

- choose copy verification mode

`--dry-run`

- print planned copy operations without writing files

`--since <date>`

- export only assets on or after a given date
- supported formats:
  - `2024-07-21`
  - `2024-07-21T14:32:05Z`
  - `2024-07-21 14:32:05`

`--state-db <path>`

- override the default SQLite state database path

## Testing

Run the test suite with:

```bash
swift test
```

The current automated tests cover:

- CLI flag parsing
- SQLite state persistence
- end-to-end copy and resume flow using a synthetic sample library
- metadata fallback to filesystem timestamps

## Design Decisions

### Archive Mode Instead of Mirror Mode

The current exporter never deletes files from the destination.

Why:

- backup jobs should be conservative
- deletion logic introduces more risk than value in a first version
- a plain-files archive is safer if the Photos library changes or becomes corrupted later

### Sequential Processing Instead of Parallel Copy

The exporter processes one asset at a time.

Why:

- simpler restart behavior
- lower memory pressure
- fewer surprises on slow or removable external drives
- easier reasoning about temp files and progress state

Parallelism can be added later behind a bounded worker model if needed.

### SQLite for Resume State

Using SQLite instead of a plain JSON file makes it easier to:

- store structured per-asset state
- handle repeated runs
- query asset history
- grow the state model without rewriting large blobs

### Direct Package Inspection Instead of Photos APIs

The exporter reads the library package itself rather than relying on higher-level Photos app APIs.

Why:

- the goal is extracting original files from an existing library package
- package inspection works well for offline backup workflows
- it avoids app-level permission/workflow complexity for this use case

The tradeoff is that library schema changes may require future adaptation.

## Limitations

The project is already useful, but there are some known limitations.

- Photos database schema handling is heuristic, not exhaustive.
- Filename collision suffixing is deterministic and simple, but not yet based on a richer identity scheme.
- The exporter is archive-only and does not support deletion or full synchronization.
- There is no separate machine-readable reporting output yet.
- Progress output is human-readable but still minimal.
- The current test suite uses synthetic sample libraries rather than a real Photos library fixture.

## Suggested Future Improvements

- add broader Photos schema compatibility coverage
- include richer duplicate detection and stronger asset identity mapping
- add optional JSON summary output
- add configurable folder and filename templates
- add bounded concurrency for faster exports to high-throughput destinations
- add richer reporting around failures and skipped assets
- add integration tests against more realistic library fixtures

## Safety Notes

- Always point `--destination` at a backup location you control.
- Start with `--dry-run` on a real library if you want to inspect behavior before copying.
- Consider using `--verify hash` for a first archival pass to a new external drive.
- Keep the state database if you want robust restart behavior across long runs.

## License / Status

This repository currently contains an implementation-oriented project scaffold and working CLI tool, but no explicit software license file yet. Add a license before wider distribution.
