import CoreImage
import Foundation

/// A grayscale float rendering of an image, row-major with row 0 at the top.
nonisolated struct LuminanceBuffer: Sendable {
    let width: Int
    let height: Int
    let values: [Float]

    /// Renders `image`, scaled down first if its longer side exceeds `maxDimension`.
    /// Returns nil for empty or infinite images.
    static func render(_ image: CIImage, maxDimension: Int? = nil) -> LuminanceBuffer? {
        let extent = image.extent.integral
        guard !extent.isInfinite, !extent.isEmpty else { return nil }

        var source = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if let maxDimension, max(extent.width, extent.height) > CGFloat(maxDimension) {
            let scale = CGFloat(maxDimension) / max(extent.width, extent.height)
            source = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let bounds = source.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0 else { return nil }

        var pixels = [Float](repeating: 0, count: width * height * 4)
        let context = FloatContext.make()
        pixels.withUnsafeMutableBytes { buffer in
            context.render(
                source,
                toBitmap: buffer.baseAddress!,
                rowBytes: width * 16,
                bounds: bounds,
                format: .RGBAf,
                colorSpace: nil
            )
        }

        var values = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            values[i] = (pixels[i * 4] + pixels[i * 4 + 1] + pixels[i * 4 + 2]) / 3
        }
        return LuminanceBuffer(width: width, height: height, values: values)
    }
}
