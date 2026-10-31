import CoreImage
import Foundation

nonisolated struct JobProgress: Sendable, Equatable {
    let framesDone: Int
    let framesTotal: Int
    /// Why the frame just finished was skipped, if it was.
    let currentFailure: FrameFailure?
}

nonisolated enum JobError: Error, Equatable {
    /// The run stopped on request after saving a checkpoint.
    case interrupted(framesDone: Int)
    case tooFewUsableFrames(usable: Int)
    /// The aligned frames share no common area.
    case noOverlap
}

/// Runs one stack from start to finish, saving a checkpoint after every analysed frame so an
/// interrupted run resumes where it stopped.
actor StackJob {
    private let request: StackRequest
    private let source: FrameSource
    private let store: CheckpointStore
    private let outputDirectory: URL

    init(request: StackRequest, source: FrameSource, store: CheckpointStore, outputDirectory: URL) {
        self.request = request
        self.source = source
        self.store = store
        self.outputDirectory = outputDirectory
    }

    /// - Parameter stopAfterFrames: stop (throwing `JobError.interrupted`) once this many frames
    ///   have been analysed in this call. The checkpoint is already saved at that point.
    func run(
        stopAfterFrames limit: Int? = nil,
        progress: @Sendable (JobProgress) -> Void = { _ in }
    ) async throws -> StackResult {
        let kind = try FrameLoader.validate(request.frames)
        var checkpoint = store.load(jobID: request.id) ?? Checkpoint(jobID: request.id)

        // Phase 1: analyse each frame, one at a time.
        var analysedThisCall = 0
        for frame in request.frames where !checkpoint.completedFrameIDs.contains(frame.id) {
            try Task.checkCancellation()

            let failure = await analyse(frame, into: &checkpoint)
            checkpoint.completedFrameIDs.append(frame.id)
            if let failure {
                checkpoint.failures[frame.id] = failure
            }
            try store.save(checkpoint)

            analysedThisCall += 1
            progress(JobProgress(
                framesDone: checkpoint.completedFrameIDs.count,
                framesTotal: request.frames.count,
                currentFailure: failure
            ))
            if let limit, analysedThisCall >= limit, checkpoint.completedFrameIDs.count < request.frames.count {
                throw JobError.interrupted(framesDone: checkpoint.completedFrameIDs.count)
            }
        }

        let usable = request.frames.filter { checkpoint.failures[$0.id] == nil }
        guard usable.count >= StackRequest.frameRange.lowerBound else {
            throw JobError.tooFewUsableFrames(usable: usable.count)
        }
        try Task.checkCancellation()

        // Phase 2: stack the usable frames and write the result.
        let result = try await stackAndExport(usable, kind: kind, checkpoint: checkpoint)
        store.remove(jobID: request.id)
        return result
    }

    // MARK: - Phase 1

    /// Detects stars and aligns the frame to the reference. Returns why the frame cannot be used, if so.
    /// Trails mode does not align, so it only needs the frame to be readable.
    private func analyse(_ frame: Frame, into checkpoint: inout Checkpoint) async -> FrameFailure? {
        let image: CIImage
        do {
            let batch = try await FrameLoader.load([frame], source: source)
            if let failure = batch.unreadable[frame.id] { return failure }
            image = batch.frames[0].linear
        } catch {
            return .unreadable(error.localizedDescription)
        }

        if request.mode == .trails { return nil }

        let stars = StarDetector.detect(in: image)
        guard !stars.isEmpty else { return .noStars }
        guard stars.count >= StarAligner.minimumStars else { return .tooFewStars(found: stars.count) }

        if checkpoint.referenceFrameID == nil {
            checkpoint.referenceFrameID = frame.id
            checkpoint.referenceStars = stars
            checkpoint.transforms[frame.id] = AlignmentTransform(a: 1, b: 0, tx: 0, ty: 0)
            return nil
        }

        do {
            checkpoint.transforms[frame.id] = try StarAligner.transform(from: stars, to: checkpoint.referenceStars)
            return nil
        } catch let failure as FrameFailure {
            return failure
        } catch {
            return .misaligned
        }
    }

    // MARK: - Phase 2

    private func stackAndExport(_ usable: [Frame], kind: BatchKind, checkpoint: Checkpoint) async throws -> StackResult {
        var failures = checkpoint.failures
        let batch = try await FrameLoader.load(usable, source: source)
        for (id, failure) in batch.unreadable {
            failures[id] = failure
        }
        guard batch.frames.count >= StackRequest.frameRange.lowerBound else {
            throw JobError.tooFewUsableFrames(usable: batch.frames.count)
        }

        let frameSize = CGSize(width: batch.width, height: batch.height)
        let aligning = request.mode != .trails
        let crop = aligning
            ? PostProcess.commonCropRect(for: batch.frames.map { checkpoint.transforms[$0.id] }, size: frameSize)
            : CGRect(origin: .zero, size: frameSize)
        guard !crop.isEmpty else { throw JobError.noOverlap }

        // The sky is aligned on the stars. The foreground does not move with the stars on a
        // tripod, so it is stacked as shot; aligning it on the stars would smear it.
        let skyFrames = batch.frames.map {
            AlignedFrame(linear: $0.linear, transform: aligning ? checkpoint.transforms[$0.id] : nil)
        }
        let foregroundFrames = batch.frames.map { AlignedFrame(linear: $0.linear, transform: nil) }
        let tile = TileRect.full(of: crop)
        let stacker = Stacker()
        let sky = stacker.stack(skyFrames, mode: request.mode, tile: tile)
        let foreground = stacker.stack(foregroundFrames, mode: .mean, tile: tile)

        let maskFrame = batch.frames.first { $0.id == checkpoint.referenceFrameID } ?? batch.frames[0]
        let mask = SkyMasker.automaticMask(for: maskFrame.linear)
        let settings = PostSettings.automatic(for: sky)
        let finished = PostProcess.blend(sky: sky, foreground: foreground, mask: mask, settings: settings)
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        let format = ExportFormat(for: kind)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory
            .appendingPathComponent(request.id.uuidString)
            .appendingPathExtension(format == .tiff16 ? "tiff" : "jpg")
        try PostProcess.export(finished, format: format, to: url)

        return StackResult(outputURL: url, usedFrameIDs: batch.frames.map(\.id), failures: failures)
    }
}
