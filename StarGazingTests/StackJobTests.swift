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

    func testMissingSavedStarsForACompletedFrameAreRedetected() async throws {
        let fixture = try makeFixture(frameCount: 5)
        let store = CheckpointStore(directory: directory.appendingPathComponent("a"))

        do {
            _ = try await makeJob(fixture, store: "a").run(stopAfterFrames: 3)
        } catch is JobError {}
        // Lose one frame's saved stars, as a partly written file would.
        let lost = try XCTUnwrap(store.load(jobID: fixture.request.id)?.completedFrameIDs.first)
        try FileManager.default.removeItem(at: store.starsURL(for: lost, jobID: fixture.request.id))

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
    }

    private enum Kind {
        case full, sparse, blank
    }

    private func makeJob(_ fixture: Fixture, store: String, output: String = "out") -> StackJob {
        StackJob(
            request: fixture.request,
            source: fixture.source,
            store: CheckpointStore(directory: directory.appendingPathComponent(store)),
            outputDirectory: directory.appendingPathComponent(output)
        )
    }

    /// Frames of the same 25-star field, each shifted a few pixels. `cloudy` frames are blank,
    /// `sparse` frames hold five unrelated stars, and `missing` frames are absent from the source.
    /// With `orientationTags` the frames are JPEGs carrying those EXIF tags.
    private func makeFixture(
        frameCount: Int,
        mode: StackMode = .mean,
        cloudy: Set<Int> = [],
        sparse: Set<Int> = [],
        missing: Set<Int> = [],
        orientationTags: [Int]? = nil
    ) throws -> Fixture {
        var data: [UUID: Data] = [:]
        var frames: [Frame] = []
        for index in 0..<frameCount {
            // Photos reports display-oriented sizes, so a rotated tag swaps width and height.
            let rotated = orientationTags.map { [5, 6, 7, 8].contains($0[index]) } ?? false
            let frame = Frame(
                id: UUID(), assetID: "asset-\(index)",
                width: rotated ? 150 : 200, height: rotated ? 200 : 150,
                isRAW: false, exposureSeconds: 10, iso: 1600
            )
            frames.append(frame)
            if !missing.contains(index) {
                let kind: Kind = cloudy.contains(index) ? .blank : (sparse.contains(index) ? .sparse : .full)
                data[frame.id] = Self.starField(
                    dx: (index * 3) % 7 - 3, dy: (index * 2) % 5 - 2,
                    kind: kind, orientationTag: orientationTags?[index]
                )
            }
        }
        return Fixture(
            request: try StackRequest.validated(frames: frames, mode: mode),
            source: FakeFrameSource(data: data)
        )
    }

    private static func starField(dx: Int, dy: Int, kind: Kind, orientationTag: Int?) -> Data {
        let gray = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
            space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 150))

        if kind != .blank {
            let gradient = CGGradient(
                colorSpace: gray, colorComponents: [1, 1, 0, 1], locations: [0, 1], count: 2
            )!
            var seed: UInt64 = kind == .full ? 99 : 4242
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 11) / Double(1 << 53)
            }
            for _ in 0..<(kind == .full ? 25 : 5) {
                let center = CGPoint(x: 30 + next() * 140 + Double(dx), y: 30 + next() * 90 + Double(dy))
                context.drawRadialGradient(
                    gradient, startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: 5, options: []
                )
            }
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

    private func pixelSize(of url: URL) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return CGSize(width: width, height: height)
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
