import SwiftUI

/// While a stack runs, the photos fan around a ring and fold into one glowing star.
struct RunView: View {
    let progress: JobProgress

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cardCount = 12
    private let radius: Double = 118

    private var fraction: Double {
        progress.framesTotal > 0 ? Double(progress.framesDone) / Double(progress.framesTotal) : 0
    }

    /// Frames count for most of the work; the final stack is the last share.
    private var overall: Double {
        let total = Double(progress.framesTotal + 1)
        return (Double(progress.framesDone) + (progress.stackingFraction ?? 0)) / total
    }

    private var statusLine: String {
        if let stacking = progress.stackingFraction {
            return "Combining photos, \(Int(stacking * 100))%"
        }
        return "Looking at photo \(min(progress.framesDone + 1, progress.framesTotal)) of \(progress.framesTotal)"
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: overall)
                    .stroke(
                        AngularGradient(colors: [Theme.aurora, Theme.starGold], center: .center),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: overall)
                ForEach(0..<cardCount, id: \.self) { index in
                    card(index)
                }
                coreStar
            }
            .frame(width: 300, height: 300)

            VStack(spacing: 8) {
                Text("Stacking your night sky")
                    .font(.title2.weight(.semibold))
                Text(statusLine)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                if let failure = progress.currentFailure {
                    Label("Skipped a photo: \(failure.userDescription)", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .smooth, value: progress)

            Spacer()
            Label("Keep StarGazing open while it works. If it is interrupted, you can pick up where it stopped.", systemImage: "hand.raised")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .sensoryFeedback(.impact(weight: .light), trigger: progress.framesDone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stacking your night sky")
        .accessibilityValue("\(statusLine). \(Int(overall * 100)) percent done.")
    }

    private func isMerged(_ index: Int) -> Bool {
        Double(index + 1) / Double(cardCount) <= fraction + 0.0001
    }

    private func card(_ index: Int) -> some View {
        let merged = isMerged(index)
        let angle = Double(index) / Double(cardCount) * 2 * .pi
        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.20, green: 0.20, blue: 0.50), Color(red: 0.08, green: 0.08, blue: 0.25)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.starGold)
                    .padding(6)
            }
            .frame(width: 44, height: 58)
            .rotationEffect(.radians(merged ? Double(index) * 0.03 : angle + .pi / 2))
            .scaleEffect(merged ? 0.78 : 1)
            .opacity(merged ? 0.55 : 1)
            .offset(x: merged ? 0 : cos(angle) * radius, y: merged ? 0 : sin(angle) * radius)
            .animation(
                reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.65),
                value: merged
            )
    }

    private var coreStar: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 36 + 40 * fraction))
            .foregroundStyle(Theme.starGold)
            .shadow(color: Theme.starGold.opacity(0.35 + 0.5 * fraction), radius: 10 + 20 * fraction)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            .animation(reduceMotion ? nil : .smooth, value: fraction)
    }
}

#Preview {
    ZStack {
        StarfieldBackground()
        RunView(progress: JobProgress(framesDone: 5, framesTotal: 12, currentFailure: nil))
    }
    .preferredColorScheme(.dark)
}
