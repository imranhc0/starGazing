import XCTest
@testable import StarGazing

final class ModelsTests: XCTestCase {

    func testStackRequestRejectsFewerThanFiveFrames() {
        XCTAssertThrowsError(try StackRequest.validated(frames: fixtureFrames(count: 4), mode: .mean))
    }

    func testStackRequestAcceptsTwoHundredFrames() throws {
        XCTAssertNoThrow(try StackRequest.validated(frames: fixtureFrames(count: 200), mode: .mean))
    }

    func testStackRequestRejectsTwoHundredOneFrames() {
        XCTAssertThrowsError(try StackRequest.validated(frames: fixtureFrames(count: 201), mode: .mean))
    }

    private func fixtureFrames(count: Int) -> [Frame] {
        (0..<count).map { index in
            Frame(
                id: UUID(),
                assetID: "asset-\(index)",
                width: 4032,
                height: 3024,
                isRAW: true,
                exposureSeconds: 15,
                iso: 1600
            )
        }
    }
}
