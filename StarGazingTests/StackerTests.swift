import XCTest
import CoreImage
@testable import StarGazing

final class StackerTests: XCTestCase {

    private let size = 32
    private var fullTile: TileRect { .full(of: CGRect(x: 0, y: 0, width: size, height: size)) }

    func testMeanOfConstantFramesIsTheConstant() throws {
        let out = try Stacker().stack(constantFrames([0.2, 0.2, 0.2]), mode: .mean, tile: fullTile)
        XCTAssertEqual(pixel(out, 0, 0).r, 0.2, accuracy: 1e-4)
    }

    func testSigmaClipRemovesBrightSatelliteFromFiveFrames() throws {
        let out = try Stacker().stack(constantFrames([0.2, 0.2, 0.2, 0.2, 0.95]), mode: .mean, tile: fullTile)
        XCTAssertEqual(pixel(out, 10, 10).r, 0.2, accuracy: 0.01)
    }

    func testMedianRemovesOutlier() throws {
        let out = try Stacker().stack(constantFrames([0.2, 0.21, 0.2, 0.19, 0.95]), mode: .median, tile: fullTile)
        XCTAssertEqual(pixel(out, 10, 10).r, 0.2, accuracy: 0.02)
    }

    func testTrailsKeepMaximumPerPixel() throws {
        let out = try Stacker().stack(constantFrames([0.1, 0.9, 0.3]), mode: .trails, tile: fullTile)
        XCTAssertEqual(pixel(out, 10, 10).r, 0.9, accuracy: 1e-4)
    }

    func testTiledResultMatchesWholeImage() throws {
        let frames = randomFrames(count: 5)
        let tile = TileRect.full(of: CGRect(x: 0, y: 0, width: 100, height: 100))
        let whole = try Stacker(tileSize: 10_000).stack(frames, mode: .mean, tile: tile)
        let tiled = try Stacker(tileSize: 64).stack(frames, mode: .mean, tile: tile)

        XCTAssertLessThan(maxDifference(whole, tiled, width: 100, height: 100), 1e-4)
    }

    func testTilesAreBigWhenThereAreFewPhotosAndSmallerAsTheyGrow() {
        XCTAssertEqual(Stacker.adaptiveTileSize(frameCount: 10), 1024, "few photos: big tiles, less overhead")
        XCTAssertLessThanOrEqual(Stacker.adaptiveTileSize(frameCount: 100), 384)
        XCTAssertGreaterThanOrEqual(Stacker.adaptiveTileSize(frameCount: 200), 128)
        // The working memory of a tile (every photo's tile at 16 bytes a pixel) stays bounded.
        for frames in [5, 10, 30, 100, 200] {
            let size = Stacker.adaptiveTileSize(frameCount: frames)
            XCTAssertLessThanOrEqual(frames * size * size * 16, 260_000_000, "\(frames) photos at \(size)")
        }
    }

    func testStackReportsProgressAfterEachChunk() throws {
        var seen: [Double] = []
        let tile = TileRect.full(of: CGRect(x: 0, y: 0, width: 100, height: 100))
        _ = try Stacker(tileSize: 64).stack(randomFrames(count: 3), mode: .mean, tile: tile) { seen.append($0) }

        // 100x100 in 64-pixel chunks is four chunks.
        XCTAssertEqual(seen, [0.25, 0.5, 0.75, 1.0])
    }

