import CoreImage
import Foundation

/// A region of the reference frame, in Core Image space (origin bottom-left, whole pixels).
nonisolated struct TileRect: Sendable, Equatable {
    let origin: CGPoint
    let size: CGSize

    var rect: CGRect { CGRect(origin: origin, size: size) }

    static func full(of extent: CGRect) -> TileRect {
        TileRect(origin: extent.origin, size: extent.size)
    }
}

/// A frame plus the transform that maps its pixels onto the reference frame.
/// `transform` is nil when the frame is already in reference coordinates (trails mode).
nonisolated struct AlignedFrame: Sendable {
    let linear: CIImage
    let transform: AlignmentTransform?
}

nonisolated struct Stacker: Sendable {
    /// Edge length of the working chunks. Peak scratch memory is about
    /// frames × tileSize² × 16 bytes (RGBA float): 200 frames at 256 is about 210 MB.
    var tileSize: Int = 256
    var clipSigma: Double = 2.5

    /// Floor on the clipping width, as a fraction of the median, so identical frames
    /// with tiny differences are not thrown away.
    static let minimumRelativeSigma: Float = 0.02
    /// A warped frame contributes to a pixel only where it fully covers it.
    static let coverageThreshold: Float = 0.999

    /// Combines the frames over `tile` and returns the result, positioned at `tile.origin`.
    /// Pixels no frame covers come back transparent.
    ///
    /// Reports progress (0 to 1) after each chunk and stops with `CancellationError` between
    /// chunks, so a long stack can show that it is alive and can be ended by the system.
    func stack(
        _ frames: [AlignedFrame],
        mode: StackMode,
        tile: TileRect,
        progress: (Double) -> Void = { _ in }
    ) throws -> CIImage {
        let rect = tile.rect.integral
        let width = Int(rect.width)
        let height = Int(rect.height)
        guard !frames.isEmpty, width > 0, height > 0 else { return CIImage.empty() }

        let warped = frames.map(Self.warped)
        let context = FloatContext.make()

        // One output buffer for the whole tile, handed to Core Image without a second copy.
        let rowBytes = width * 16
        let byteCount = rowBytes * height
        guard let output = calloc(1, byteCount) else { throw CocoaError(.fileWriteOutOfSpace) }
        var ownsOutput = true
        defer { if ownsOutput { free(output) } }

        let allChunks = chunks(of: rect)
        for (index, chunk) in allChunks.enumerated() {
            try Task.checkCancellation()

            let chunkWidth = Int(chunk.width)
            let chunkHeight = Int(chunk.height)
            let buffers = warped.map { Self.render($0, over: chunk, with: context) }
            let reduced = reduce(buffers, pixelCount: chunkWidth * chunkHeight, mode: mode)

            // Bitmap rows run top-down, so place the chunk by its top edge.
            let firstRow = Int(rect.maxY - chunk.maxY)
            let firstColumn = Int(chunk.minX - rect.minX)
            reduced.withUnsafeBytes { source in
                for row in 0..<chunkHeight {
                    let destination = output + (firstRow + row) * rowBytes + firstColumn * 16
                    memcpy(destination, source.baseAddress! + row * chunkWidth * 16, chunkWidth * 16)
                }
            }
            progress(Double(index + 1) / Double(allChunks.count))
        }

        let data = Data(bytesNoCopy: output, count: byteCount, deallocator: .free)
        ownsOutput = false
        return CIImage(
            bitmapData: data,
            bytesPerRow: rowBytes,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: nil
        )
        .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    // MARK: - Chunking and rendering

    private func chunks(of rect: CGRect) -> [CGRect] {
        let step = CGFloat(max(1, tileSize))
        var result: [CGRect] = []
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                result.append(CGRect(
                    x: x, y: y,
                    width: min(step, rect.maxX - x),
                    height: min(step, rect.maxY - y)
                ))
                x += step
            }
            y += step
        }
        return result
    }

    /// Frame → reference coordinates. The transform maps frame points onto the reference,
    /// so it applies directly: x' = a·x − b·y + tx, y' = b·x + a·y + ty.
    private static func warped(_ frame: AlignedFrame) -> CIImage {
        guard let t = frame.transform else { return frame.linear }
        let affine = CGAffineTransform(a: t.a, b: t.b, c: -t.b, d: t.a, tx: t.tx, ty: t.ty)
        return frame.linear.samplingLinear().transformed(by: affine)
    }

    private static func render(_ image: CIImage, over chunk: CGRect, with context: CIContext) -> [Float] {
        let width = Int(chunk.width)
        let height = Int(chunk.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(
                image,
                toBitmap: buffer.baseAddress!,
                rowBytes: width * 16,
                bounds: chunk,
                format: .RGBAf,
                colorSpace: nil
            )
        }
        return pixels
    }

    // MARK: - Per-pixel combination

    private func reduce(_ buffers: [[Float]], pixelCount: Int, mode: StackMode) -> [Float] {
        var output = [Float](repeating: 0, count: pixelCount * 4)
        var values = [Float](repeating: 0, count: buffers.count)
        var deviations = [Float](repeating: 0, count: buffers.count)

        for pixel in 0..<pixelCount {
            let base = pixel * 4
            var count = 0
            for buffer in buffers where buffer[base + 3] >= Self.coverageThreshold {
                count += 1
            }
            guard count > 0 else { continue }

            for channel in 0..<3 {
                var n = 0
                for buffer in buffers where buffer[base + 3] >= Self.coverageThreshold {
                    values[n] = buffer[base + channel]
                    n += 1
                }
                output[base + channel] = combine(&values, &deviations, count: n, mode: mode)
            }
            output[base + 3] = 1
        }
        return output
    }

    private func combine(_ values: inout [Float], _ deviations: inout [Float], count: Int, mode: StackMode) -> Float {
        switch mode {
        case .trails:
            return values[0..<count].max() ?? 0
        case .median:
            values[0..<count].sort()
            return Self.median(of: values, count: count)
        case .mean:
            return clippedMean(&values, &deviations, count: count)
        }
    }

    /// Mean after discarding values further than `clipSigma` robust deviations from the median.
    /// Centring on the median and scaling by the MAD still works with few frames, where a
    /// mean/standard-deviation clip cannot reject an outlier (with 5 frames no value can be
    /// further than 2σ from a mean that includes it).
    private func clippedMean(_ values: inout [Float], _ deviations: inout [Float], count: Int) -> Float {
        guard count >= 3 else {
            return values[0..<count].reduce(0, +) / Float(count)
        }

        values[0..<count].sort()
        let median = Self.median(of: values, count: count)
        for i in 0..<count {
            deviations[i] = abs(values[i] - median)
        }
        deviations[0..<count].sort()
        let mad = Self.median(of: deviations, count: count)
        let sigma = max(1.4826 * mad, Self.minimumRelativeSigma * abs(median) + 1e-6)
        let limit = Float(clipSigma) * sigma

        var sum: Float = 0
        var kept = 0
        for i in 0..<count where abs(values[i] - median) <= limit {
            sum += values[i]
            kept += 1
        }
        return kept > 0 ? sum / Float(kept) : median
    }

    /// Median of the first `count` values, which must already be sorted.
    private static func median(of sorted: [Float], count: Int) -> Float {
        count % 2 == 1
            ? sorted[count / 2]
            : (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }
}
