import PhotosUI
import SwiftUI

struct PickerView: View {
    let model: StackViewModel

    @State private var selection: [PhotosPickerItem] = []
    @State private var mode: StackMode = .mean
    @State private var isStarting = false
    @State private var accessMessage: String?
    @State private var report: PickReport?
    @State private var readableFrames: [Frame] = []
    @Namespace private var modeNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let modes: [StackMode] = [.mean, .median, .trails]
    private var minimum: Int { StackRequest.frameRange.lowerBound }
    private var canStart: Bool { selection.count >= minimum && !isStarting }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 24)
            header
            Spacer(minLength: 12)
            if let pending = model.pending {
                resumeCard(pending)
            }
            pickerCard
            if let report, let message = report.message {
                reportCard(report, message)
            }
            modePicker
            startButton
            if let accessMessage {
                Text(accessMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(
                    LinearGradient(colors: [Theme.starGold, Theme.aurora], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            Text("StarGazing")
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text("Stack your night photos into one clean sky")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var pickerCard: some View {
        PhotosPicker(
            selection: $selection,
            maxSelectionCount: StackRequest.frameRange.upperBound,
            matching: .images,
            photoLibrary: .shared()
        ) {
            HStack(spacing: 16) {
                Image(systemName: "photo.stack")
                    .font(.title)
                    .foregroundStyle(Theme.aurora)
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.isEmpty ? "Choose your photos" : "\(selection.count) photos chosen")
                        .font(.headline)
                        .contentTransition(.numericText())
                    Text("RAW, HEIC or JPEG. \(minimum) to \(StackRequest.frameRange.upperBound) photos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .glassCard()
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .smooth, value: selection.count)
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(modes, id: \.self) { candidate in
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
                            mode = candidate
                        }
                    } label: {
                        Text(candidate.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(mode == candidate ? Color.black : Color.white)
                            .background {
                                if mode == candidate {
                                    Capsule()
                                        .fill(Theme.starGold)
                                        .matchedGeometryEffect(id: "selectedMode", in: modeNamespace)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mode == candidate ? .isSelected : [])
                }
            }
            .padding(5)
            .background(.ultraThinMaterial, in: Capsule())

            Text(mode.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .id(mode)
                .transition(.opacity)
        }
    }

    private var startButton: some View {
        Button {
            Task { await start() }
        } label: {
            HStack(spacing: 10) {
                if isStarting {
                    ProgressView().tint(.black)
                }
                Text(selection.count < minimum ? "Pick at least \(minimum) photos" : "Start stacking")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(canStart ? Color.black : Color.secondary)
            .background(
                Capsule().fill(
                    canStart
                        ? AnyShapeStyle(LinearGradient(colors: [Theme.starGold, Theme.aurora], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.white.opacity(0.1))
                )
            )
        }
        .disabled(!canStart)
        .animation(reduceMotion ? nil : .smooth, value: canStart)
    }

    private func start() async {
        isStarting = true
        defer { isStarting = false }
        accessMessage = nil

        do {
            try await PhotosLibrary.requireReadAccess()
        } catch {
            accessMessage = error.localizedDescription
            return
        }

        let identifiers = selection.compactMap(\.itemIdentifier)
        let frames = await Task.detached { PhotosLibrary.frames(for: identifiers) }.value

        // With limited access some chosen photos cannot be opened. Say so, never drop them quietly.
        let outcome = PickReport(picked: selection.count, readable: frames.count)
        if outcome.isComplete {
            report = nil
            await model.start(frames: frames, mode: mode)
        } else {
            readableFrames = frames
            report = outcome
        }
    }

    private func resumeCard(_ pending: StackViewModel.PendingStack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pick up where you left off", systemImage: "arrow.clockwise.circle")
                .font(.headline)
            Text("\(pending.framesAnalysed) of \(pending.request.frames.count) photos had been looked at when it stopped.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Resume stacking") { Task { await model.resume() } }
                    .buttonStyle(.borderedProminent)
                Button("Discard", role: .destructive) { model.discardPending() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func reportCard(_ report: PickReport, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Some photos can't be read", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Add photos") { PhotosLibrary.presentLimitedPicker() }
                    .buttonStyle(.bordered)
                if report.canStack {
                    Button("Stack the \(report.readable)") {
                        Task { await model.start(frames: readableFrames, mode: mode) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
