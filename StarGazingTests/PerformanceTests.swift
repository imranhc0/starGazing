import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
@testable import StarGazing

/// Run on a physical iPhone 12 Pro: the simulator runs on Mac hardware, so its timings say
/// nothing about the A14. The target is about 2 minutes for 100 frames.
///
/// These frames are 12 megapixels of synthetic stars. Real 48 megapixel RAW frames cost far more
/// to decode and hold in memory, so passing here does not clear that case.
final class PerformanceTests: XCTestCase {

    func testHundredTwelveMegapixelFramesFinishWithinTarget() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Performance targets are for a physical iPhone 12 Pro, not the simulator.")
        #else
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Five distinct shifted frames, reused, so building the fixture does not dominate the timing.
        let variants = (0..<5).map { Self.starFieldPNG(dx: $0 * 3 - 6, dy: $0 * 2 - 4) }
        var data: [UUID: Data] = [:]
        var frames: [Frame] = []
        for index in 0..<100 {
            let frame = Frame(
                id: UUID(), assetID: "perf-\(index)", width: 4032, height: 3024,
                isRAW: false, exposureSeconds: 10, iso: 1600
            )
            frames.append(frame)
            data[frame.id] = variants[index % variants.count]
        }

        let request = try StackRequest.validated(frames: frames, mode: .mean)
        let job = StackJob(
            request: request,
            source: FixedSource(data: data),
            store: CheckpointStore(directory: directory.appendingPathComponent("checkpoints")),
            outputDirectory: directory.appendingPathComponent("out")
        )

        let memoryBefore = os_proc_available_memory()
        let start = Date()
        let result = try await job.run()
        let elapsed = Date().timeIntervalSince(start)
        let memoryAfter = os_proc_available_memory()

        add(XCTAttachment(string: """
            frames: 100 at 4032x3024
            elapsed: \(String(format: "%.1f", elapsed)) s (target 120 s)
            available memory before: \(memoryBefore / 1_048_576) MB, after: \(memoryAfter / 1_048_576) MB
            used: \(result.usedFrameIDs.count), skipped: \(result.failures.count)
            """))

        XCTAssertEqual(result.usedFrameIDs.count, 100)
        XCTAssertLessThan(elapsed, 120)
        #endif
    }

    #if !targetEnvironment(simulator)
    private struct FixedSource: FrameSource {
        let data: [UUID: Data]

        func data(for frameID: UUID) async throws -> Data {
            guard let bytes = data[frameID] else { throw FrameFailure.unreadable("missing") }
            return bytes
        }
    }

    private static func starFieldPNG(dx: Int, dy: Int) -> Data {
        let width = 4032
        let height = 3024
        let gray = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let gradient = CGGradient(colorSpace: gray, colorComponents: [1, 1, 0, 1], locations: [0, 1], count: 2)!
        var seed: UInt64 = 5
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for _ in 0..<400 {
            let center = CGPoint(x: 100 + next() * 3800 + Double(dx), y: 100 + next() * 2800 + Double(dy))
            context.drawRadialGradient(
                gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 7, options: []
            )
        }

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
    #endif
}
