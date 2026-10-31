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
///
/// How a burst becomes one crisp picture:
/// 1. Every photo is measured (stars, sharpness), one at a time, and the measurement is saved.
/// 2. The sharpest photo becomes the reference: everything is lined up with it, so the result is as
///    crisp as the best single frame.
/// 3. A sky shot (plenty of stars) has its sky lined up on the stars, and its ground on the ground's
///    own detail: stars drift across a tripod's frames while the ground stays put, and the other way
///    round for a tracked sky. An ordinary night scene has no stars to use, so everything is lined up
///    on the picture's detail.
/// 4. The aligned photos are combined, ignoring anything that does not agree with the rest.
actor StackJob {
    private let request: StackRequest
    private let source: FrameSource
    private let store: CheckpointStore
    private let outputDirectory: URL
    /// What was measured in this run, so aligning does not re-read files it has just written.
    private var analysisCache: [UUID: FrameAnalysis] = [:]

    /// A burst whose typical frame has at least this many stars is treated as a shot of the night sky.
    private static let starsInASkyShot = 8
    /// Below this share of the picture, the ground is too thin to align on.
    private static let thinnestGround = 0.03

    init(request: StackRequest, source: FrameSource, store: CheckpointStore, outputDirectory: URL) {
        self.request = request
        self.source = source
        self.store = store
        self.outputDirectory = outputDirectory
    }

    /// What lining the analysed frames up with the reference settled so far.
    private struct Alignment {
        var referenceID: UUID?
        /// A sky shot: aligned on its stars (below), and its ground separately (later).
        var usesStars = false
        /// For a sky shot, how each frame's sky maps onto the reference. Empty for an ordinary scene.
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
        forgetFramesWithoutSavedAnalysis(&checkpoint)

        // Phase 1: look at each frame, one at a time, and keep what was found.
        var analysedThisCall = 0
        for frame in request.frames where !checkpoint.completedFrameIDs.contains(frame.id) {
            try Task.checkCancellation()

            let failure = await analyse(frame)
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

        // Phase 2: with every frame seen, pick the reference and, for a sky shot, line the sky up
        // on its stars. Quick and in memory, so a resumed run simply does it again.
        let alignment = request.mode == .trails ? Alignment() : planAlignment(checkpoint)
        let failures = checkpoint.failures.merging(alignment.failures) { _, new in new }
        let usable = request.frames.filter { failures[$0.id] == nil }
        guard usable.count >= StackRequest.frameRange.lowerBound else {
            throw JobError.tooFewUsableFrames(usable: usable.count)
        }
        try Task.checkCancellation()

        // Phase 3: align the rest, stack the usable frames and write the result.
        let result = try await stackAndExport(usable, kind: kind, alignment: alignment, failures: failures, progress: progress)
        store.remove(jobID: request.id)
        return result
    }

    // MARK: - Phase 1

    /// A frame counted as done whose measurement was never saved (a partly written file) is looked at again.
    private func forgetFramesWithoutSavedAnalysis(_ checkpoint: inout Checkpoint) {
        guard request.mode != .trails else { return }
        checkpoint.completedFrameIDs.removeAll { id in
            checkpoint.failures[id] == nil && store.loadAnalysis(for: id, jobID: request.id) == nil
        }
    }

    /// Measures the frame and keeps the measurement. Returns why the frame cannot be used, if so.
    /// Trails mode does not align, so it only needs the frame to be readable.
    private func analyse(_ frame: Frame) async -> FrameFailure? {
        let image: CIImage
        do {
            let batch = try await FrameLoader.load([frame], source: source)
            if let failure = batch.unreadable[frame.id] { return failure }
            image = batch.frames[0].linear
        } catch {
            return .unreadable(error.localizedDescription)
        }

        if request.mode == .trails { return nil }

        guard var analysis = FrameAnalysis.analyse(image) else { return .unreadable("The photo could not be measured.") }
        // The aligner only looks at the brightest stars, so that is all that is kept.
        analysis.stars = Array(analysis.stars.prefix(StarAligner.inlierPool))
        analysisCache[frame.id] = analysis
        // A failed save only costs a repeat of this frame after a restart; this run has the measurement.
        try? store.saveAnalysis(analysis, for: frame.id, jobID: request.id)
        return nil
    }

    // MARK: - Phase 2

    private func analysis(of frame: Frame) -> FrameAnalysis {
        analysisCache[frame.id]
            ?? store.loadAnalysis(for: frame.id, jobID: request.id)
            ?? FrameAnalysis(stars: [], sharpness: 0)
    }

    /// The reference is the sharpest frame (the earliest on a tie), so the result is as crisp as the
    /// best single photo. For a sky shot, every other frame's sky is lined up with it on the stars.
    private func planAlignment(_ checkpoint: Checkpoint) -> Alignment {
        let candidates = request.frames.filter { checkpoint.failures[$0.id] == nil }
        guard !candidates.isEmpty else { return Alignment() }

        let starCounts = candidates.map { analysis(of: $0).stars.count }.sorted()
        let usesStars = starCounts[starCounts.count / 2] >= Self.starsInASkyShot

        // A sky shot needs a reference that has stars to line the others up on, and that looks like the
        // others: a frame with far fewer stars than usual (cloud, a stray light) is no one to follow.
        let enoughStars = max(StarAligner.minimumStars, starCounts[starCounts.count / 2] * 3 / 4)
        let eligible = usesStars
            ? candidates.filter { analysis(of: $0).stars.count >= enoughStars }
            : candidates
        guard let reference = eligible.max(by: { analysis(of: $0).sharpness < analysis(of: $1).sharpness }) else {
            return Alignment()
        }

        var alignment = Alignment(referenceID: reference.id, usesStars: usesStars)
        guard usesStars else { return alignment }

        let referenceStars = analysis(of: reference).stars
        alignment.transforms[reference.id] = AlignmentTransform(a: 1, b: 0, tx: 0, ty: 0)
        for frame in candidates where frame.id != reference.id {
            let stars = analysis(of: frame).stars
            if stars.isEmpty {
                alignment.failures[frame.id] = .noStars
                continue
            }
            do {
                alignment.transforms[frame.id] = try StarAligner.transform(from: stars, to: referenceStars)
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
        var frames = batch.frames
        guard frames.count >= StackRequest.frameRange.lowerBound else {
            throw JobError.tooFewUsableFrames(usable: frames.count)
        }

        let total = request.frames.count
        func report(_ fraction: Double) {
            progress(JobProgress(framesDone: total, framesTotal: total, currentFailure: nil, stackingFraction: fraction))
        }
        report(0)

        // Everything is in the sensor's orientation. The sky mask needs an upright picture to find the
        // horizon, and the finished picture is turned the way the reference frame was shot.
        let reference = frames.first { $0.id == alignment.referenceID } ?? frames[0]
        let upright = reference.linear.orientationTransform(for: reference.orientation)
        let mask = SkyMasker.automaticMask(for: reference.linear.transformed(by: upright))
        let sensorSize = reference.linear.extent.size

        let aligning = request.mode != .trails
        var sky: [UUID: AlignmentTransform] = alignment.transforms
        var ground: [UUID: AlignmentTransform] = [:]
        let identity = AlignmentTransform(a: 1, b: 0, tx: 0, ty: 0)

        if aligning {
            // Aligning the frames takes a share of the progress at the start.
            let alignmentShare = 0.1
            let others = frames.filter { $0.id != reference.id }

            if alignment.usesStars {
                // Stars gave the sky. The ground is lined up on its own detail: it holds still on a
                // tripod (shift about zero) and moves on a tracked mount or a hand-held camera.
                if let region = groundRegion(of: mask, upright: upright, sensorSize: sensorSize) {
                    for (index, frame) in others.enumerated() {
                        try Task.checkCancellation()
                        // Ground with too little detail to align on is left as shot.
                        if let motion = DenseAligner.transform(from: frame.linear, to: reference.linear, region: region) {
                            ground[frame.id] = motion
                        }
                        report(alignmentShare * Double(index + 1) / Double(others.count))
                    }
                }
            } else {
                // No stars to use: line everything up on the picture's detail, sky and ground alike.
                sky[reference.id] = identity
                ground[reference.id] = identity
                var kept = [reference]
                for (index, frame) in others.enumerated() {
                    try Task.checkCancellation()
                    if let motion = DenseAligner.transform(from: frame.linear, to: reference.linear) {
                        sky[frame.id] = motion
                        ground[frame.id] = motion
                        kept.append(frame)
                    } else {
                        failures[frame.id] = .misaligned
                    }
                    report(alignmentShare * Double(index + 1) / Double(others.count))
                }
                frames = frames.filter { frame in kept.contains { $0.id == frame.id } }
                guard frames.count >= StackRequest.frameRange.lowerBound else {
                    throw JobError.tooFewUsableFrames(usable: frames.count)
                }
            }
        }

        // The picture every frame covers, whichever way each was moved.
        let frameSize = CGSize(width: batch.width, height: batch.height)
        let crop = aligning
            ? PostProcess.commonCropRect(for: frames.flatMap { [sky[$0.id], ground[$0.id]] }, size: frameSize)
            : CGRect(origin: .zero, size: frameSize)
        guard !crop.isEmpty else { throw JobError.noOverlap }

        let skyFrames = frames.map { AlignedFrame(linear: $0.linear, transform: aligning ? sky[$0.id] : nil) }
        let groundFrames = frames.map { AlignedFrame(linear: $0.linear, transform: aligning ? ground[$0.id] : nil) }
        let tile = TileRect.full(of: crop)
        let stacker = Stacker()

        let stackingStart = aligning ? 0.1 : 0
        let stackingSpan = 1 - stackingStart
        // When sky and ground were lined up the same way, and both are averaged (a city scene),
        // the two stacks would be identical: do the work once.
        let oneStackServesBoth = request.mode == .mean && frames.allSatisfy { sky[$0.id] == ground[$0.id] }
        let skyShare = oneStackServesBoth ? 1.0 : 0.5
        let skyStack = try stacker.stack(skyFrames, mode: request.mode, tile: tile) {
            report(stackingStart + $0 * stackingSpan * skyShare)
        }
        let groundStack = try oneStackServesBoth
            ? skyStack
            : stacker.stack(groundFrames, mode: .mean, tile: tile) {
                report(stackingStart + stackingSpan * 0.5 + $0 * stackingSpan * 0.5)
            }

        let uprightCrop = crop.applying(upright)
        let settings = PostSettings.automatic(for: skyStack)
        let finished = PostProcess.blend(
            sky: skyStack.transformed(by: upright),
            foreground: groundStack.transformed(by: upright),
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

        return StackResult(outputURL: url, usedFrameIDs: frames.map(\.id), failures: failures)
    }

    /// Where the ground is, in the sensor picture, as fractions of it (origin bottom left), or nil
    /// when there is little or none. The mask finds the horizon in the upright picture, so its
    /// ground rectangle is turned back into the sensor's orientation.
    private func groundRegion(of mask: SkyMask, upright: CGAffineTransform, sensorSize: CGSize) -> CGRect? {
        let fraction = mask.groundFraction
        guard fraction > Self.thinnestGround else { return nil }
        let ground = CGRect(x: 0, y: 0, width: mask.fullWidth, height: mask.fullHeight * fraction)
        let inSensor = ground.applying(upright.inverted())
        return CGRect(
            x: inSensor.minX / sensorSize.width,
            y: inSensor.minY / sensorSize.height,
            width: inSensor.width / sensorSize.width,
            height: inSensor.height / sensorSize.height
        )
    }
}
