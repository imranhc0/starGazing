import XCTest
import CoreImage
import CoreGraphics
@testable import StarGazing

final class StarAlignmentTests: XCTestCase {

    // MARK: - Detection

    func testDetectsSyntheticStarsWithinHalfPixel() {
        let points: [(Double, Double)] = [(100, 100), (400, 220), (250, 330)]
        let stars = StarDetector.detect(in: syntheticField(points: points, size: 500))

        XCTAssertEqual(stars.count, 3)
        let sorted = stars.sorted { $0.x < $1.x }
        let expected = points.sorted { $0.0 < $1.0 }
        for (found, want) in zip(sorted, expected) {
            XCTAssertEqual(found.x, want.0, accuracy: 0.5)
            XCTAssertEqual(found.y, want.1, accuracy: 0.5)
        }
    }

    func testEmptySkyReportsNoStars() {
        XCTAssertTrue(StarDetector.detect(in: syntheticField(points: [], size: 500)).isEmpty)
    }

    // MARK: - Alignment

    func testRecoversTranslationWithinTenthOfPixel() throws {
        let reference = field()
        let t = try StarAligner.transform(from: reference, to: shifted(reference, dx: 12.4, dy: -7.1))
        XCTAssertEqual(t.tx, 12.4, accuracy: 0.1)
        XCTAssertEqual(t.ty, -7.1, accuracy: 0.1)
    }

    func testRecoversSmallRotation() throws {
        let t = try StarAligner.transform(from: rotated(field(), degrees: 0.3), to: field())
        XCTAssertEqual(atan2(t.b, t.a) * 180 / .pi, -0.3, accuracy: 0.02)
    }

    func testFrameWithTooFewStarsReportsFailure() {
        XCTAssertThrowsError(try StarAligner.transform(from: cloudyField(), to: field())) { error in
            XCTAssertEqual(error as? FrameFailure, .tooFewStars(found: 2))
        }
    }

    // MARK: - Helpers

    /// Deterministic star field: 40 points in a 1000x1000 area.
    private func field() -> [StarCentroid] {
        var seed: UInt64 = 42
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<40).map { i in
            StarCentroid(x: next() * 1000, y: next() * 1000, flux: 1 + Double(i % 7))
        }
    }

    private func shifted(_ stars: [StarCentroid], dx: Double, dy: Double) -> [StarCentroid] {
        stars.map { StarCentroid(x: $0.x + dx, y: $0.y + dy, flux: $0.flux) }
    }

    private func rotated(_ stars: [StarCentroid], degrees: Double) -> [StarCentroid] {
        let r = degrees * .pi / 180
        return stars.map { star in
            StarCentroid(
                x: star.x * cos(r) - star.y * sin(r),
                y: star.x * sin(r) + star.y * cos(r),
                flux: star.flux
            )
        }
    }

    private func cloudyField() -> [StarCentroid] {
        [StarCentroid(x: 10, y: 10, flux: 1), StarCentroid(x: 500, y: 300, flux: 1)]
    }

    /// Renders soft white stars on black, so centroids have real sub-pixel information.
    private func syntheticField(points: [(Double, Double)], size: Int) -> CIImage {
        let gray = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: gray,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let gradient = CGGradient(
            colorSpace: gray,
            colorComponents: [1, 0],
            locations: [0, 1],
            count: 2
        )!
        for (x, y) in points {
            // CGContext's origin is bottom-left; the detector reads top-left coordinates
            // from CIImage, which uses the same bottom-left origin, so no flip is needed here.
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: x, y: y),
                startRadius: 0,
                endCenter: CGPoint(x: x, y: y),
                endRadius: 6,
                options: []
            )
        }
        return CIImage(cgImage: context.makeImage()!)
    }
}
