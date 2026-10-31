import XCTest
@testable import StarGazing

final class BackgroundRunnerTests: XCTestCase {

    private struct EmptySource: FrameSource {
        func data(for frameID: UUID) async throws -> Data { throw FrameFailure.unreadable("none") }
    }

    /// Asking the system to schedule the stacking task used to raise an Objective-C exception
    /// ("No launch handler registered for task with identifier ..."), which Swift cannot catch, so
    /// the app died instead of falling back to the foreground. Whatever the system decides, the
    /// call must come back.
    func testSchedulingTheTaskNeverCrashesTheApp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = (0..<5).map {
            Frame(id: UUID(), assetID: "a\($0)", width: 10, height: 10, isRAW: false, exposureSeconds: 1, iso: 100)
        }
        let job = StackJob(
            request: try StackRequest.validated(frames: frames, mode: .mean),
            source: EmptySource(),
            store: CheckpointStore(directory: folder.appendingPathComponent("checkpoints")),
            outputDirectory: folder.appendingPathComponent("out")
        )

        do {
            _ = try await BackgroundRunner().run(job, framesTotal: 5, title: "Test", subtitle: "Test") { _ in }
        } catch is BackgroundRunner.SubmissionFailed {
            // The system declined (for example in the simulator): the caller falls back to the foreground.
        } catch {
            // The system started the task and the job itself failed (these frames cannot be read).
        }
        // Reaching this line is the assertion: the process is still alive.
    }
}
