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

    func testFramesStayInSensorOrientationAndReportTheirTag() async throws {
        // A phone on a tripod pointing at the sky writes the same sensor data every time, but the
        // orientation tag can flip between shots. Frames must not be rotated by their own tag.
        let tagged = makeJPEG(width: 40, height: 20, orientation: 6)
        let other = makeJPEG(width: 40, height: 20, orientation: 1)
        let source = FakeFrameSource(data: [tagged.id: tagged.data, other.id: other.data])

        let batch = try await FrameLoader.load(
            [frame(id: tagged.id, isRAW: false), frame(id: other.id, isRAW: false)],
            source: source
        )

        XCTAssertEqual(batch.frames.count, 2)
        XCTAssertEqual(batch.frames[0].linear.extent.size, CGSize(width: 40, height: 20))
        XCTAssertEqual(batch.frames[1].linear.extent.size, CGSize(width: 40, height: 20))
        XCTAssertEqual(batch.frames[0].orientation, .right)
        XCTAssertEqual(batch.frames[1].orientation, .up)
    }

    func testBatchSizeComesFromTheDecodedPixelsNotPhotosMetadata() async throws {
        // Photos reports display-oriented sizes (20x40 here); the decoded sensor data is 40x20.
        let shot = makeJPEG(width: 40, height: 20, orientation: 6)
        let batch = try await FrameLoader.load(
            [frame(id: shot.id, isRAW: false, width: 20, height: 40)],
            source: FakeFrameSource(data: [shot.id: shot.data])
        )

        XCTAssertEqual(batch.width, 40)
        XCTAssertEqual(batch.height, 20)
    }

    func testSizesAreComparedIgnoringOrientation() throws {
        XCTAssertNoThrow(try FrameLoader.validate([
            frame(isRAW: false, width: 4032, height: 3024),
            frame(isRAW: false, width: 3024, height: 4032),
        ]))
    }

    func testJpegGreyKeepsItsLinearValue() async throws {
        // sRGB 0.5 grey is 0.2158 in linear light. Converting twice would give about 0.04.
        let grey = makeJPEG(width: 16, height: 16, orientation: 1, grey: 0.5)
        let batch = try await FrameLoader.load(
            [frame(id: grey.id, isRAW: false, width: 16, height: 16)],
            source: FakeFrameSource(data: [grey.id: grey.data])
        )

        XCTAssertEqual(TestImages.pixel(batch.frames[0].linear, 8, 8).r, 0.2158, accuracy: 0.01)
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

    private func makeJPEG(width: Int, height: Int, orientation: Int, grey: CGFloat? = nil) -> (id: UUID, data: Data) {
        // Tagged sRGB, as a phone's JPEG is. A device-RGB image would be saved with a gamma 1.8
        // profile, which Core Image rightly honours.
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        // srgbRed, because CGColor(red:green:blue:alpha:) is in the generic RGB space and would be
        // converted when it is drawn into this sRGB image.
        if let grey {
            context.setFillColor(CGColor(srgbRed: grey, green: grey, blue: grey, alpha: 1))
        } else {
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.6, alpha: 1))
        }
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
