import CoreImage
import Foundation

nonisolated struct JobProgress: Sendable, Equatable {
    let framesDone: Int
    let framesTotal: Int
    /// Why the frame just finished was skipped, if it was.
    let currentFailure: FrameFailure?
    /// While the final stack is built: how far along it is, from 0 to 1. Nil while frames are analysed.
    let stackingFraction: Double?

    init(framesDone: Int, framesTotal: Int, currentFailure: FrameFailure?, stackingFraction: Double? = nil) {
        self.framesDone = framesDone
        self.framesTotal = framesTotal
        self.currentFailure = currentFailure
        self.stackingFraction = stackingFraction
    }
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
    /// Stars found in this run, so aligning does not re-read files it has just written.
    private var starsCache: [UUID: [StarCentroid]] = [:]

    init(request: StackRequest, source: FrameSource, store: CheckpointStore, outputDirectory: URL) {
        self.request = request
        self.source = source
        self.store = store
        self.outputDirectory = outputDirectory
    }

    /// What aligning the analysed frames settled.
    private struct Alignment {
        var referenceID: UUID?
        var transforms: [UUID: AlignmentTransform] = [:]
        var failures: [UUID: FrameFailure] = [:]
    }

    /// - Parameter stopAfterFrames: stop (throwing `JobError.interrupted`) once this many frames
    ///   have been analysed in this call. The checkpoint is already saved at that point.
    func run(
        stopAfterFrames limit: Int? = nil,
        progress: @Sendable (JobProgress) -> Void = { _ in }
    ) async throws -> StackResult {
        let kind = try FrameLoader.validate(request.frames)
        var checkpoint = store.load(jobID: request.id) ?? Checkpoint(jobID: request.id)
        forgetFramesWithoutSavedStars(&checkpoint)

        // Phase 1: look at each frame, one at a time, and keep what was found.
        var analysedThisCall = 0
        for frame in request.frames where !checkpoint.completedFrameIDs.contains(frame.id) {
            try Task.checkCancellation()

            let failure = await detectStars(in: frame)
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

        // Phase 2: with every frame seen, pick the best reference and line the rest up with it.
        // This is quick and done in memory, so a resumed run simply does it again.
        let alignment = request.mode == .trails ? Alignment() : align(checkpoint)
        let failures = checkpoint.failures.merging(alignment.failures) { _, new in new }
        let usable = request.frames.filter { failures[$0.id] == nil }
        guard usable.count >= StackRequest.frameRange.lowerBound else {
            throw JobError.tooFewUsableFrames(usable: usable.count)
        }
        try Task.checkCancellation()

        // Phase 3: stack the usable frames and write the result.
        let result = try await stackAndExport(usable, kind: kind, alignment: alignment, failures: failures, progress: progress)
        store.remove(jobID: request.id)
        return result
    }

    // MARK: - Phase 1

    /// A frame counted as done whose stars were never saved (a partly written file) is looked at again.
    private func forgetFramesWithoutSavedStars(_ checkpoint: inout Checkpoint) {
        guard request.mode != .trails else { return }
        checkpoint.completedFrameIDs.removeAll { id in
            checkpoint.failures[id] == nil && store.loadStars(for: id, jobID: request.id) == nil
        }
    }

    /// Finds the frame's stars and keeps them. Returns why the frame cannot be used, if so.
    /// Trails mode does not align, so it only needs the frame to be readable.
    private func detectStars(in frame: Frame) async -> FrameFailure? {
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

        // The aligner only looks at the brightest, so that is all that is kept.
        let kept = Array(stars.prefix(StarAligner.inlierPool))
        starsCache[frame.id] = kept
        // A failed save only costs a repeat of this frame after a restart; this run has the stars.
        try? store.saveStars(kept, for: frame.id, jobID: request.id)
        return nil
    }

    // MARK: - Phase 2

    /// The reference is the frame with the most stars, the earliest on a tie: a cloudy or sparse
    /// first frame must not decide what everything else is lined up against.
    private func align(_ checkpoint: Checkpoint) -> Alignment {
        let candidates = request.frames.filter { checkpoint.failures[$0.id] == nil }
        var stars: [UUID: [StarCentroid]] = [:]
        for frame in candidates {
            stars[frame.id] = starsCache[frame.id] ?? store.loadStars(for: frame.id, jobID: request.id) ?? []
        }

        var reference: Frame?
        var mostStars = 0
        for frame in candidates where (stars[frame.id]?.count ?? 0) > mostStars {
            mostStars = stars[frame.id]?.count ?? 0
            reference = frame
        }
        guard let reference, let referenceStars = stars[reference.id] else { return Alignment() }

        var alignment = Alignment(referenceID: reference.id)
        alignment.transforms[reference.id] = AlignmentTransform(a: 1, b: 0, tx: 0, ty: 0)
        for frame in candidates where frame.id != reference.id {
            do {
                alignment.transforms[frame.id] = try StarAligner.transform(from: stars[frame.id] ?? [], to: referenceStars)
            } catch let failure as FrameFailure {
                alignment.failures[frame.id] = failure
            } catch {
                alignment.failures[frame.id] = .misaligned
            }
        }
        return alignment
    }

    // MARK: - Phase 3

    private func stackAndExport(
        _ usable: [Frame],
        kind: BatchKind,
        alignment: Alignment,
        failures: [UUID: FrameFailure],
        progress: @Sendable (JobProgress) -> Void
    ) async throws -> StackResult {
        var failures = failures
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
            ? PostProcess.commonCropRect(for: batch.frames.map { alignment.transforms[$0.id] }, size: frameSize)
            : CGRect(origin: .zero, size: frameSize)
        guard !crop.isEmpty else { throw JobError.noOverlap }

        // The sky is aligned on the stars. The foreground does not move with the stars on a
        // tripod, so it is stacked as shot; aligning it on the stars would smear it.
        let skyFrames = batch.frames.map {
            AlignedFrame(linear: $0.linear, transform: aligning ? alignment.transforms[$0.id] : nil)
        }
        let foregroundFrames = batch.frames.map { AlignedFrame(linear: $0.linear, transform: nil) }
        let tile = TileRect.full(of: crop)
        let stacker = Stacker()

        let total = request.frames.count
        func report(_ fraction: Double) {
            progress(JobProgress(framesDone: total, framesTotal: total, currentFailure: nil, stackingFraction: fraction))
        }
        report(0)
        let sky = try stacker.stack(skyFrames, mode: request.mode, tile: tile) { report($0 * 0.5) }
        let foreground = try stacker.stack(foregroundFrames, mode: .mean, tile: tile) { report(0.5 + $0 * 0.5) }

        // Everything above is in the sensor's orientation. Turn the picture the way the reference
        // frame was shot: the sky mask also needs an upright picture, to find the horizon.
        let reference = batch.frames.first { $0.id == alignment.referenceID } ?? batch.frames[0]
        let upright = reference.linear.orientationTransform(for: reference.orientation)
        let mask = SkyMasker.automaticMask(for: reference.linear.transformed(by: upright))
        let uprightCrop = crop.applying(upright)
        let settings = PostSettings.automatic(for: sky)
        let finished = PostProcess.blend(
            sky: sky.transformed(by: upright),
            foreground: foreground.transformed(by: upright),
            mask: mask,
            settings: settings
        )
        .cropped(to: uprightCrop)
        .transformed(by: CGAffineTransform(translationX: -uprightCrop.minX, y: -uprightCrop.minY))

        let format = ExportFormat(for: kind)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory
            .appendingPathComponent(request.id.uuidString)
            .appendingPathExtension(format == .tiff16 ? "tiff" : "jpg")
        try PostProcess.export(finished, format: format, to: url)

        return StackResult(outputURL: url, usedFrameIDs: batch.frames.map(\.id), failures: failures)
    }
}
