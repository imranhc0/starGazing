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

    private(set) var phase: Phase = .picking
    /// True once the finished image has been saved to Photos.
    private(set) var saved = false
    /// Why the last save failed. The result stays available, so the user can retry.
    private(set) var saveError: String?
    /// The first photo of the run, shown as "before" next to the stacked result.
    private(set) var beforeAssetID: String?

    private let runner: StackRunner
    private let photos: PhotosWriter

    init(runner: StackRunner, photos: PhotosWriter) {
        self.runner = runner
        self.photos = photos
    }

    func start(frames: [Frame], mode: StackMode) async {
        let request: StackRequest
        do {
            request = try StackRequest.validated(frames: frames, mode: mode)
        } catch {
            phase = .failed(Self.message(for: error))
            return
        }

        saved = false
        saveError = nil
        beforeAssetID = frames.first?.assetID
        phase = .running(JobProgress(framesDone: 0, framesTotal: frames.count, currentFailure: nil))
        do {
            let result = try await runner.run(request) { [weak self] progress in
                Task { @MainActor in self?.report(progress) }
            }
            phase = .done(result)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Progress callbacks hop through a task, so one can arrive after the run has finished.
    private func report(_ progress: JobProgress) {
        if case .running = phase {
            phase = .running(progress)
        }
    }

    func saveToPhotos() async throws {
        guard case .done(let result) = phase else { return }
        do {
            try await photos.save(imageAt: result.outputURL)
            saved = true
            saveError = nil
        } catch {
            saved = false
            saveError = error.localizedDescription
            throw error
        }
    }

    func reset() {
        phase = .picking
        saved = false
        saveError = nil
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
            return "Stacking was paused. Open the app again to continue."
        case FrameLoaderError.mixedFormats:
            return "RAW and JPEG/HEIC photos can't be stacked together. Pick one kind."
        case FrameLoaderError.mixedSizes:
            return "These photos have different sizes. Pick photos from the same camera and shoot."
        case is CancellationError:
            return "Stacking was stopped. Open the app again to continue."
        default:
            return error.localizedDescription
        }
    }
}