    func testStackStopsWhenTheTaskIsCancelled() async {
        let frames = constantFrames([0.2, 0.2, 0.2])
        let tile = fullTile
        let task = Task { () throws -> CIImage in
            // Wait for the cancellation, so the stack starts from a cancelled task.
            while !Task.isCancelled { await Task.yield() }
            return try Stacker().stack(frames, mode: .mean, tile: tile)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected the stack to stop")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTransformMapsEachFrameOntoTheReference() throws {
        // A star at (10,10) in frame A and at (15,12) in frame B. B's transform maps B onto A's grid.
        let a = AlignedFrame(linear: image(dots: [(10, 10, 1)]), transform: AlignmentTransform(a: 1, b: 0, tx: 0, ty: 0))
        let b = AlignedFrame(
            linear: image(dots: [(15, 12, 1)]),
            transform: AlignmentTransform(a: 1, b: 0, tx: -5, ty: -2)
        )
        let out = try Stacker().stack([a, b], mode: .mean, tile: fullTile)

        XCTAssertEqual(pixel(out, 10, 10).r, 1.0, accuracy: 1e-3)
    }

    func testPixelsMissingFromOneFrameUseTheOthers() throws {
        // B is shifted left by 5, so it has no data in the rightmost 5 columns; A's value must survive.
        let a = AlignedFrame(linear: image(fill: 0.4), transform: AlignmentTransform(a: 1, b: 0, tx: 0, ty: 0))
        let b = AlignedFrame(linear: image(fill: 0.8), transform: AlignmentTransform(a: 1, b: 0, tx: -5, ty: 0))
        let out = try Stacker().stack([a, b], mode: .trails, tile: fullTile)

        XCTAssertEqual(pixel(out, 30, 5).r, 0.4, accuracy: 1e-3)
        XCTAssertEqual(pixel(out, 10, 5).r, 0.8, accuracy: 1e-3)
    }

    // MARK: - Helpers

    private func constantFrames(_ values: [Float]) -> [AlignedFrame] {
        values.map { AlignedFrame(linear: image(fill: $0), transform: nil) }
    }

    private func randomFrames(count: Int) -> [AlignedFrame] {
        var seed: UInt64 = 7
        return (0..<count).map { _ in
            var floats = [Float]()
            for _ in 0..<(100 * 100) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let v = Float(seed >> 40) / Float(1 << 24)
                floats += [v, v, v, 1]
            }
            return AlignedFrame(linear: bitmapImage(floats, width: 100, height: 100), transform: nil)
        }
    }

    private func image(fill: Float) -> CIImage {
        bitmapImage(Array(repeating: [fill, fill, fill, 1], count: size * size).flatMap { $0 }, width: size, height: size)
    }

    /// Black image with single bright pixels at Core Image coordinates (x, y).
    private func image(dots: [(Int, Int, Float)]) -> CIImage {
        var floats = [Float](repeating: 0, count: size * size * 4)
        for pixel in 0..<(size * size) {
            floats[pixel * 4 + 3] = 1
        }
        for (x, y, value) in dots {
            let row = size - 1 - y
            let index = (row * size + x) * 4
            floats[index] = value
            floats[index + 1] = value
            floats[index + 2] = value
        }
        return bitmapImage(floats, width: size, height: size)
    }

    private func bitmapImage(_ floats: [Float], width: Int, height: Int) -> CIImage {
        CIImage(
            bitmapData: floats.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: width * 16,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: nil
        )
    }

    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> (r: Float, g: Float, b: Float, a: Float) {
        var rgba = [Float](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { buffer in
            FloatContext.make().render(
                image,
                toBitmap: buffer.baseAddress!,
                rowBytes: 16,
                bounds: CGRect(x: x, y: y, width: 1, height: 1),
                format: .RGBAf,
                colorSpace: nil
            )
        }
        return (rgba[0], rgba[1], rgba[2], rgba[3])
    }

    private func maxDifference(_ a: CIImage, _ b: CIImage, width: Int, height: Int) -> Float {
        func render(_ image: CIImage) -> [Float] {
            var floats = [Float](repeating: 0, count: width * height * 4)
            floats.withUnsafeMutableBytes { buffer in
                FloatContext.make().render(
                    image,
                    toBitmap: buffer.baseAddress!,
                    rowBytes: width * 16,
                    bounds: CGRect(x: 0, y: 0, width: width, height: height),
                    format: .RGBAf,
                    colorSpace: nil
                )
            }
            return floats
        }
        return zip(render(a), render(b)).map { abs($0 - $1) }.max() ?? 0
    }
}
