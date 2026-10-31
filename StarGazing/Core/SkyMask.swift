import CoreImage
import Foundation

/// Sky (1) versus foreground (0), stored at low resolution so a 48MP frame does not
/// cost a full-size buffer. Coordinates are Core Image space: origin bottom-left,
/// in the pixels of the full-size frame.
nonisolated struct SkyMask: Sendable {
    let fullWidth: Double
    let fullHeight: Double
    let width: Int
    let height: Int
    /// Row-major, row 0 at the top of the picture.
    private(set) var values: [Float]

    init(fullSize: CGSize, width: Int, height: Int, values: [Float]) {
        self.fullWidth = Double(fullSize.width)
        self.fullHeight = Double(fullSize.height)
        self.width = width
        self.height = height
        self.values = values
    }

    /// The share of the frame's height, counted up from the bottom, that is foreground.
    /// Zero when the whole frame is sky.
    var groundFraction: Double {
        var groundRows = 0
        for row in stride(from: height - 1, through: 0, by: -1) {
            let start = row * width
            let mean = values[start..<(start + width)].reduce(0, +) / Float(width)
            guard mean < 0.5 else { break }
            groundRows += 1
        }
        return Double(groundRows) / Double(height)
    }

    func value(atX x: Double, y: Double) -> Float {
        let column = min(width - 1, max(0, Int(x / fullWidth * Double(width))))
        let row = min(height - 1, max(0, Int((fullHeight - y) / fullHeight * Double(height))))
        return values[row * width + column]
    }

    /// Paints a soft-edged disc at each point: sky if `sky`, foreground otherwise.
    func painting(_ stroke: [CGPoint], radius: CGFloat, sky: Bool) -> SkyMask {
        var result = self
        let target: Float = sky ? 1 : 0
        let scaleX = Double(width) / fullWidth
        let scaleY = Double(height) / fullHeight
        let radiusX = Double(radius) * scaleX
        let radiusY = Double(radius) * scaleY

        for point in stroke {
            let centerX = Double(point.x) * scaleX
            let centerY = (fullHeight - Double(point.y)) * scaleY
            let minColumn = max(0, Int((centerX - radiusX).rounded(.down)))
            let maxColumn = min(width - 1, Int((centerX + radiusX).rounded(.up)))
            let minRow = max(0, Int((centerY - radiusY).rounded(.down)))
            let maxRow = min(height - 1, Int((centerY + radiusY).rounded(.up)))
            guard minColumn <= maxColumn, minRow <= maxRow else { continue }

            for row in minRow...maxRow {
                for column in minColumn...maxColumn {
                    let dx = (Double(column) + 0.5 - centerX) / radiusX
                    let dy = (Double(row) + 0.5 - centerY) / radiusY
                    let distance = (dx * dx + dy * dy).squareRoot()
                    // Full strength inside 70% of the radius, fading to nothing at the edge.
                    let weight = Float(min(1, max(0, (1 - distance) / 0.3)))
                    let index = row * width + column
                    result.values[index] = result.values[index] * (1 - weight) + target * weight
                }
            }
        }
        return result
    }

    /// The mask scaled up to the full frame. The value is written to every colour channel
    /// (a single-channel image is pure red, which `CIBlendWithMask` does not read).
    func ciImage() -> CIImage {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for (index, value) in values.enumerated() {
            rgba[index * 4] = value
            rgba[index * 4 + 1] = value
            rgba[index * 4 + 2] = value
        }
        let small = CIImage(
            bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: width * 16,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: nil
        )
        let scale = CGAffineTransform(scaleX: fullWidth / Double(width), y: fullHeight / Double(height))
        return small
            .samplingLinear()
            .transformed(by: scale)
            .cropped(to: CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight))
    }
}

nonisolated enum SkyMasker {
    static let maxDimension = 1024
    /// A horizon must drop brightness by at least this fraction of the sky's brightness.
    static let minimumRelativeContrast: Float = 0.3

    /// Finds the horizon as the strongest bright-above, dark-below step in the row-by-row
    /// median brightness. A frame with no such step is treated as all sky.
    static func automaticMask(for frame: CIImage) -> SkyMask {
        let extent = frame.extent.integral
        let fullSize = extent.size
        guard let buffer = LuminanceBuffer.render(frame, maxDimension: maxDimension) else {
            return SkyMask(fullSize: CGSize(width: 1, height: 1), width: 1, height: 1, values: [1])
        }

        let profile = rowMedians(buffer)
        let horizon = horizonRow(in: profile)
        let rows = buffer.height
        let edge = max(2.0, Double(rows) / 100)

        var values = [Float](repeating: 1, count: buffer.width * rows)
        if let horizon {
            for row in 0..<rows {
                let soft = 0.5 + (Double(horizon) - (Double(row) + 0.5)) / edge
                let value = Float(min(1, max(0, soft)))
                for column in 0..<buffer.width {
                    values[row * buffer.width + column] = value
                }
            }
        }
        return SkyMask(fullSize: fullSize, width: buffer.width, height: rows, values: values)
    }

    private static func rowMedians(_ buffer: LuminanceBuffer) -> [Float] {
        (0..<buffer.height).map { row in
            let start = row * buffer.width
            let sorted = buffer.values[start..<(start + buffer.width)].sorted()
            return sorted[sorted.count / 2]
        }
    }

    /// The row where the sky ends, or nil if no convincing horizon exists.
    private static func horizonRow(in profile: [Float]) -> Int? {
        let window = max(4, profile.count / 20)
        guard profile.count >= 2 * window + 1 else { return nil }

        var prefix = [Float](repeating: 0, count: profile.count + 1)
        for i in profile.indices {
            prefix[i + 1] = prefix[i] + profile[i]
        }
        func mean(_ from: Int, _ to: Int) -> Float {
            (prefix[to] - prefix[from]) / Float(to - from)
        }

        var best: (row: Int, step: Float, above: Float)?
        for row in window...(profile.count - window) {
            let above = mean(row - window, row)
            let below = mean(row, row + window)
            let step = above - below
            if step > (best?.step ?? 0) {
                best = (row, step, above)
            }
        }

        guard let best, best.above > 1e-6, best.step / best.above > minimumRelativeContrast else {
            return nil
        }
        return best.row
    }
}
