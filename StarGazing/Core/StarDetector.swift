import CoreImage
import Foundation

/// A detected star. Coordinates are in Core Image space: origin bottom-left, pixel `i` spans `[i, i+1)`.
nonisolated struct StarCentroid: Sendable, Equatable {
    let x: Double
    let y: Double
    let flux: Double
}

nonisolated enum StarDetector {
    static let maxStars = 500
    static let windowRadius = 3
    static let peakRadius = 2
    static let suppressionRadius = 4.0

    static func detect(in image: CIImage) -> [StarCentroid] {
        guard let buffer = LuminanceBuffer.render(image),
              buffer.width > 2 * peakRadius, buffer.height > 2 * peakRadius else {
            return []
        }
        return detect(luminance: buffer.values, width: buffer.width, height: buffer.height)
    }

    /// Finds local peaks above a robust noise threshold and refines each with a
    /// flux-weighted centroid. Input is row-major, row 0 at the top.
    static func detect(luminance: [Float], width: Int, height: Int) -> [StarCentroid] {
        let background = median(sampled: luminance)
        let sigma = robustSigma(sampled: luminance, around: background)
        let threshold = background + max(5 * sigma, 0.02)

        var stars: [StarCentroid] = []
        for row in peakRadius..<(height - peakRadius) {
            for col in peakRadius..<(width - peakRadius) {
                let value = luminance[row * width + col]
                guard value > threshold, isLocalMaximum(luminance, width, row, col, value) else {
                    continue
                }
                stars.append(centroid(luminance, width, height, row, col, background))
            }
        }

        return suppressDuplicates(stars.sorted { $0.flux > $1.flux })
    }

    /// A star centred on a pixel boundary leaves several equal peaks; keep only the
    /// brightest of any that fall within `suppressionRadius` of each other.
    private static func suppressDuplicates(_ brightestFirst: [StarCentroid]) -> [StarCentroid] {
        var kept: [StarCentroid] = []
        for star in brightestFirst {
            let isDuplicate = kept.contains { other in
                let dx = other.x - star.x
                let dy = other.y - star.y
                return (dx * dx + dy * dy).squareRoot() < suppressionRadius
            }
            if !isDuplicate {
                kept.append(star)
                if kept.count == maxStars { break }
            }
        }
        return kept
    }

    private static func isLocalMaximum(_ lum: [Float], _ width: Int, _ row: Int, _ col: Int, _ value: Float) -> Bool {
        for dr in -peakRadius...peakRadius {
            for dc in -peakRadius...peakRadius where lum[(row + dr) * width + (col + dc)] > value {
                return false
            }
        }
        return true
    }

    private static func centroid(
        _ lum: [Float], _ width: Int, _ height: Int, _ row: Int, _ col: Int, _ background: Float
    ) -> StarCentroid {
        var sumWeight = 0.0
        var sumX = 0.0
        var sumY = 0.0
        for r in max(0, row - windowRadius)...min(height - 1, row + windowRadius) {
            for c in max(0, col - windowRadius)...min(width - 1, col + windowRadius) {
                let weight = Double(max(0, lum[r * width + c] - background))
                sumWeight += weight
                sumX += weight * (Double(c) + 0.5)
                sumY += weight * (Double(r) + 0.5)
            }
        }
        guard sumWeight > 0 else {
            return StarCentroid(x: Double(col) + 0.5, y: Double(height - row) - 0.5, flux: 0)
        }
        // Convert bitmap rows (top-down) to Core Image y (bottom-up).
        return StarCentroid(
            x: sumX / sumWeight,
            y: Double(height) - sumY / sumWeight,
            flux: sumWeight
        )
    }

    private static func median(sampled values: [Float]) -> Float {
        let stride = max(1, values.count / 50_000)
        var sample = Swift.stride(from: 0, to: values.count, by: stride).map { values[$0] }
        sample.sort()
        return sample.isEmpty ? 0 : sample[sample.count / 2]
    }

    private static func robustSigma(sampled values: [Float], around center: Float) -> Float {
        let stride = max(1, values.count / 50_000)
        var deviations = Swift.stride(from: 0, to: values.count, by: stride).map { abs(values[$0] - center) }
        deviations.sort()
        guard !deviations.isEmpty else { return 0 }
        return 1.4826 * deviations[deviations.count / 2]
    }
}
