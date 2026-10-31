import XCTest
import CoreImage
import CoreGraphics
@testable import StarGazing

final class FrameAnalysisTests: XCTestCase {

    func testASharpPictureScoresHigherThanABlurredOne() throws {
        let sharp = texture(width: 800, height: 600)
        let blurred = sharp.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: sharp.extent)

        let sharpScore = try XCTUnwrap(FrameAnalysis.analyse(sharp)).sharpness
        let blurredScore = try XCTUnwrap(FrameAnalysis.analyse(blurred)).sharpness

        XCTAssertGreaterThan(sharpScore, blurredScore * 1.5)
    }

    func testAFlatPictureHasNoSharpness() throws {
        let flat = TestImages.constant(0.2, width: 400, height: 300)

        XCTAssertEqual(try XCTUnwrap(FrameAnalysis.analyse(flat)).sharpness, 0, accuracy: 1e-6)
    }

    func testStarsOfALargeFrameAreReportedInFullSizeCoordinates() throws {
        // Bigger than the working size, so detection runs on a reduced copy and the positions are scaled back.
        let points: [(Double, Double)] = [(500, 400), (1500, 2500), (2800, 700), (3600, 2800), (2000, 1500), (900, 1900)]
        let analysis = try XCTUnwrap(FrameAnalysis.analyse(starField(points: points, width: 4096, height: 3072)))

        XCTAssertEqual(analysis.stars.count, points.count)
        for want in points {
            let nearest = analysis.stars.min { distance($0, want) < distance($1, want) }!
            XCTAssertLessThan(distance(nearest, want), 1.5, "star near \(want)")
        }
    }

    func testAnalysisSurvivesBeingSavedAndLoaded() throws {
        let original = FrameAnalysis(stars: [StarCentroid(x: 10.5, y: 20.25, flux: 3)], sharpness: 0.75)
        let data = try JSONEncoder().encode(original)

        XCTAssertEqual(try JSONDecoder().decode(FrameAnalysis.self, from: data), original)
    }

    // MARK: - Helpers

    private func distance(_ star: StarCentroid, _ point: (Double, Double)) -> Double {
        ((star.x - point.0) * (star.x - point.0) + (star.y - point.1) * (star.y - point.1)).squareRoot()
    }

    private func texture(width: Int, height: Int) -> CIImage {
        var state: UInt64 = 99
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
        var floats = [Float](repeating: 1, count: width * height * 4)
        var luminance = [Float](repeating: 0.25, count: width * height)
        for _ in 0..<(width * height / 190) {
            let cx = Int(next() * Float(width)), cy = Int(next() * Float(height))
            let radius = 2 + Int(next() * 8)
            let value = 0.05 + next() * 0.9
            for y in max(0, cy - radius)..<min(height, cy + radius) {
                for x in max(0, cx - radius)..<min(width, cx + radius) {
                    if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius { luminance[y * width + x] = value }
                }
            }
        }
        for i in 0..<(width * height) {
            floats[i * 4] = luminance[i]; floats[i * 4 + 1] = luminance[i]; floats[i * 4 + 2] = luminance[i]
        }
        return TestImages.bitmap(floats, width: width, height: height)
    }

    /// Soft white stars on black, drawn at Core Image coordinates (origin bottom left).
    private func starField(points: [(Double, Double)], width: Int, height: Int) -> CIImage {
        let gray = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let gradient = CGGradient(colorSpace: gray, colorComponents: [1, 1, 0, 1], locations: [0, 1], count: 2)!
        for (x, y) in points {
            let center = CGPoint(x: x, y: y)
            context.drawRadialGradient(
                gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 16, options: []
            )
        }
        return CIImage(cgImage: context.makeImage()!)
    }
}
