import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import StarGazing

final class StackJobTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("job-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Tests

    func testRunStacksAllUsableFramesAndWritesOutput() async throws {
        let fixture = try makeFixture(frameCount: 5)
        let result = try await makeJob(fixture, store: "a").run()

        XCTAssertEqual(result.usedFrameIDs.count, 5)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
    }

    func testInterruptedRunLeavesACheckpointOfCompletedFrames() async throws {
        let fixture = try makeFixture(frameCount: 5)
        let store = CheckpointStore(directory: directory.appendingPathComponent("a"))

        do {
            _ = try await makeJob(fixture, store: "a").run(stopAfterFrames: 3)
            XCTFail("expected the run to be interrupted")
        } catch let error as JobError {
            XCTAssertEqual(error, .interrupted(framesDone: 3))
        }

        XCTAssertEqual(store.load(jobID: fixture.request.id)?.completedFrameIDs.count, 3)
    }

    func testResumeFromCheckpointMatchesUninterruptedRun() async throws {
        let fixture = try makeFixture(frameCount: 5)
        let full = try await makeJob(fixture, store: "full", output: "full").run()

        do {
            _ = try await makeJob(fixture, store: "resume", output: "resumed").run(stopAfterFrames: 3)
        } catch is JobError {}
        let resumed = try await makeJob(fixture, store: "resume", output: "resumed").run()

        XCTAssertEqual(try Data(contentsOf: full.outputURL), try Data(contentsOf: resumed.outputURL))
    }

    func testCorruptCheckpointRestartsFromZero() async throws {
        let fixture = try makeFixture(frameCount: 5)
        let store = CheckpointStore(directory: directory.appendingPathComponent("a"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{ not a checkpoint".utf8).write(to: store.fileURL(for: fixture.request.id))

        let result = try await makeJob(fixture, store: "a").run()

        XCTAssertEqual(result.usedFrameIDs.count, 5)
    }

    func testMissingSavedAnalysisForACompletedFrameIsRedone() async throws {
        let fixture = try makeFixture(frameCount: 5)
        let store = CheckpointStore(directory: directory.appendingPathComponent("a"))

        do {
            _ = try await makeJob(fixture, store: "a").run(stopAfterFrames: 3)
        } catch is JobError {}
        // Lose one frame's saved analysis, as a partly written file would.
        let lost = try XCTUnwrap(store.load(jobID: fixture.request.id)?.completedFrameIDs.first)
        try FileManager.default.removeItem(at: store.analysisURL(for: lost, jobID: fixture.request.id))

        let result = try await makeJob(fixture, store: "a").run()

        XCTAssertEqual(result.usedFrameIDs.count, 5)
    }

    func testFrameWithNoStarsIsSkippedAndRunContinues() async throws {
        let fixture = try makeFixture(frameCount: 6, cloudy: [2])
        let result = try await makeJob(fixture, store: "a").run()

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[fixture.request.frames[2].id], .noStars)
        XCTAssertEqual(result.usedFrameIDs.count, 5)
    }

    func testSparseFirstFrameDoesNotBecomeTheReference() async throws {
        // Frame 0 has five stars that match nothing else. If it were the reference, every other
        // frame would fail to align to it and the run would fail.
        let fixture = try makeFixture(frameCount: 6, sparse: [0])
        let result = try await makeJob(fixture, store: "a").run()

        XCTAssertEqual(result.usedFrameIDs.count, 5)
        XCTAssertNotNil(result.failures[fixture.request.frames[0].id])
    }

    func testFewerThanFiveUsableFramesFailsTheRun() async throws {
        let fixture = try makeFixture(frameCount: 5, cloudy: [3])

        do {
            _ = try await makeJob(fixture, store: "a").run()
            XCTFail("expected the run to fail")
        } catch let error as JobError {
            XCTAssertEqual(error, .tooFewUsableFrames(usable: 4))
        }
    }

    func testUnreadableFrameIsSkippedAndReported() async throws {
        let fixture = try makeFixture(frameCount: 6, missing: [4])
        let result = try await makeJob(fixture, store: "a").run()

        XCTAssertEqual(result.usedFrameIDs.count, 5)
        guard case .unreadable = result.failures[fixture.request.frames[4].id] else {
            return XCTFail("expected an unreadable failure")
        }
    }

    func testTrailsModeDoesNotNeedStarsInEveryFrame() async throws {
        let fixture = try makeFixture(frameCount: 5, mode: .trails, cloudy: [1])
        let result = try await makeJob(fixture, store: "a").run()

        XCTAssertEqual(result.usedFrameIDs.count, 5)
    }

    func testTheReferenceFramesOrientationTagOrientsTheOutput() async throws {
        // Same sensor data in every shot, but the tag flips between "right" (6) and "left" (8),
        // as it can for a phone on a tripod pointing at the sky. All frames must still align, and
        // the result is turned the way the reference frame was tagged: portrait here.
        let fixture = try makeFixture(frameCount: 5, orientationTags: [6, 8, 6, 8, 6])
        let result = try await makeJob(fixture, store: "a").run()

        XCTAssertEqual(result.usedFrameIDs.count, 5)
        let size = try pixelSize(of: result.outputURL)
        XCTAssertGreaterThan(size.height, size.width)
    }

    // MARK: - Detail: the stack must come out as crisp as one frame, not smeared

    func testAHandheldCityBurstComesOutAsSharpAsOneFrame() async throws {
        // Every frame is the same scene, moved a few pixels by the hand: the whole picture shifts.
        let fixture = try makeFixture(frameCount: 6, scene: .city)
        let result = try await makeJob(fixture, store: "a").run()

        XCTAssertEqual(result.usedFrameIDs.count, 6)
        let single = try sharpness(ofData: fixture.data(0), bottomFraction: 0.3)
        let stacked = try sharpness(ofImageAt: result.outputURL, bottomFraction: 0.3)
        XCTAssertGreaterThan(stacked, single * 0.8, "stacked \(stacked) vs one frame \(single)")
    }

    func testTheGroundOfATrackedSkyIsAlignedOnItsOwn() async throws {
        // The stars hold still (the sky is tracked) while the ground drifts. If the ground were
        // stacked as shot, or aligned on the stars, it would smear.
        let fixture = try makeFixture(frameCount: 6, scene: .trackedSky)
        let result = try await makeJob(fixture, store: "a").run()

        XCTAssertEqual(result.usedFrameIDs.count, 6)
        let single = try sharpness(ofData: fixture.data(0), bottomFraction: 0.3)
        let stacked = try sharpness(ofImageAt: result.outputURL, bottomFraction: 0.3)
        XCTAssertGreaterThan(stacked, single * 0.8, "stacked \(stacked) vs one frame \(single)")
    }

    // MARK: - Progress

    func testProgressReportsEveryFrame() async throws {
        let fixture = try makeFixture(frameCount: 5)
        let recorder = ProgressRecorder()
        _ = try await makeJob(fixture, store: "a").run { recorder.record($0) }

        XCTAssertEqual(recorder.detectionProgress, [1, 2, 3, 4, 5])
    }

    func testStackingPhaseReportsProgressUpToOne() async throws {
        let fixture = try makeFixture(frameCount: 5)
        let recorder = ProgressRecorder()
        _ = try await makeJob(fixture, store: "a").run { recorder.record($0) }

        let fractions = recorder.stackingFractions
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertEqual(fractions.last ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(fractions, fractions.sorted(), "progress never goes backwards")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let request: StackRequest
        let source: FakeFrameSource

        func data(_ index: Int) -> Data { source.data[request.frames[index].id]! }
    }

    private enum Kind {
        case full, sparse, blank
    }

    /// What the frames show.
    private enum Scene {
        /// Stars on a black sky, the camera still; each frame's star field drifts a few pixels.
        case astro
        /// A busy city scene, no stars, the whole picture shifted by hand shake.
        case city
        /// A lit sky with fixed stars over a dark, textured ground that drifts from frame to frame.
        case trackedSky
    }

    private func makeJob(_ fixture: Fixture, store: String, output: String = "out") -> StackJob {
        StackJob(
            request: fixture.request,
            source: fixture.source,
            store: CheckpointStore(directory: directory.appendingPathComponent(store)),
            outputDirectory: directory.appendingPathComponent(output)
        )
    }

    /// Frames of one scene, each moved a few pixels. `cloudy` frames are blank, `sparse` frames hold
    /// five unrelated stars, and `missing` frames are absent from the source. With `orientationTags`
    /// the frames are JPEGs carrying those EXIF tags.
    private func makeFixture(
        frameCount: Int,
        mode: StackMode = .mean,
        scene: Scene = .astro,
        cloudy: Set<Int> = [],
        sparse: Set<Int> = [],
        missing: Set<Int> = [],
        orientationTags: [Int]? = nil
    ) throws -> Fixture {
        var data: [UUID: Data] = [:]
        var frames: [Frame] = []
        let size = scene == .astro ? (width: 200, height: 150) : (width: 400, height: 300)
        for index in 0..<frameCount {
            // Photos reports display-oriented sizes, so a rotated tag swaps width and height.
            let rotated = orientationTags.map { [5, 6, 7, 8].contains($0[index]) } ?? false
            let frame = Frame(
                id: UUID(), assetID: "asset-\(index)",
                width: rotated ? size.height : size.width, height: rotated ? size.width : size.height,
                isRAW: false, exposureSeconds: 10, iso: 1600
            )
            frames.append(frame)
            if !missing.contains(index) {
                let kind: Kind = cloudy.contains(index) ? .blank : (sparse.contains(index) ? .sparse : .full)
                let shift = (dx: (index * 3) % 7 - 3, dy: (index * 2) % 5 - 2)
                data[frame.id] = Self.frameData(
                    scene: scene, shift: shift, kind: kind, orientationTag: orientationTags?[index]
                )
            }
        }
        return Fixture(
            request: try StackRequest.validated(frames: frames, mode: mode),
            source: FakeFrameSource(data: data)
        )
    }

    private static func frameData(scene: Scene, shift: (dx: Int, dy: Int), kind: Kind, orientationTag: Int?) -> Data {
        let gray = CGColorSpaceCreateDeviceGray()
        let width = scene == .astro ? 200 : 400
        let height = scene == .astro ? 150 : 300
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!

        switch scene {
        case .astro:
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if kind != .blank {
                drawStars(into: context, seed: kind == .full ? 99 : 4242, count: kind == .full ? 25 : 5,
                          area: CGRect(x: 30, y: 30, width: 140, height: 90), shift: shift)
            }
        case .city:
            // The same busy picture every time, placed a little differently by the "hand".
            context.setFillColor(gray: 0.15, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(
                texture(width: width, height: height, seed: 11, lowest: 0.03, highest: 0.9),
                in: CGRect(x: shift.dx * 2, y: shift.dy * 2, width: width, height: height)
            )
        case .trackedSky:
            // Lit sky with stars that do not move, over a dark ground that does.
            let horizon = height * 4 / 10
            context.setFillColor(gray: 0.12, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            drawStars(into: context, seed: 99, count: 25,
                      area: CGRect(x: 20, y: CGFloat(horizon + 20), width: CGFloat(width - 40), height: CGFloat(height - horizon - 40)),
                      shift: (0, 0))
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: 0, width: width, height: horizon))
            context.setFillColor(gray: 0.04, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: horizon))
            context.draw(
                texture(width: width, height: horizon, seed: 21, lowest: 0.02, highest: 0.12),
                in: CGRect(x: shift.dx * 2, y: shift.dy * 2, width: width, height: horizon)
            )
            context.restoreGState()
        }

        let output = NSMutableData()
        let type = orientationTag == nil ? UTType.png : UTType.jpeg
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientationTag {
            properties[kCGImagePropertyOrientation] = orientationTag
            properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private static func drawStars(
        into context: CGContext, seed: UInt64, count: Int, area: CGRect, shift: (dx: Int, dy: Int)
    ) {
        let gradient = CGGradient(
            colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: [1, 1, 0, 1], locations: [0, 1], count: 2
        )!
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        for _ in 0..<count {
            let center = CGPoint(
                x: Double(area.minX) + next() * Double(area.width) + Double(shift.dx),
                y: Double(area.minY) + next() * Double(area.height) + Double(shift.dy)
            )
            context.drawRadialGradient(
                gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 5, options: []
            )
        }
    }

    /// A busy picture of blobs of different sizes and brightness, like a street or a skyline.
    private static func texture(width: Int, height: Int, seed: UInt64, lowest: Double, highest: Double) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: CGFloat((lowest + highest) / 2), alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var state = seed &* 2654435761 &+ 1
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        for _ in 0..<(width * height / 150) {
            let size = 3 + next() * 14
            context.setFillColor(gray: CGFloat(lowest + next() * (highest - lowest)), alpha: 1)
            context.fill(CGRect(x: next() * Double(width), y: next() * Double(height), width: size, height: size))
        }
        return context.makeImage()!
    }

    // MARK: - Measuring

    private func pixelSize(of url: URL) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return CGSize(width: width, height: height)
    }

    /// How crisp the bottom part of a picture is: the mean gradient divided by the spread of its
    /// brightness. Blur lowers it; a change in overall brightness or contrast does not.
    private func sharpness(ofData data: Data, bottomFraction: Double) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try sharpness(of: try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), bottomFraction: bottomFraction)
    }

    private func sharpness(ofImageAt url: URL, bottomFraction: Double) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try sharpness(of: try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), bottomFraction: bottomFraction)
    }

    private func sharpness(of image: CGImage, bottomFraction: Double) throws -> Double {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Memory rows run top-down, so the bottom of the picture is the last rows.
        let firstRow = Int(Double(height) * (1 - bottomFraction))
        var gradient = 0.0, sum = 0.0, sumSquares = 0.0, count = 0.0
        for y in firstRow..<(height - 1) {
            for x in 0..<(width - 1) {
                let value = Double(bytes[y * width + x])
                gradient += abs(Double(bytes[y * width + x + 1]) - value) + abs(Double(bytes[(y + 1) * width + x]) - value)
                sum += value
                sumSquares += value * value
                count += 1
            }
        }
        let mean = sum / count
        let deviation = max((sumSquares / count - mean * mean).squareRoot(), 1e-6)
        return (gradient / count) / deviation
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

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [JobProgress] = []

        func record(_ progress: JobProgress) {
            lock.lock()
            all.append(progress)
            lock.unlock()
        }

        private var snapshot: [JobProgress] {
            lock.lock()
            defer { lock.unlock() }
            return all
        }

        /// `framesDone` of each progress report from the detection phase.
        var detectionProgress: [Int] {
            snapshot.filter { $0.stackingFraction == nil }.map(\.framesDone)
        }

        var stackingFractions: [Double] {
            snapshot.compactMap(\.stackingFraction)
        }
    }
}
