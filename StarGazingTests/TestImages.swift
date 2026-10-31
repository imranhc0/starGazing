import CoreImage
import Foundation
@testable import StarGazing

/// Float test images with no colour management, so values read back exactly.
enum TestImages {

    static func constant(_ value: Float, width: Int, height: Int) -> CIImage {
        var floats = [Float](repeating: value, count: width * height * 4)
        for pixel in 0..<(width * height) {
            floats[pixel * 4 + 3] = 1
        }
        return bitmap(floats, width: width, height: height)
    }

    static func bitmap(_ floats: [Float], width: Int, height: Int) -> CIImage {
        CIImage(
            bitmapData: floats.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: width * 16,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: nil
        )
    }

    /// RGBA of one pixel, at Core Image coordinates.
    static func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> (r: Float, g: Float, b: Float, a: Float) {
        var rgba = [Float](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { buffer in
            FloatContext.make().render(
                image,
                toBitmap: buffer.baseAddress!,
                rowBytes: 16,
                bounds: CGRect(x: x, y: y, width: 1, height: 1),
                format: .RGBAf,
                colorSpace: nil
            )
        }
        return (rgba[0], rgba[1], rgba[2], rgba[3])
    }
}
