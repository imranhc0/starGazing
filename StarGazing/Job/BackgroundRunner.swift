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

    private struct Pending {
        let job: StackJob
        let framesTotal: Int
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

    /// Asks the system to run the job now and keep it going in the background.
    /// Returns the identifier of the submitted task.
    @discardableResult
    func start(_ job: StackJob, framesTotal: Int, title: String, subtitle: String) throws -> String {
        let identifier = Self.identifierPrefix + UUID().uuidString
        lock.lock()
        pending[identifier] = Pending(job: job, framesTotal: framesTotal)
        lock.unlock()

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            lock.lock()
            pending[identifier] = nil
            lock.unlock()
            throw error
        }
        return identifier
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
                _ = try await entry.job.run { progress in
                    task.progress.completedUnitCount = Int64(progress.framesDone)
                }
                task.progress.completedUnitCount = task.progress.totalUnitCount
                task.setTaskCompleted(success: true)
            } catch {
                // Cancelled by expiration or failed: the checkpoint is already saved.
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}
