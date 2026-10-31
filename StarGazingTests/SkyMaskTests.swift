import XCTest
import CoreImage
import CoreGraphics
@testable import StarGazing

/// All coordinates are Core Image space: origin bottom-left, so "sky" (the top of the picture) has large y.
final class SkyMaskTests: XCTestCase {

    func testAutomaticMaskSeparatesSkyFromDarkForeground() {
        let mask = SkyMasker.automaticMask(for: horizonImage(width: 200, height: 600, horizonY: 300))

        XCTAssertGreaterThan(mask.value(atX: 50, y: 500), 0.9)
        XCTAssertLessThan(mask.value(atX: 50, y: 100), 0.1)
    }

    func testFrameWithoutForegroundIsAllSky() {
        let mask = SkyMasker.automaticMask(for: uniformImage(width: 200, height: 600, gray: 0.1))

        XCTAssertGreaterThan(mask.value(atX: 50, y: 20), 0.9)
        XCTAssertGreaterThan(mask.value(atX: 50, y: 580), 0.9)
    }

    func testPaintingForegroundOverridesAutomaticSky() {
        let mask = SkyMasker.automaticMask(for: horizonImage(width: 200, height: 600, horizonY: 300))
            .painting([CGPoint(x: 50, y: 500)], radius: 20, sky: false)

        XCTAssertLessThan(mask.value(atX: 50, y: 500), 0.1)
    }

    func testPaintingSkyOverridesAutomaticForeground() {
        let mask = SkyMasker.automaticMask(for: horizonImage(width: 200, height: 600, horizonY: 300))
            .painting([CGPoint(x: 50, y: 100)], radius: 20, sky: true)

        XCTAssertGreaterThan(mask.value(atX: 50, y: 100), 0.9)
    }

    func testPaintingLeavesDistantPixelsUntouched() {
        let original = SkyMasker.automaticMask(for: horizonImage(width: 200, height: 600, horizonY: 300))
        let painted = original.painting([CGPoint(x: 50, y: 500)], radius: 20, sky: false)

        XCTAssertEqual(painted.value(atX: 150, y: 500), original.value(atX: 150, y: 500), accuracy: 0.001)
    }

    func testCIImageCoversTheFullFrame() {
        let mask = SkyMasker.automaticMask(for: horizonImage(width: 200, height: 600, horizonY: 300))

        XCTAssertEqual(mask.ciImage().extent, CGRect(x: 0, y: 0, width: 200, height: 600))
    }

    // MARK: - Helpers

    /// Brighter sky above `horizonY`, darker foreground below it.
    private func horizonImage(width: Int, height: Int, horizonY: Int) -> CIImage {
        let gray = CGColorSpaceCreateDeviceGray()
        let context = grayContext(width: width, height: height)
        context.setFillColor(gray: 0.01, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: horizonY))
        context.setFillColor(gray: 0.08, alpha: 1)
        context.fill(CGRect(x: 0, y: horizonY, width: width, height: height - horizonY))
        _ = gray
        return CIImage(cgImage: context.makeImage()!)
    }

    private func uniformImage(width: Int, height: Int, gray: CGFloat) -> CIImage {
        let context = grayContext(width: width, height: height)
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return CIImage(cgImage: context.makeImage()!)
    }

    private func grayContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
    }
}
