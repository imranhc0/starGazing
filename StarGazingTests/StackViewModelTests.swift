import XCTest
@testable import StarGazing

@MainActor
final class StackViewModelTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Running

    func testStartShowsRunningThenDone() async throws {
        let result = makeResult()
        let runner = GatedRunner(result: result)
        let model = makeModel(runner: runner)

        let run = Task { await model.start(frames: frames(5), mode: .mean) }
        try await waitUntil { model.phase == .running(JobProgress(framesDone: 0, framesTotal: 5, currentFailure: nil)) }

        runner.release()
        await run.value

        XCTAssertEqual(model.phase, .done(result))
    }

    func testFailedRunShowsAMessageThatNamesTheCount() async {
        let model = makeModel(runner: ThrowingRunner(error: JobError.tooFewUsableFrames(usable: 4)))
        await model.start(frames: frames(5), mode: .mean)

        guard case .failed(let message) = model.phase else { return XCTFail("expected failed") }
        XCTAssertTrue(message.contains("4"), message)
    }

    func testTooFewFramesFailsWithoutRunning() async {
        let runner = ThrowingRunner(error: JobError.noOverlap)
        let model = makeModel(runner: runner)
        await model.start(frames: frames(3), mode: .mean)

        guard case .failed = model.phase else { return XCTFail("expected failed") }
        XCTAssertEqual(runner.callCount, 0)
    }

    func testStartRemembersTheFirstPhotoForTheBeforeImage() async {
        let picked = frames(5)
        let model = makeModel(runner: ImmediateRunner(result: makeResult()))
        XCTAssertNil(model.beforeAssetID)

        await model.start(frames: picked, mode: .mean)

        XCTAssertEqual(model.beforeAssetID, picked[0].assetID)
    }

    // MARK: - Resuming

    func testInterruptedRunCanBeResumedByANewModel() async throws {
        let stores = makeStores()
        let picked = frames(5)
        let first = StackViewModel(
            runner: InterruptingRunner(checkpoints: stores.checkpoints, framesDone: 3),
            photos: FakePhotos(failing: false), pendingStore: stores.pending, checkpoints: stores.checkpoints
        )
        await first.start(frames: picked, mode: .median)
        guard case .failed(let message) = first.phase else { return XCTFail("expected failed") }
        XCTAssertTrue(message.lowercased().contains("saved"), "the message must be true: progress is saved. \(message)")

        // The app is opened again.
        let result = makeResult()
        let runner = ImmediateRunner(result: result)
        let second = StackViewModel(
            runner: runner, photos: FakePhotos(failing: false),
            pendingStore: stores.pending, checkpoints: stores.checkpoints
        )
        let pending = try XCTUnwrap(second.pending)
        XCTAssertEqual(pending.framesAnalysed, 3)
        XCTAssertEqual(pending.request.frames.map(\.assetID), picked.map(\.assetID))
        XCTAssertEqual(pending.request.mode, .median)

        await second.resume()

        XCTAssertEqual(runner.requests.map(\.id), [pending.request.id], "resumes the same run, not a new one")
        XCTAssertEqual(second.phase, .done(result))
        XCTAssertNil(second.pending)
    }

    func testDiscardingAPendingStackRemovesItsProgress() async throws {
        let stores = makeStores()
        let model = StackViewModel(
            runner: InterruptingRunner(checkpoints: stores.checkpoints, framesDone: 2),
            photos: FakePhotos(failing: false), pendingStore: stores.pending, checkpoints: stores.checkpoints
        )
        await model.start(frames: frames(5), mode: .mean)
        model.reset()
        let jobID = try XCTUnwrap(model.pending?.request.id)
        XCTAssertNotNil(stores.checkpoints.load(jobID: jobID))

        model.discardPending()

        XCTAssertNil(model.pending)
        XCTAssertNil(stores.pending.load())
        XCTAssertNil(stores.checkpoints.load(jobID: jobID))
    }

    func testACompletedRunLeavesNothingPending() async {
        let stores = makeStores()
        let model = StackViewModel(
            runner: ImmediateRunner(result: makeResult()),
            photos: FakePhotos(failing: false), pendingStore: stores.pending, checkpoints: stores.checkpoints
        )
        await model.start(frames: frames(5), mode: .mean)

        XCTAssertNil(model.pending)
        XCTAssertNil(stores.pending.load())
    }

    func testARunThatCannotSucceedIsNotKeptForResuming() async {
        let stores = makeStores()
        let model = StackViewModel(
            runner: ThrowingRunner(error: JobError.tooFewUsableFrames(usable: 2)),
            photos: FakePhotos(failing: false), pendingStore: stores.pending, checkpoints: stores.checkpoints
        )
        await model.start(frames: frames(5), mode: .mean)
        model.reset()

        XCTAssertNil(model.pending)
        XCTAssertNil(stores.pending.load())
    }

    // MARK: - Saving and cleaning up

    func testSaveFailureKeepsResultForRetry() async throws {
        let result = makeResult()
        let photos = FakePhotos(failing: true)
        let model = makeModel(runner: ImmediateRunner(result: result), photos: photos)
        await model.start(frames: frames(5), mode: .mean)

        do {
            try await model.saveToPhotos()
            XCTFail("expected the save to fail")
        } catch {}

        XCTAssertEqual(model.phase, .done(result))
        XCTAssertNotNil(model.saveError)
        XCTAssertFalse(model.saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path), "kept for the retry")

        photos.failing = false
        try await model.saveToPhotos()
        XCTAssertTrue(model.saved)
        XCTAssertNil(model.saveError)
    }

    func testSavedResultFileIsRemovedToFreeStorage() async throws {
        let result = makeResult()
        let model = makeModel(runner: ImmediateRunner(result: result))
        await model.start(frames: frames(5), mode: .mean)

        try await model.saveToPhotos()

        XCTAssertFalse(FileManager.default.fileExists(atPath: result.outputURL.path))
    }

    func testResetDeletesTheResultFile() async {
        let result = makeResult()
        let model = makeModel(runner: ImmediateRunner(result: result))
        await model.start(frames: frames(5), mode: .mean)

        model.reset()

        XCTAssertEqual(model.phase, .picking)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.outputURL.path))
    }

    // MARK: - Helpers

    private func frames(_ count: Int) -> [Frame] {
        (0..<count).map {
            Frame(id: UUID(), assetID: "asset-\($0)", width: 4000, height: 3000,
                  isRAW: false, exposureSeconds: 10, iso: 1600)
        }
    }

    /// A result whose file really exists, so tests can see whether it is kept or removed.
    private func makeResult(failures: [UUID: FrameFailure] = [:]) -> StackResult {
        let url = directory.appendingPathComponent("result-\(UUID().uuidString).jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return StackResult(outputURL: url, usedFrameIDs: [], failures: failures)
    }

    private struct Stores {
        let pending: PendingJobStore
        let checkpoints: CheckpointStore
    }

    private func makeStores() -> Stores {
        Stores(
            pending: PendingJobStore(directory: directory.appendingPathComponent("pending")),
            checkpoints: CheckpointStore(directory: directory.appendingPathComponent("checkpoints"))
        )
    }

    private func makeModel(runner: StackRunner, photos: PhotosWriter = FakePhotos(failing: false)) -> StackViewModel {
        let stores = makeStores()
        return StackViewModel(runner: runner, photos: photos, pendingStore: stores.pending, checkpoints: stores.checkpoints)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never became true")
    }

    // MARK: - Fakes

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
        private let lock = NSLock()
        private var seen: [StackRequest] = []
        init(result: StackResult) { self.result = result }

        var requests: [StackRequest] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        func run(_ request: StackRequest, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> StackResult {
            lock.lock()
            seen.append(request)
            lock.unlock()
            return result
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

    /// Behaves like a job the system stopped: it saved a checkpoint, then was cancelled.
    private final class InterruptingRunner: StackRunner, @unchecked Sendable {
        let checkpoints: CheckpointStore
        let framesDone: Int
        init(checkpoints: CheckpointStore, framesDone: Int) {
            self.checkpoints = checkpoints
            self.framesDone = framesDone
        }

        func run(_ request: StackRequest, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> StackResult {
            var checkpoint = Checkpoint(jobID: request.id)
            checkpoint.completedFrameIDs = request.frames.prefix(framesDone).map(\.id)
            try checkpoints.save(checkpoint)
            throw CancellationError()
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
