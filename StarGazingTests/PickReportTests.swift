import XCTest
@testable import StarGazing

final class PickReportTests: XCTestCase {

    func testNothingSkippedMeansNoMessage() {
        let report = PickReport(picked: 12, readable: 12)

        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.skipped, 0)
        XCTAssertNil(report.message)
        XCTAssertTrue(report.canStack)
    }

    func testSkippedPhotosAreCountedAndNamedInTheMessage() throws {
        // The limited-access case: 30 chosen, only 8 are in the library selection the app may read.
        let report = PickReport(picked: 30, readable: 8)

        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.skipped, 22)
        let message = try XCTUnwrap(report.message)
        XCTAssertTrue(message.contains("8 of the 30"), message)
        XCTAssertTrue(report.canStack, "8 is enough to stack")
    }

    func testTooFewReadablePhotosCannotStack() throws {
        let report = PickReport(picked: 30, readable: 0)

        XCTAssertFalse(report.canStack)
        let message = try XCTUnwrap(report.message)
        XCTAssertTrue(message.contains("0 of the 30"), message)
    }

    func testTheMinimumIsTheSameOneTheStackerEnforces() {
        let minimum = StackRequest.frameRange.lowerBound

        XCTAssertFalse(PickReport(picked: 30, readable: minimum - 1).canStack)
        XCTAssertTrue(PickReport(picked: 30, readable: minimum).canStack)
    }
}
