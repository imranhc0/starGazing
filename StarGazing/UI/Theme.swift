import SwiftUI

enum Theme {
    static let skyTop = Color(red: 0.03, green: 0.04, blue: 0.14)
    static let skyBottom = Color(red: 0.12, green: 0.08, blue: 0.32)
    static let starGold = Color(red: 1.00, green: 0.86, blue: 0.56)
    static let aurora = Color(red: 0.46, green: 0.89, blue: 1.00)
    static let cardRadius: CGFloat = 24
}

/// The night sky behind every screen. Stars twinkle; with Reduce Motion on they hold still.
struct StarfieldBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stars = Star.field(count: 140)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.skyTop, Theme.skyBottom], startPoint: .top, endPoint: .bottom)
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    for star in stars {
                        let twinkle = reduceMotion ? 0.8 : 0.55 + 0.45 * sin(time * star.speed + star.phase)
                        context.opacity = twinkle * star.brightness
                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: star.x * size.width, y: star.y * size.height,
                                width: star.size, height: star.size
                            )),
                            with: .color(.white)
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct Star {
    let x: Double
    let y: Double
    let size: Double
    let brightness: Double
    let speed: Double
    let phase: Double

    static func field(count: Int) -> [Star] {
        (0..<count).map { _ in
            Star(
                x: .random(in: 0...1), y: .random(in: 0...1),
                size: .random(in: 0.8...2.4), brightness: .random(in: 0.35...1),
                speed: .random(in: 0.6...2.2), phase: .random(in: 0...(2 * .pi))
            )
        }
    }
}

extension View {
    /// A frosted panel with a hairline edge.
    func glassCard() -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
    }
}

extension StackMode {
    var title: String {
        switch self {
        case .mean: "Clean sky"
        case .median: "Median"
        case .trails: "Star trails"
        }
    }

    var detail: String {
        switch self {
        case .mean: "Less noise, sharp stars"
        case .median: "Removes planes and satellites"
        case .trails: "Stars become streaks"
        }
    }
}

extension FrameFailure {
    /// Plain-language reason a photo was skipped.
    var userDescription: String {
        switch self {
        case .tooFewStars(let found): "too few stars to align (\(found) found)"
        case .noStars: "no stars found, maybe clouds"
        case .misaligned: "could not be lined up with the others"
        case .outOfFocus: "out of focus"
        case .unreadable(let reason): reason
        }
    }
}
