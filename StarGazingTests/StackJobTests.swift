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

    func testFrameWithNoStarsIsSkippedAndRunContinues() async throws {
        let fixture = try makeFixture(frameCount: 6, cloudy: [2])
        let result = try await makeJob(fixture, store: "a").run()

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[fixture.request.frames[2].id], .noStars)
        XCTAssertEqual(result.usedFrameIDs.count, 5)
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

    func testProgressReportsEveryFrame() async throws {
        let fixture = try makeFixture(frameCount: 5)
        let recorder = ProgressRecorder()
        _ = try await makeJob(fixture, store: "a").run { recorder.record($0) }

        XCTAssertEqual(recorder.framesDone, [1, 2, 3, 4, 5])
    }

    // MARK: - Fixtures

    private struct Fixture {
        let request: StackRequest
        let source: FakeFrameSource
    }

    private func makeJob(_ fixture: Fixture, store: String, output: String = "out") -> StackJob {
        StackJob(
            request: fixture.request,
            source: fixture.source,
            store: CheckpointStore(directory: directory.appendingPathComponent(store)),
            outputDirectory: directory.appendingPathComponent(output)
        )
    }

    /// Frames of the same 25-star field, each shifted a few pixels. `cloudy` frames are blank;
    /// `missing` frames are absent from the source.
    private func makeFixture(
        frameCount: Int,
        mode: StackMode = .mean,
        cloudy: Set<Int> = [],
        missing: Set<Int> = []
    ) throws -> Fixture {
        var data: [UUID: Data] = [:]
        var frames: [Frame] = []
        for index in 0..<frameCount {
            let frame = Frame(
                id: UUID(), assetID: "asset-\(index)", width: 200, height: 150,
                isRAW: false, exposureSeconds: 10, iso: 1600
            )
            frames.append(frame)
            if !missing.contains(index) {
                data[frame.id] = Self.starFieldPNG(
                    dx: (index * 3) % 7 - 3,
                    dy: (index * 2) % 5 - 2,
                    blank: cloudy.contains(index)
                )
            }
        }
        return Fixture(
            request: try StackRequest.validated(frames: frames, mode: mode),
            source: FakeFrameSource(data: data)
        )
    }

    private static func starFieldPNG(dx: Int, dy: Int, blank: Bool) -> Data {
        let gray = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
            space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 150))

        if !blank {
            let gradient = CGGradient(
                colorSpace: gray, colorComponents: [1, 1, 0, 1], locations: [0, 1], count: 2
            )!
            var seed: UInt64 = 99
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 11) / Double(1 << 53)
            }
            for _ in 0..<25 {
                let center = CGPoint(x: 30 + next() * 140 + Double(dx), y: 30 + next() * 90 + Double(dy))
                context.drawRadialGradient(
                    gradient, startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: 5, options: []
                )
            }
        }

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
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
        private var done: [Int] = []

        func record(_ progress: JobProgress) {
            lock.lock()
            done.append(progress.framesDone)
            lock.unlock()
        }

        var framesDone: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return done
        }
    }
}
