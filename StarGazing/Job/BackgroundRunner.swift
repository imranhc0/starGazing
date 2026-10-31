import BackgroundTasks
import Foundation
import os

/// Runs a `StackJob` under `BGContinuedProcessingTask`, so a stack the user started keeps going
/// when the app leaves the foreground. The system shows the task's progress to the user and may
/// expire it; the job's checkpoint is what lets the next launch resume.
///
/// Only the system can decide whether to run these tasks, so what it does with one can only be
/// seen by running on a device; the tests check that scheduling one never crashes the app.
nonisolated final class BackgroundRunner: @unchecked Sendable {
    /// Each submitted task gets this prefix plus a unique suffix. The wildcard form of it,
    /// `imranhc0.StarGazing.stacking.*`, is what `BGTaskSchedulerPermittedIdentifiers` lists
    /// (Config/Info.plist). The wildcard is never registered itself: see `run`.
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
    private let logger = Logger(subsystem: "imranhc0.StarGazing", category: "background")

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

            // The scheduler looks for a handler registered under exactly this identifier, and if
            // there is none it raises an Objective-C exception, which Swift's `catch` cannot stop
            // (the app dies instead of falling back to the foreground). A continued processing task
            // is registered here, just before it is submitted, under its own unique identifier;
            // registering the wildcard once at launch does not cover it.
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else { return }
                self?.run(task)
            }
            guard registered else {
                logger.error("The system did not accept a handler for the background task.")
                if takePending(identifier) != nil {
                    let reason = "The system did not accept a handler for the background task."
                    continuation.resume(throwing: SubmissionFailed(underlying: NSError(
                        domain: "StarGazing.BackgroundRunner", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: reason]
                    )))
                }
                return
            }

            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            // `.fail`, not `.queue`: a queued request can wait indefinitely (or be dropped when the
            // app is swiped away) while the screen shows a run that has not started. Failing at
            // once lets the caller run the job in the foreground instead.
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                logger.error("Background stacking was not scheduled: \(error.localizedDescription, privacy: .public)")
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

        // A hundred units per frame plus a hundred for the final stack, so progress keeps moving
        // while the stack is built (a task that looks stalled can be ended by the system) and does
        // not read as finished before the result is written.
        task.progress.totalUnitCount = Int64((entry.framesTotal + 1) * 100)

        // The expiration handler is in place before any work starts.
        let cancel = CancelBox()
        task.expirationHandler = { cancel.cancel() }

        cancel.set(Task {
            do {
                let result = try await entry.job.run { progress in
                    let stacking = Int((progress.stackingFraction ?? 0) * 100)
                    task.progress.completedUnitCount = Int64(progress.framesDone * 100 + stacking)
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
        })
    }

    /// Lets the expiration handler be installed before the work task exists.
    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var cancelled = false

        func set(_ task: Task<Void, Never>) {
            lock.lock()
            self.task = task
            let alreadyCancelled = cancelled
            lock.unlock()
            if alreadyCancelled { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }
}
