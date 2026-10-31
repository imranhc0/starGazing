import XCTest
@testable import StarGazing

@MainActor
final class StackViewModelTests: XCTestCase {

    private let outputURL = URL(fileURLWithPath: "/tmp/result.jpg")

    private func frames(_ count: Int) -> [Frame] {
        (0..<count).map {
            Frame(id: UUID(), assetID: "asset-\($0)", width: 4000, height: 3000,
                  isRAW: false, exposureSeconds: 10, iso: 1600)
        }
    }

    private func makeResult(failures: [UUID: FrameFailure] = [:]) -> StackResult {
        StackResult(outputURL: outputURL, usedFrameIDs: [], failures: failures)
    }

    func testStartShowsRunningThenDone() async throws {
        let result = makeResult()
        let runner = GatedRunner(result: result)
        let model = StackViewModel(runner: runner, photos: FakePhotos(failing: false))

        let run = Task { await model.start(frames: frames(5), mode: .mean) }
        try await waitUntil { model.phase == .running(JobProgress(framesDone: 0, framesTotal: 5, currentFailure: nil)) }

        runner.release()
        await run.value

        XCTAssertEqual(model.phase, .done(result))
    }

    func testFailedRunShowsAMessageThatNamesTheCount() async {
        let model = StackViewModel(
            runner: ThrowingRunner(error: JobError.tooFewUsableFrames(usable: 4)),
            photos: FakePhotos(failing: false)
        )
        await model.start(frames: frames(5), mode: .mean)

        guard case .failed(let message) = model.phase else { return XCTFail("expected failed") }
        XCTAssertTrue(message.contains("4"), message)
    }

    func testTooFewFramesFailsWithoutRunning() async {
        let runner = ThrowingRunner(error: JobError.noOverlap)
        let model = StackViewModel(runner: runner, photos: FakePhotos(failing: false))
        await model.start(frames: frames(3), mode: .mean)

        guard case .failed = model.phase else { return XCTFail("expected failed") }
        XCTAssertEqual(runner.callCount, 0)
    }

    func testSaveFailureKeepsResultForRetry() async throws {
        let result = makeResult()
        let photos = FakePhotos(failing: true)
        let model = StackViewModel(runner: ImmediateRunner(result: result), photos: photos)
        await model.start(frames: frames(5), mode: .mean)

        do {
            try await model.saveToPhotos()
            XCTFail("expected the save to fail")
        } catch {}

        XCTAssertEqual(model.phase, .done(result))
        XCTAssertNotNil(model.saveError)
        XCTAssertFalse(model.saved)

        photos.failing = false
        try await model.saveToPhotos()
        XCTAssertTrue(model.saved)
        XCTAssertNil(model.saveError)
    }

    func testStartRemembersTheFirstPhotoForTheBeforeImage() async {
        let picked = frames(5)
        let model = StackViewModel(runner: ImmediateRunner(result: makeResult()), photos: FakePhotos(failing: false))
        XCTAssertNil(model.beforeAssetID)

        await model.start(frames: picked, mode: .mean)

        XCTAssertEqual(model.beforeAssetID, picked[0].assetID)
    }

    func testResetReturnsToPicking() async {
        let model = StackViewModel(runner: ImmediateRunner(result: makeResult()), photos: FakePhotos(failing: false))
        await model.start(frames: frames(5), mode: .mean)
        model.reset()

        XCTAssertEqual(model.phase, .picking)
    }

    // MARK: - Fakes

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never became true")
    }

    private final class GatedRunner: StackRunner, @unchecked Sendable {
        let result: StackResult
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        init(result: StackResult) { self.result = result }

        func run(_ request: StackRequest, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> StackResult {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
            return result
        }

        func release() {
            lock.lock()
            released = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    private final class ImmediateRunner: StackRunner, @unchecked Sendable {
        let result: StackResult
        init(result: StackResult) { self.result = result }
        func run(_ request: StackRequest, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> StackResult {
            result
        }
    }

    private final class ThrowingRunner: StackRunner, @unchecked Sendable {
        let error: Error
        private let lock = NSLock()
        private var calls = 0
        init(error: Error) { self.error = error }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        func run(_ request: StackRequest, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> StackResult {
            lock.lock()
            calls += 1
            lock.unlock()
            throw error
        }
    }

    private final class FakePhotos: PhotosWriter, @unchecked Sendable {
        var failing: Bool
        init(failing: Bool) { self.failing = failing }
        func save(imageAt url: URL) async throws {
            if failing { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"]) }
        }
    }
}
