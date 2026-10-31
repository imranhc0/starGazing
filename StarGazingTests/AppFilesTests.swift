import XCTest
@testable import StarGazing

final class AppFilesTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOldResultsArePurgedAndRecentOnesKept() throws {
        let old = directory.appendingPathComponent("old.jpg")
        let recent = directory.appendingPathComponent("recent.jpg")
        FileManager.default.createFile(atPath: old.path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: recent.path, contents: Data("x".utf8))
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: old.path)

        AppFiles.purge(directory, olderThan: 7 * 24 * 3600)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testPurgingAMissingFolderDoesNothing() {
        AppFiles.purge(directory.appendingPathComponent("does-not-exist"), olderThan: 60)
    }

    func testFolderIsExcludedFromBackups() throws {
        let folder = directory.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        AppFiles.excludeFromBackup(folder)

        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
