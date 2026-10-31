import SwiftUI

struct ResultView: View {
    let model: StackViewModel
    let result: StackResult
    let loadBefore: () async -> UIImage?

    @State private var before: UIImage?
    @State private var after: UIImage?
    @State private var appeared = false
    @State private var isSaving = false

    private var aspectRatio: CGFloat {
        guard let after, after.size.height > 0 else { return 4.0 / 3.0 }
        return after.size.width / after.size.height
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Your stacked sky")
                    .font(.title.weight(.bold))
                    .padding(.top, 24)

                BeforeAfterSlider(before: before, after: after)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    )

                summary
                saveSection

                Button("Stack another set") {
                    model.reset()
                }
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .task {
            async let afterImage = Thumbnails.load(url: result.outputURL, maxPixel: 1600)
            async let beforeImage = loadBefore()
            after = await afterImage
            before = await beforeImage
        }
        .onAppear { appeared = true }
        .sensoryFeedback(.success, trigger: appeared)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(result.usedFrameIDs.count) photos stacked", systemImage: "checkmark.seal")
                .font(.headline)
            if !result.failures.isEmpty {
                DisclosureGroup("\(result.failures.count) skipped") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(result.failures.values.enumerated()), id: \.offset) { _, failure in
                            Text("• \(failure.userDescription)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .font(.subheadline)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var saveSection: some View {
        VStack(spacing: 8) {
            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 10) {
                    if isSaving {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: model.saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .symbolEffect(.bounce, value: model.saved)
                    }
                    Text(model.saved ? "Saved to Photos" : (model.saveError == nil ? "Save to Photos" : "Try saving again"))
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(.black)
                .background(
                    Capsule().fill(LinearGradient(colors: [Theme.starGold, Theme.aurora], startPoint: .leading, endPoint: .trailing))
                )
            }
            .disabled(isSaving || model.saved)

            if let error = model.saveError {
                Text("Couldn't save: \(error). Your stacked photo is still here, so you can try again.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        // A failure is kept in the model (saveError), so the screen shows it and offers a retry.
        try? await model.saveToPhotos()
    }
}
