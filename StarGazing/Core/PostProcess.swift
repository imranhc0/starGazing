import CoreImage
import CoreGraphics
import Foundation
import ImageIO

nonisolated enum ExportFormat: Sendable, Equatable {
    case jpeg
    case tiff16

    /// RAW batches keep 16 bits; JPEG/HEIC batches only ever had 8.
    init(for kind: BatchKind) {
        self = kind == .raw ? .tiff16 : .jpeg
    }
}

nonisolated struct PostSettings: Sendable, Equatable {
    /// Stretch strength, 0 (off) to 1 (the full automatic stretch).
    var stretch: Double
    /// Denoise strength, 0 (off) to 1.
    var denoise: Double
    /// The gamma-style power that would bring this image's median to `targetMedian`. 1 means none.
    var stretchPower: Double

    static let defaultStretch = 0.8
    static let defaultDenoise = 0.3
    /// The brightness (linear light) the stretch lifts a picture's median to, at most. It is low on
    /// purpose: a pitch-black astro frame needs lifting to show its stars, but a night photo that is
    /// already lit (a city under cloud measured 0.038) must keep its dark sky. Aiming at 0.25 lifted
    /// that sky to a light grey haze.
    static let targetMedian: Float = 0.04
    static let minimumPower = 0.15

    var effectivePower: Double {
        1 + (stretchPower - 1) * stretch
    }

    /// Defaults computed from the image's own histogram: the stretch aims the median
    /// brightness at `targetMedian`.
    static func automatic(for image: CIImage) -> PostSettings {
        var power = 1.0
        if let buffer = LuminanceBuffer.render(image, maxDimension: 512) {
            let sorted = buffer.values.sorted()
            let median = sorted[sorted.count / 2]
            if median > 0, median < targetMedian {
                power = max(minimumPower, Double(log(targetMedian) / log(median)))
            }
        }
        return PostSettings(stretch: defaultStretch, denoise: defaultDenoise, stretchPower: power)
    }
}

nonisolated enum PostProcess {

    /// Composites sky over foreground through the mask, then stretches and denoises the result.
    static func blend(sky: CIImage, foreground: CIImage, mask: SkyMask, settings: PostSettings) -> CIImage {
        let filter = CIFilter(name: "CIBlendWithMask")!
        filter.setValue(sky, forKey: kCIInputImageKey)
        filter.setValue(foreground, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask.ciImage(), forKey: kCIInputMaskImageKey)
        return finish(filter.outputImage!, settings: settings)
    }

    /// Denoise first, while the data is still linear and the noise has not been amplified,
    /// then stretch.
    static func finish(_ image: CIImage, settings: PostSettings) -> CIImage {
        var result = image
        if settings.denoise > 0 {
            result = result.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.02 * settings.denoise,
                "inputSharpness": 0.4,
            ])
        }
        let power = settings.effectivePower
        if power < 1 {
            result = result.applyingFilter("CIGammaAdjust", parameters: ["inputPower": power])
        }
        return result
    }

    /// The largest axis-aligned area of the reference frame that every frame covers.
    /// A nil transform means the frame is already in reference coordinates.
    static func commonCropRect(for transforms: [AlignmentTransform?], size: CGSize) -> CGRect {
        let width = Double(size.width)
        let height = Double(size.height)
        var common = CGRect(x: 0, y: 0, width: width, height: height)

        for case let transform? in transforms {
            let c0 = transform.apply(x: 0, y: 0)
            let c1 = transform.apply(x: width, y: 0)
            let c2 = transform.apply(x: width, y: height)
            let c3 = transform.apply(x: 0, y: height)
            // The rectangle inside the transformed frame, for rotations well under 90°.
            let left = max(c0.x, c3.x)
            let right = min(c1.x, c2.x)
            let bottom = max(c0.y, c1.y)
            let top = min(c2.y, c3.y)
            common = common.intersection(CGRect(x: left, y: bottom, width: right - left, height: top - bottom))
        }

        guard !common.isNull, !common.isEmpty else { return .zero }
        // Round inwards so no pixel at the edge is partly uncovered.
        let minX = common.minX.rounded(.up)
        let minY = common.minY.rounded(.up)
        let maxX = common.maxX.rounded(.down)
        let maxY = common.maxY.rounded(.down)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Writes the image in the pipeline's linear light, converted to sRGB for the file.
    static func export(_ image: CIImage, format: ExportFormat, to url: URL) throws {
        let context = FloatContext.make()
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        switch format {
        case .jpeg:
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            try context.writeJPEGRepresentation(of: image, to: url, colorSpace: sRGB, options: [quality: 0.95])
        case .tiff16:
            try context.writeTIFFRepresentation(of: image, to: url, format: .RGBA16, colorSpace: sRGB, options: [:])
        }
    }
}
