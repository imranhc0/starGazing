import Foundation

/// What a run has settled so far. Analysis (detect and align) is what costs time per frame,
/// so that is what is saved after each frame; the final stack is rebuilt from it.
nonisolated struct Checkpoint: Codable, Sendable, Equatable {
    let jobID: UUID
    var referenceFrameID: UUID?
    var referenceStars: [StarCentroid]
    var completedFrameIDs: [UUID]
    var transforms: [UUID: AlignmentTransform]
    var failures: [UUID: FrameFailure]

    init(jobID: UUID) {
        self.jobID = jobID
        self.referenceFrameID = nil
        self.referenceStars = []
        self.completedFrameIDs = []
        self.transforms = [:]
        self.failures = [:]
    }
}

nonisolated struct CheckpointStore: Sendable {
    let directory: URL

    func fileURL(for jobID: UUID) -> URL {
        directory.appendingPathComponent("\(jobID.uuidString).checkpoint.json")
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

    func remove(jobID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: jobID))
    }
}
