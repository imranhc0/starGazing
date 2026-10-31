import Foundation

nonisolated enum StackMode: Sendable, Codable {
    case mean
    case median
    case trails
}

nonisolated struct Frame: Sendable, Codable, Equatable {
    let id: UUID
    let assetID: String
    let width: Int
    let height: Int
    let isRAW: Bool
    let exposureSeconds: Double
    let iso: Double
}

nonisolated enum FrameFailure: Error, Equatable, Sendable, Codable {
    case tooFewStars(found: Int)
    case noStars
    case misaligned
    case outOfFocus
    case unreadable(String)
}

nonisolated enum StackRequestError: Error, Equatable {
    case tooFewFrames(Int)
    case tooManyFrames(Int)
}

nonisolated struct StackRequest: Sendable, Codable, Equatable {
    static let frameRange = 5...200

    /// Identifies the run, so a resumed run finds its own checkpoint.
    let id: UUID
    let frames: [Frame]
    let mode: StackMode

    static func validated(frames: [Frame], mode: StackMode, id: UUID = UUID()) throws -> StackRequest {
        if frames.count < frameRange.lowerBound {
            throw StackRequestError.tooFewFrames(frames.count)
        }
        if frames.count > frameRange.upperBound {
            throw StackRequestError.tooManyFrames(frames.count)
        }
        return StackRequest(id: id, frames: frames, mode: mode)
    }
}

nonisolated struct StackResult: Sendable, Equatable {
    let outputURL: URL
    let usedFrameIDs: [UUID]
    let failures: [UUID: FrameFailure]
}
