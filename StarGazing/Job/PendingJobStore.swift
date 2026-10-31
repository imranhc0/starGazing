import Foundation

/// Remembers the stack that is in progress (which photos, which mode, which run), so that after
/// the app is stopped or relaunched the same run can be picked up from its checkpoint.
/// Only one stack is in progress at a time.
nonisolated struct PendingJobStore: Sendable {
    let directory: URL

    private var fileURL: URL {
        directory.appendingPathComponent("pending-stack.json")
    }

    func save(_ request: StackRequest) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: fileURL, options: .atomic)
    }

    /// Nil when nothing is pending or the file cannot be read.
    func load() -> StackRequest? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StackRequest.self, from: data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
