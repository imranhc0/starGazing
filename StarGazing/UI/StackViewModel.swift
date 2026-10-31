import Foundation
import Observation

/// Runs a stack and reports progress. The app implements this over `StackJob` and
/// `BackgroundRunner`; tests supply fakes.
nonisolated protocol StackRunner: Sendable {
    func run(_ request: StackRequest, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> StackResult
}

/// Saves a finished image to the photo library.
nonisolated protocol PhotosWriter: Sendable {
    func save(imageAt url: URL) async throws
}

@MainActor
@Observable
final class StackViewModel {
    enum Phase: Equatable {
        case picking
        case running(JobProgress)
        case done(StackResult)
        case failed(String)
    }

    /// A stack that was started and not finished, which can be resumed from where it stopped.
    struct PendingStack: Equatable {
        let request: StackRequest
        /// How many of its photos had already been looked at.
        let framesAnalysed: Int
    }

    private(set) var phase: Phase = .picking
    /// True once the finished image has been saved to Photos.
    private(set) var saved = false
    /// Why the last save failed. The result stays available, so the user can retry.
    private(set) var saveError: String?
    /// The first photo of the run, shown as "before" next to the stacked result.
    private(set) var beforeAssetID: String?
    /// An unfinished stack from an earlier run or launch, if there is one.
    private(set) var pending: PendingStack?

    private let runner: StackRunner
    private let photos: PhotosWriter
    private let pendingStore: PendingJobStore
    private let checkpoints: CheckpointStore

    init(runner: StackRunner, photos: PhotosWriter, pendingStore: PendingJobStore, checkpoints: CheckpointStore) {
        self.runner = runner
        self.photos = photos
        self.pendingStore = pendingStore
        self.checkpoints = checkpoints
        refreshPending()
    }

    // MARK: - Running

    func start(frames: [Frame], mode: StackMode) async {
        let request: StackRequest
        do {
            request = try StackRequest.validated(frames: frames, mode: mode)
        } catch {
            phase = .failed(Self.message(for: error))
            return
        }
        await run(request)
    }

    /// Carries on the unfinished stack from its checkpoint.
    func resume() async {
        guard let pending else { return }
        await run(pending.request)
    }

    /// Gives up on the unfinished stack and removes its saved progress.
    func discardPending() {
        if let request = pendingStore.load() {
            checkpoints.remove(jobID: request.id)
        }
        pendingStore.remove()
        pending = nil
    }

    private func run(_ request: StackRequest) async {
        saved = false
        saveError = nil
        beforeAssetID = request.frames.first?.assetID
        // Saved first, so that if the run is stopped, the next launch can find it.
        try? pendingStore.save(request)
        pending = nil
        phase = .running(JobProgress(framesDone: 0, framesTotal: request.frames.count, currentFailure: nil))

        do {
            let result = try await runner.run(request) { [weak self] progress in
                Task { @MainActor in self?.report(progress) }
            }
            pendingStore.remove()
            phase = .done(result)
        } catch {
            phase = .failed(Self.message(for: error))
            // Only a run that was stopped can be picked up again. One that failed on its own
            // merits (too few usable photos, no overlap) would fail the same way.
            if !Self.isResumable(error) {
                checkpoints.remove(jobID: request.id)
                pendingStore.remove()
            }
        }
    }

    /// Progress callbacks hop through a task, so one can arrive after the run has finished.
    private func report(_ progress: JobProgress) {
        if case .running = phase {
            phase = .running(progress)
        }
    }

    // MARK: - Saving and leaving

    func saveToPhotos() async throws {
        guard case .done(let result) = phase else { return }
        do {
            try await photos.save(imageAt: result.outputURL)
            saved = true
            saveError = nil
            // The copy in Photos is the keeper; free the storage the app was holding.
            try? FileManager.default.removeItem(at: result.outputURL)
        } catch {
            saved = false
            saveError = error.localizedDescription
            throw error
        }
    }

    /// Returns to the picker. A result that is left behind is deleted: the caller is expected to
    /// have saved it, or to have asked the user.
    func reset() {
        if case .done(let result) = phase {
            try? FileManager.default.removeItem(at: result.outputURL)
        }
        phase = .picking
        saved = false
        saveError = nil
        refreshPending()
    }

    private func refreshPending() {
        guard let request = pendingStore.load() else {
            pending = nil
            return
        }
        let analysed = checkpoints.load(jobID: request.id)?.completedFrameIDs.count ?? 0
        pending = PendingStack(request: request, framesAnalysed: analysed)
    }

    // MARK: - Messages

    private static func isResumable(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case JobError.interrupted = error { return true }
        return false
    }

    static func message(for error: Error) -> String {
        let minimum = StackRequest.frameRange.lowerBound
        switch error {
        case StackRequestError.tooFewFrames(let count):
            return "Pick at least \(minimum) photos. You picked \(count)."
        case StackRequestError.tooManyFrames(let count):
            return "Stacking supports up to \(StackRequest.frameRange.upperBound) photos. You picked \(count)."
        case JobError.tooFewUsableFrames(let usable):
            return "Only \(usable) of your photos could be used. Stacking needs at least \(minimum)."
        case JobError.noOverlap:
            return "The photos don't overlap enough to stack. Check that they show the same patch of sky."
        case JobError.interrupted:
            return "Stacking was paused. Your progress is saved, and you can pick up where it stopped."
        case FrameLoaderError.mixedFormats:
            return "RAW and JPEG/HEIC photos can't be stacked together. Pick one kind."
        case FrameLoaderError.mixedSizes:
            return "These photos have different sizes. Pick photos from the same camera and shoot."
        case is CancellationError:
            return "Stacking was stopped. Your progress is saved, and you can pick up where it stopped."
        default:
            return error.localizedDescription
        }
    }
}
