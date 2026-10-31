import XCTest
import CoreImage
@testable import StarGazing

final class DenseAlignerTests: XCTestCase {

    // MARK: - Recovering known motion

    func testRecoversAShiftAndASmallRotation() throws {
        let reference = texture(width: 800, height: 600, seed: 3)
        let motion = rotation(degrees: 0.8, aboutX: 400, y: 300).concatenating(CGAffineTransform(translationX: 13.4, y: -8.2))
        let frame = shifted(reference, by: motion)

        let found = try XCTUnwrap(DenseAligner.transform(from: frame, to: reference))

        assertMaps(found, equals: motion.inverted(), within: 0.3)
    }

    func testRecoversAPureShift() throws {
        let reference = texture(width: 800, height: 600, seed: 4)
        let motion = CGAffineTransform(translationX: 20, y: 15)
        let frame = shifted(reference, by: motion)

        let found = try XCTUnwrap(DenseAligner.transform(from: frame, to: reference))

        assertMaps(found, equals: motion.inverted(), within: 0.3)
    }

    func testAnIdenticalPictureNeedsNoMotion() throws {
        let reference = texture(width: 800, height: 600, seed: 5)

        let found = try XCTUnwrap(DenseAligner.transform(from: reference, to: reference))

        assertMaps(found, equals: .identity, within: 0.1)
    }

    func testIgnoresSomethingThatMovedOnItsOwn() throws {
        // A bright block sits in a different place in the two pictures, as a passing car would.
        let base = texture(width: 800, height: 600, seed: 6)
        let motion = CGAffineTransform(translationX: 11, y: -6)
        let reference = block(at: CGRect(x: 300, y: 250, width: 120, height: 120)).composited(over: base)
            .cropped(to: base.extent)
        let frame = block(at: CGRect(x: 380, y: 300, width: 120, height: 120))
            .composited(over: shifted(base, by: motion))
            .cropped(to: base.extent)

        let found = try XCTUnwrap(DenseAligner.transform(from: frame, to: reference))

        assertMaps(found, equals: motion.inverted(), within: 0.6)
    }

    func testWorksOnALargeFrameAndScalesTheMotionBack() throws {
        // Larger than the working size, so the picture is reduced and the answer scaled back up.
        let reference = texture(width: 3200, height: 2400, seed: 7)
        let motion = CGAffineTransform(translationX: 37, y: -21)
        let frame = shifted(reference, by: motion)

        let found = try XCTUnwrap(DenseAligner.transform(from: frame, to: reference))

        assertMaps(found, equals: motion.inverted(), within: 0.7)
    }

    func testCanBeLimitedToTheGroundOnly() throws {
        // The top of the picture moves by one amount (sky), the bottom by another (ground).
        let base = texture(width: 800, height: 600, seed: 8)
        let skyMotion = CGAffineTransform(translationX: 25, y: 0)
        let groundMotion = CGAffineTransform(translationX: -9, y: 6)
        let sky = base.transformed(by: skyMotion).cropped(to: CGRect(x: 0, y: 300, width: 800, height: 300))
        let ground = base.transformed(by: groundMotion).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 300))
        let frame = filled(sky.composited(over: ground), extent: base.extent)

        let found = try XCTUnwrap(
            DenseAligner.transform(from: frame, to: base, region: CGRect(x: 0, y: 0, width: 1, height: 0.45))
        )

        assertMaps(found, equals: groundMotion.inverted(), within: 0.7, atPoints: [CGPoint(x: 200, y: 100), CGPoint(x: 600, y: 200)])
    }

    // MARK: - Refusing

    func testRefusesPicturesThatShareNothing() {
        let one = texture(width: 800, height: 600, seed: 9)
        let another = texture(width: 800, height: 600, seed: 10)

        XCTAssertNil(DenseAligner.transform(from: another, to: one))
    }

    // MARK: - Helpers

    private func assertMaps(
        _ found: AlignmentTransform,
        equals expected: CGAffineTransform,
        within tolerance: Double,
        atPoints points: [CGPoint] = [CGPoint(x: 100, y: 100), CGPoint(x: 700, y: 500), CGPoint(x: 400, y: 300)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for point in points {
            let got = found.apply(x: Double(point.x), y: Double(point.y))
            let want = point.applying(expected)
            XCTAssertEqual(got.x, Double(want.x), accuracy: tolerance, "x at \(point)", file: file, line: line)
            XCTAssertEqual(got.y, Double(want.y), accuracy: tolerance, "y at \(point)", file: file, line: line)
        }
    }

    private func rotation(degrees: Double, aboutX x: Double, y: Double) -> CGAffineTransform {
        CGAffineTransform(translationX: CGFloat(-x), y: CGFloat(-y))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(degrees * .pi / 180)))
            .concatenating(CGAffineTransform(translationX: CGFloat(x), y: CGFloat(y)))
    }

    /// A busy picture of soft blobs, with detail at every scale, like a skyline or a street.
    private func texture(width: Int, height: Int, seed: UInt64) -> CIImage {
        var state = seed &* 2654435761 &+ 1
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
        var luminance = [Float](repeating: 0.25, count: width * height)
        let blobs = width * height / 190
        for _ in 0..<blobs {
            let cx = Int(next() * Float(width)), cy = Int(next() * Float(height))
            let radius = 2 + Int(next() * 10)
            let value = 0.05 + next() * 0.9
            for y in max(0, cy - radius)..<min(height, cy + radius) {
                for x in max(0, cx - radius)..<min(width, cx + radius) {
                    let dx = x - cx, dy = y - cy
                    if dx * dx + dy * dy <= radius * radius { luminance[y * width + x] = value }
                }
            }
        }
        var floats = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            floats[i * 4] = luminance[i]
            floats[i * 4 + 1] = luminance[i]
            floats[i * 4 + 2] = luminance[i]
        }
        return TestImages.bitmap(floats, width: width, height: height).samplingLinear()
    }

    private func block(at rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect)
    }

    /// The picture moved by `motion` but still the same size, the way a real burst frame is: what
    /// the move uncovers at the edges is filled with plain grey.
    private func shifted(_ image: CIImage, by motion: CGAffineTransform) -> CIImage {
        filled(image.transformed(by: motion), extent: image.extent)
    }

    private func filled(_ image: CIImage, extent: CGRect) -> CIImage {
        image.composited(over: CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25)).cropped(to: extent))
            .cropped(to: extent)
    }
}
