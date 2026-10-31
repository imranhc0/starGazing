import BackgroundTasks
import Foundation

/// Runs a `StackJob` under `BGContinuedProcessingTask`, so a stack the user started keeps going
/// when the app leaves the foreground. The system shows the task's progress to the user and may
/// expire it; the job's checkpoint is what lets the next launch resume.
///
/// Only the system can schedule these tasks, so this is checked by building and by running on a
/// device, not by unit tests.
nonisolated final class BackgroundRunner: @unchecked Sendable {
    /// The wildcard listed in `BGTaskSchedulerPermittedIdentifiers` (Config/Info.plist).
    static let registrationIdentifier = "imranhc0.StarGazing.stacking.*"
    /// Each submitted task gets this prefix plus a unique suffix, as the SDK requires.
    static let identifierPrefix = "imranhc0.StarGazing.stacking."

    /// The system declined to schedule the task (not permitted, no room, simulator).
    /// The caller can run the job in the foreground instead.
    struct SubmissionFailed: Error {
        let underlying: Error
    }

    private struct Pending {
        let job: StackJob
        let framesTotal: Int
        let onProgress: @Sendable (JobProgress) -> Void
        let continuation: CheckedContinuation<StackResult, Error>
    }

    private let lock = NSLock()
    private var pending: [String: Pending] = [:]

    /// Call once as the app starts.
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.registrationIdentifier, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            self?.run(task)
        }
    }

    /// Submits the job to the system and waits for its result. Throws `SubmissionFailed`
    /// before the job has started if the system will not run it.
    func run(
        _ job: StackJob,
        framesTotal: Int,
        title: String,
        subtitle: String,
        onProgress: @escaping @Sendable (JobProgress) -> Void
    ) async throws -> StackResult {
        let identifier = Self.identifierPrefix + UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[identifier] = Pending(
                job: job, framesTotal: framesTotal, onProgress: onProgress, continuation: continuation
            )
            lock.unlock()

            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .queue
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                if takePending(identifier) != nil {
                    continuation.resume(throwing: SubmissionFailed(underlying: error))
                }
            }
        }
    }

    private func takePending(_ identifier: String) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: identifier)
    }

    private func run(_ task: BGContinuedProcessingTask) {
        guard let entry = takePending(task.identifier) else {
            task.setTaskCompleted(success: false)
            return
        }

        // One unit per frame, plus one for the final stack, so progress does not read as finished
        // before the result is written.
        task.progress.totalUnitCount = Int64(entry.framesTotal + 1)

        let work = Task {
            do {
                let result = try await entry.job.run { progress in
                    task.progress.completedUnitCount = Int64(progress.framesDone)
                    entry.onProgress(progress)
                }
                task.progress.completedUnitCount = task.progress.totalUnitCount
                task.setTaskCompleted(success: true)
                entry.continuation.resume(returning: result)
            } catch {
                // Cancelled by expiration or failed: the checkpoint is already saved.
                task.setTaskCompleted(success: false)
                entry.continuation.resume(throwing: error)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}
