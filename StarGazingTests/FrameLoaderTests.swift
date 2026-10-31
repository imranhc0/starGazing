import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import StarGazing

final class FrameLoaderTests: XCTestCase {

    func testMixedRawAndJpegIsRejected() {
        XCTAssertThrowsError(try FrameLoader.validate([frame(isRAW: true), frame(isRAW: false)]))
    }

    func testMixedSizesAreRejected() {
        XCTAssertThrowsError(try FrameLoader.validate([
            frame(width: 4000, height: 3000),
            frame(width: 4032, height: 3024),
        ]))
    }

    func testRawOnlyBatchIsSixteenBit() throws {
        XCTAssertEqual(try FrameLoader.validate([frame(isRAW: true), frame(isRAW: true)]), .raw)
    }

    func testJpegBatchIsEightBit() throws {
        XCTAssertEqual(try FrameLoader.validate([frame(isRAW: false), frame(isRAW: false)]), .lossy)
    }

    func testOrientationIsNormalizedToUpright() async throws {
        // Stored 40x20 with EXIF orientation 6 (rotate 90°) displays as 20x40.
        let rotated = makeJPEG(width: 40, height: 20, orientation: 6)
        let upright = makeJPEG(width: 20, height: 40, orientation: 1)
        let source = FakeFrameSource(data: [rotated.id: rotated.data, upright.id: upright.data])

        let batch = try await FrameLoader.load(
            [frame(id: rotated.id, isRAW: false), frame(id: upright.id, isRAW: false)],
            source: source
        )

        XCTAssertEqual(batch.frames.count, 2)
        XCTAssertEqual(batch.frames[0].linear.extent.size, batch.frames[1].linear.extent.size)
    }

    func testUnreadableFrameIsReportedNotFatal() async throws {
        let good = makeJPEG(width: 20, height: 40, orientation: 1)
        let missingID = UUID()
        let source = FakeFrameSource(data: [good.id: good.data])

        let batch = try await FrameLoader.load(
            [frame(id: good.id, isRAW: false), frame(id: missingID, isRAW: false)],
            source: source
        )

        XCTAssertEqual(batch.frames.count, 1)
        XCTAssertNotNil(batch.unreadable[missingID])
    }

    // MARK: - Helpers

    private func frame(
        id: UUID = UUID(),
        isRAW: Bool = true,
        width: Int = 4032,
        height: Int = 3024
    ) -> Frame {
        Frame(
            id: id,
            assetID: id.uuidString,
            width: width,
            height: height,
            isRAW: isRAW,
            exposureSeconds: 15,
            iso: 1600
        )
    }

    private struct FakeFrameSource: FrameSource {
        let data: [UUID: Data]

        func data(for frameID: UUID) async throws -> Data {
            guard let bytes = data[frameID] else {
                throw FrameFailure.unreadable("missing \(frameID)")
            }
            return bytes
        }
    }

    private func makeJPEG(width: Int, height: Int, orientation: Int) -> (id: UUID, data: Data) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        CGImageDestinationFinalize(destination)
        return (UUID(), output as Data)
    }
}
