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

        // Average the colour channels into the red one and render only that: one float per pixel
        // instead of four, which matters for a full-size frame.
        let third = CIVector(x: 1.0 / 3, y: 1.0 / 3, z: 1.0 / 3, w: 0)
        let grey = source.applyingFilter("CIColorMatrix", parameters: ["inputRVector": third])

        var values = [Float](repeating: 0, count: width * height)
        let context = FloatContext.make()
        values.withUnsafeMutableBytes { buffer in
            context.render(
                grey,
                toBitmap: buffer.baseAddress!,
                rowBytes: width * MemoryLayout<Float>.size,
                bounds: bounds,
                format: .Rf,
                colorSpace: nil
            )
        }
        return LuminanceBuffer(width: width, height: height, values: values)
    }
}
