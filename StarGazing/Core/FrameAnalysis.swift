import CoreImage
import Foundation

/// What is learned about one photo when it is first looked at: where its stars are, and how much
/// fine detail it has. Saved with the checkpoint, so a resumed run does not look again.
nonisolated struct FrameAnalysis: Codable, Sendable, Equatable {
    /// Brightest first, in the photo's own full-size Core Image coordinates.
    var stars: [StarCentroid]
    /// How much fine detail the photo has; higher is sharper. Only comparable between photos of
    /// the same scene, which is what choosing the best frame of a burst needs.
    var sharpness: Double

    /// One reduced copy of the photo serves both measurements, so a 36-megapixel frame is rendered once.
    static func analyse(_ image: CIImage) -> FrameAnalysis? {
        guard let buffer = LuminanceBuffer.render(image, maxDimension: StarDetector.workingSize) else { return nil }
        let large = buffer.width > 2 * StarDetector.peakRadius && buffer.height > 2 * StarDetector.peakRadius
        let stars = large ? StarDetector.stars(in: buffer, extent: image.extent) : []
        return FrameAnalysis(stars: stars, sharpness: buffer.sharpness)
    }
}

extension LuminanceBuffer {
    /// The mean squared gradient of the (square-rooted, so a few bright lights do not dominate)
    /// brightness, relative to the picture's contrast (its variance). Blur lowers it. Dividing by
    /// the contrast, not the brightness, keeps it from depending on how much there is in the frame
    /// (twenty stars or five) or on exposure. A flat picture scores zero. Pixels are averaged in 2x2
    /// blocks first, so single noisy pixels count for less.
    var sharpness: Double {
        let w = width / 2
        let h = height / 2
        guard w >= 3, h >= 3 else { return 0 }

        var small = [Float](repeating: 0, count: w * h)
        var total = 0.0
        var totalSquares = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let i = (2 * y) * width + 2 * x
                let value = (
                    max(values[i], 0).squareRoot() + max(values[i + 1], 0).squareRoot()
                        + max(values[i + width], 0).squareRoot() + max(values[i + width + 1], 0).squareRoot()
                ) / 4
                small[y * w + x] = value
                total += Double(value)
                totalSquares += Double(value) * Double(value)
            }
        }
        let mean = total / Double(w * h)
        let variance = totalSquares / Double(w * h) - mean * mean
        guard variance > 1e-9 else { return 0 }

        var energy = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let dx = Double(small[i + 1] - small[i - 1])
                let dy = Double(small[i + w] - small[i - w])
                energy += dx * dx + dy * dy
            }
        }
        return energy / Double((w - 2) * (h - 2)) / variance
    }
}
