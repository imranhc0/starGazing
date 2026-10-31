import SwiftUI

/// Drag the handle to reveal the original (left) against the stacked result (right).
struct BeforeAfterSlider: View {
    let before: UIImage?
    let after: UIImage?

    @State private var position: CGFloat = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                picture(after)
                picture(before)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: width * position)
                    }

                handle(height: geometry.size.height)
                    .position(x: width * position, y: geometry.size.height / 2)

                label("Before", alignment: .topLeading)
                label("After", alignment: .topTrailing)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        position = min(1, max(0, value.location.x / width))
                    }
                    .onEnded { _ in
                        settle()
                    }
            )
        }
        .task { await introSweep() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Before and after comparison")
        .accessibilityValue("\(Int(position * 100)) percent shows the original")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = 0.1
            position = min(1, max(0, position + (direction == .increment ? step : -step)))
        }
    }

    @ViewBuilder
    private func picture(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Rectangle().fill(.white.opacity(0.06))
                .overlay(ProgressView())
        }
    }

    private func handle(height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: height)
                .shadow(color: .black.opacity(0.4), radius: 3)
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .overlay(
                    Image(systemName: "arrow.left.and.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                )
                .frame(width: 42, height: 42)
                .shadow(color: Theme.starGold.opacity(0.5), radius: 8)
        }
    }

    private func label(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .allowsHitTesting(false)
    }

    /// A handle left right at an edge snaps to it, with a little spring.
    private func settle() {
        let target: CGFloat? = position < 0.08 ? 0 : (position > 0.92 ? 1 : nil)
        guard let target else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.7)) {
            position = target
        }
    }

    /// Shows the slider can move, once, as the result appears.
    private func introSweep() async {
        guard !reduceMotion else { return }
        try? await Task.sleep(for: .milliseconds(500))
        withAnimation(.easeInOut(duration: 0.9)) { position = 0.2 }
        try? await Task.sleep(for: .milliseconds(1000))
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { position = 0.5 }
    }
}
