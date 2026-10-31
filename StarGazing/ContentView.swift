//
//  ContentView.swift
//  StarGazing
//
//  Created by IMRAN on 31/10/26.
//

import SwiftUI

struct ContentView: View {
    let model: StackViewModel
    /// Loads the "before" photo for the result screen, given the first photo's identifier.
    var loadBefore: (String?) async -> UIImage? = { identifier in
        guard let identifier else { return nil }
        return await PhotosLibrary.thumbnail(assetID: identifier, maxPixel: 1600)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            StarfieldBackground()
            Group {
                switch model.phase {
                case .picking:
                    PickerView(model: model)
                case .running(let progress):
                    RunView(progress: progress)
                case .done(let result):
                    ResultView(model: model, result: result) {
                        await loadBefore(model.beforeAssetID)
                    }
                case .failed(let message):
                    FailedView(message: message) { model.reset() }
                }
            }
            .id(phaseKey)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.5), value: phaseKey)
        .preferredColorScheme(.dark)
        .tint(Theme.starGold)
    }

    /// Changes only when the screen changes, not on every progress tick.
    private var phaseKey: Int {
        switch model.phase {
        case .picking: 0
        case .running: 1
        case .done: 2
        case .failed: 3
        }
    }
}

private struct FailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cloud.moon")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.aurora)
            Text("That didn't work")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
        .glassCard()
        .padding(24)
    }
}

#Preview {
    ContentView(model: StackViewModel(runner: PreviewRunner(), photos: SystemPhotosWriter()))
}

private struct PreviewRunner: StackRunner {
    func run(_ request: StackRequest, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> StackResult {
        throw CancellationError()
    }
}
