#if DEBUG
import SwiftUI
import UIKit

/// Debug-only screens with made-up data, so the animated screens can be launched and looked at
/// without a photo library: `-demoScreen picker | run | result`.
enum DemoScreen: String {
    case picker, resume, run, result

    static var requested: DemoScreen? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-demoScreen"), index + 1 < arguments.count else { return nil }
        return DemoScreen(rawValue: arguments[index + 1])
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .picker: DemoPicker(unfinished: false)
        case .resume: DemoPicker(unfinished: true)
        case .run: DemoRun()
        case .result: DemoResult()
        }
    }
}

private enum DemoModel {
    /// A view model backed by a scratch folder. With `unfinished`, a stack that was stopped
    /// part-way is waiting, so the picker shows its "resume" card.
    static func make(unfinished: Bool = false) -> StackViewModel {
        let folder = URL.temporaryDirectory.appendingPathComponent("demo-stargazing")
        try? FileManager.default.removeItem(at: folder)
        let pending = PendingJobStore(directory: folder.appendingPathComponent("pending"))
        let checkpoints = CheckpointStore(directory: folder.appendingPathComponent("checkpoints"))
        if unfinished {
            let frames = (0..<40).map { index in
                Frame(id: UUID(), assetID: "demo-\(index)", width: 4032, height: 3024,
                      isRAW: true, exposureSeconds: 15, iso: 1600)
            }
            if let request = try? StackRequest.validated(frames: frames, mode: .mean) {
                try? pending.save(request)
                var checkpoint = Checkpoint(jobID: request.id)
                checkpoint.completedFrameIDs = frames.prefix(17).map(\.id)
                try? checkpoints.save(checkpoint)
            }
        }
        return StackViewModel(runner: DemoRunner(), photos: DemoWriter(), pendingStore: pending, checkpoints: checkpoints)
    }
}

private struct DemoPicker: View {
    let unfinished: Bool

    var body: some View {
        ContentView(model: DemoModel.make(unfinished: unfinished))
    }
}

/// Steps through a run, with one skipped photo, then starts over.
private struct DemoRun: View {
    @State private var done = 0
    private let total = 12

    var body: some View {
        ZStack {
            StarfieldBackground()
            RunView(progress: JobProgress(
                framesDone: done,
                framesTotal: total,
                currentFailure: done == 6 ? .noStars : nil
            ))
        }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1200))
                done = done >= total ? 0 : done + 1
            }
        }
    }
}

private struct DemoResult: View {
    @State private var model = DemoModel.make()
    private let result: StackResult
    private let beforeImage: UIImage

    init() {
        let after = DemoImages.starField(noise: 0.05, stars: 70)
        let url = URL.temporaryDirectory.appendingPathComponent("demo-after.jpg")
        try? after.jpegData(compressionQuality: 0.9)?.write(to: url)
        beforeImage = DemoImages.starField(noise: 0.35, stars: 70)
        result = StackResult(
            outputURL: url,
            usedFrameIDs: (0..<11).map { _ in UUID() },
            failures: [UUID(): .noStars]
        )
    }

    var body: some View {
        ZStack {
            StarfieldBackground()
            ResultView(model: model, result: result) { beforeImage }
        }
        .preferredColorScheme(.dark)
    }
}

private enum DemoImages {
    /// A dark sky with stars; `noise` speckles it, as an unstacked frame would be.
    static func starField(noise: Double, stars: Int) -> UIImage {
        let size = CGSize(width: 800, height: 600)
        var generator = SystemRandomNumberGenerator()
        var seeded = SeededGenerator(seed: 11)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            UIColor(red: 0.02, green: 0.03, blue: 0.10, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            for _ in 0..<stars {
                let x = Double.random(in: 0...size.width, using: &seeded)
                let y = Double.random(in: 0...(size.height * 0.8), using: &seeded)
                let r = Double.random(in: 1...3.2, using: &seeded)
                UIColor.white.withAlphaComponent(.random(in: 0.6...1, using: &seeded)).setFill()
                cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            for _ in 0..<Int(noise * 9000) {
                let x = Double.random(in: 0...size.width, using: &generator)
                let y = Double.random(in: 0...size.height, using: &generator)
                UIColor(white: 1, alpha: .random(in: 0.05...0.5, using: &generator)).setFill()
                cg.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5))
            }
            UIColor(red: 0.01, green: 0.01, blue: 0.03, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: size.height * 0.82, width: size.width, height: size.height * 0.18))
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private struct DemoRunner: StackRunner {
    func run(_ request: StackRequest, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> StackResult {
        throw CancellationError()
    }
}

private struct DemoWriter: PhotosWriter {
    func save(imageAt url: URL) async throws {}
}
#endif
