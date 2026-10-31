import Foundation

/// What a run has settled so far: which photos have been analysed, and why any were skipped.
/// What was learned about each photo (stars, sharpness) lives in its own small file (see
/// `CheckpointStore`), so saving progress after every photo stays cheap however many photos there are.
nonisolated struct Checkpoint: Codable, Sendable, Equatable {
    let jobID: UUID
    var completedFrameIDs: [UUID]
    /// Photos skipped while they were analysed (unreadable, no stars, too few stars).
    var failures: [UUID: FrameFailure]

    init(jobID: UUID) {
        self.jobID = jobID
        self.completedFrameIDs = []
        self.failures = [:]
    }
}

nonisolated struct CheckpointStore: Sendable {
    let directory: URL

    func fileURL(for jobID: UUID) -> URL {
        directory.appendingPathComponent("\(jobID.uuidString).checkpoint.json")
    }

    /// Where what was learned about one photo (its stars and sharpness) is kept.
    func analysisURL(for frameID: UUID, jobID: UUID) -> URL {
        directory
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
            .appendingPathComponent("\(frameID.uuidString).analysis.json")
    }

    func save(_ checkpoint: Checkpoint) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: fileURL(for: checkpoint.jobID), options: .atomic)
    }

    /// Nil when there is no checkpoint, or the file is unreadable or belongs to another job.
    /// A bad checkpoint means starting over, never failing the run.
    func load(jobID: UUID) -> Checkpoint? {
        guard let data = try? Data(contentsOf: fileURL(for: jobID)),
              let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data),
              checkpoint.jobID == jobID else {
            return nil
        }
        return checkpoint
    }

    func saveAnalysis(_ analysis: FrameAnalysis, for frameID: UUID, jobID: UUID) throws {
        let url = analysisURL(for: frameID, jobID: jobID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(analysis).write(to: url, options: .atomic)
    }

    /// Nil when the file is missing or unreadable; the photo is then analysed again.
    func loadAnalysis(for frameID: UUID, jobID: UUID) -> FrameAnalysis? {
        guard let data = try? Data(contentsOf: analysisURL(for: frameID, jobID: jobID)) else { return nil }
        return try? JSONDecoder().decode(FrameAnalysis.self, from: data)
    }

    func remove(jobID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: jobID))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(jobID.uuidString, isDirectory: true))
    }
}
