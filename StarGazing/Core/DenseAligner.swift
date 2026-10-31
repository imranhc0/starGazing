import CoreImage
import Foundation

/// Lines one picture up with another by looking at the picture itself (its edges and detail), not
/// at stars. This is what a handheld burst needs: the whole scene shifts and turns a little between
/// shots. It is the classic Lucas–Kanade method on an image pyramid, fitting a shift, a small
/// rotation and a tiny scale change, with a robust weighting so that something that moved on its
/// own (a passing car) does not drag the answer.
nonisolated enum DenseAligner {
    /// The pictures are reduced to this long side first. Fine detail is not needed to find the
    /// motion, and a 36-megapixel frame would be slow to work through.
    static let workingSize = 2048
    /// Only the strongest edges are used at each level, so the cost does not grow with the picture.
    static let maximumPointsPerLevel = 30_000
    private static let smallestLevelSide = 64
    private static let maximumLevels = 7

    /// A grid of brightness values (row 0 at the top).
    private struct Plane {
        let width: Int
        let height: Int
        var values: [Float]
    }

    /// A point of the reference picture to compare: where it is (measured from the picture's
    /// centre, in that level's pixels) and how bright it is.
    private struct Point {
        let u: Float
        let v: Float
        let value: Float
    }

    /// The motion that maps `frame` onto `reference`, in the same form as the star aligner's:
    /// `x' = a·x − b·y + tx`, `y' = b·x + a·y + ty` in Core Image coordinates, in full-size pixels.
    /// `region` limits which part of the reference is used to find the motion, as fractions of the
    /// picture with the origin at the bottom left (so the ground of a skyline is `y` from 0).
    /// Returns nil when the pictures do not really match.
    static func transform(from frame: CIImage, to reference: CIImage, region: CGRect? = nil) -> AlignmentTransform? {
        let extent = reference.extent.integral
        guard extent.width > 0, extent.height > 0,
              let referenceBuffer = LuminanceBuffer.render(reference, maxDimension: workingSize),
              let frameBuffer = LuminanceBuffer.render(frame, maxDimension: workingSize),
              referenceBuffer.width == frameBuffer.width,
              referenceBuffer.height == frameBuffer.height,
              min(referenceBuffer.width, referenceBuffer.height) >= 32 else {
            return nil
        }
        let width = referenceBuffer.width
        let height = referenceBuffer.height

        let referencePyramid = pyramid(of: normalised(referenceBuffer))
        let framePyramid = pyramid(of: normalised(frameBuffer))

        // Where to look, as fractions of the picture with row 0 at the top.
        let area = region.map {
            (x0: Double($0.minX), x1: Double($0.maxX), y0: 1 - Double($0.maxY), y1: 1 - Double($0.minY))
        } ?? (x0: 0, x1: 1, y0: 0, y1: 1)

        // The motion mapping reference positions to frame positions: x' = a·u − b·v + tu, y' = b·u + a·v + tv
        // with u, v measured from the centre of the level. Start from "no motion" at the coarsest level.
        var a = 1.0, b = 0.0, tu = 0.0, tv = 0.0
        var correlationAtStart = 0.0
        var correlationAtEnd = 0.0

        for level in stride(from: referencePyramid.count - 1, through: 0, by: -1) {
            let referencePlane = referencePyramid[level]
            let framePlane = framePyramid[level]
            let points = strongestPoints(in: referencePlane, area: area)
            guard points.count >= 50 else { return nil }

            if level == 0 {
                correlationAtStart = correlation(points, framePlane, a: 1, b: 0, tu: 0, tv: 0)
            }
            let iterations = level == 0 ? 15 : 40
            refine(&a, &b, &tu, &tv, points: points, frame: framePlane, iterations: iterations)
            if level == 0 {
                correlationAtEnd = correlation(points, framePlane, a: a, b: b, tu: tu, tv: tv)
            } else {
                // The next level has twice the pixels, so shifts double; turning and scale do not.
                tu *= 2
                tv *= 2
            }
        }

        // Accept only a clear match: well correlated, or clearly better than no motion at all.
        guard correlationAtEnd >= 0.9 || (correlationAtEnd >= 0.5 && correlationAtEnd >= correlationAtStart + 0.1) else {
            return nil
        }

        return fullSizeTransform(
            a: a, b: b, tu: tu, tv: tv,
            bufferWidth: width, bufferHeight: height, extent: extent
        )
    }

    // MARK: - Preparing the pictures

    /// Compresses the brightness range (night frames have a few very bright lights and a lot of dark)
    /// and centres it, so the comparison is about structure rather than overall brightness.
    private static func normalised(_ buffer: LuminanceBuffer) -> Plane {
        var values = buffer.values.map { max($0, 0).squareRoot() }
        let mean = values.reduce(0, +) / Float(max(values.count, 1))
        var variance: Float = 0
        for value in values { variance += (value - mean) * (value - mean) }
        let deviation = max((variance / Float(max(values.count, 1))).squareRoot(), 1e-6)
        for i in values.indices { values[i] = (values[i] - mean) / deviation }
        return Plane(width: buffer.width, height: buffer.height, values: values)
    }

    /// Finest first: each level averages 2x2 pixels of the one before.
    private static func pyramid(of base: Plane) -> [Plane] {
        var levels = [base]
        while levels.count < maximumLevels,
              let last = levels.last,
              min(last.width, last.height) / 2 >= smallestLevelSide {
            let width = last.width / 2
            let height = last.height / 2
            var values = [Float](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (2 * y) * last.width + 2 * x
                    values[y * width + x] = (
                        last.values[i] + last.values[i + 1]
                            + last.values[i + last.width] + last.values[i + last.width + 1]
                    ) / 4
                }
            }
            levels.append(Plane(width: width, height: height, values: values))
        }
        return levels
    }

    /// The pixels with the strongest edges inside `area`, capped in number.
    private static func strongestPoints(
        in plane: Plane,
        area: (x0: Double, x1: Double, y0: Double, y1: Double)
    ) -> [Point] {
        let columns = max(1, Int(area.x0 * Double(plane.width)))..<min(plane.width - 1, Int(area.x1 * Double(plane.width)))
        let rows = max(1, Int(area.y0 * Double(plane.height)))..<min(plane.height - 1, Int(area.y1 * Double(plane.height)))
        guard !columns.isEmpty, !rows.isEmpty else { return [] }

        func strength(_ x: Int, _ y: Int) -> Float {
            let i = y * plane.width + x
            return abs(plane.values[i + 1] - plane.values[i - 1]) + abs(plane.values[i + plane.width] - plane.values[i - plane.width])
        }

        // A threshold that keeps roughly the strongest 40%, estimated from a sample.
        var sample: [Float] = []
        let step = max(1, (columns.count * rows.count) / 20_000)
        var counter = 0
        for y in rows {
            for x in columns {
                if counter % step == 0 { sample.append(strength(x, y)) }
                counter += 1
            }
        }
        sample.sort()
        let threshold = sample[min(sample.count - 1, Int(Double(sample.count) * 0.6))]

        var candidates: [(x: Int, y: Int)] = []
        for y in rows {
            for x in columns where strength(x, y) > threshold {
                candidates.append((x, y))
            }
        }
        let stride = max(1, candidates.count / maximumPointsPerLevel)
        let centreX = Float(plane.width) / 2
        let centreY = Float(plane.height) / 2
        var points: [Point] = []
        points.reserveCapacity(min(candidates.count, maximumPointsPerLevel) + 1)
        var index = 0
        while index < candidates.count {
            let (x, y) = candidates[index]
            points.append(Point(
                u: Float(x) + 0.5 - centreX,
                v: Float(y) + 0.5 - centreY,
                value: plane.values[y * plane.width + x]
            ))
            index += stride
        }
        return points
    }

    // MARK: - Fitting the motion

    /// Brightness of the plane at a continuous position (a pixel's centre is at +0.5), or nil outside it.
    @inline(__always)
    private static func sample(_ plane: Plane, _ values: UnsafeBufferPointer<Float>, _ x: Float, _ y: Float) -> Float? {
        let fx = x - 0.5
        let fy = y - 0.5
        guard fx >= 0, fy >= 0, fx < Float(plane.width - 1), fy < Float(plane.height - 1) else { return nil }
        let ix = Int(fx)
        let iy = Int(fy)
        let dx = fx - Float(ix)
        let dy = fy - Float(iy)
        let i = iy * plane.width + ix
        let top = values[i] * (1 - dx) + values[i + 1] * dx
        let bottom = values[i + plane.width] * (1 - dx) + values[i + plane.width + 1] * dx
        return top * (1 - dy) + bottom * dy
    }

    /// Gauss–Newton on the four numbers, weighting each point by how well it agrees (Huber).
    private static func refine(
        _ a: inout Double, _ b: inout Double, _ tu: inout Double, _ tv: inout Double,
        points: [Point], frame: Plane, iterations: Int
    ) {
        let centreX = Double(frame.width) / 2
        let centreY = Double(frame.height) / 2

        frame.values.withUnsafeBufferPointer { values in
            for _ in 0..<iterations {
                var errors: [Float] = []
                var gradients: [(ix: Float, iy: Float, u: Float, v: Float)] = []
                errors.reserveCapacity(points.count)
                gradients.reserveCapacity(points.count)

                for point in points {
                    let u = Double(point.u), v = Double(point.v)
                    let x = Float(centreX + a * u - b * v + tu)
                    let y = Float(centreY + b * u + a * v + tv)
                    guard let here = sample(frame, values, x, y),
                          let right = sample(frame, values, x + 0.5, y), let left = sample(frame, values, x - 0.5, y),
                          let below = sample(frame, values, x, y + 0.5), let above = sample(frame, values, x, y - 0.5) else {
                        continue
                    }
                    errors.append(point.value - here)
                    gradients.append((right - left, below - above, point.u, point.v))
                }
                guard errors.count >= 50 else { return }

                // How big is a normal error? The median absolute error, scaled to a standard deviation.
                let sortedAbsolute = errors.map { abs($0) }.sorted()
                let scale = max(Double(sortedAbsolute[sortedAbsolute.count / 2]) * 1.4826, 1e-4)
                let cutoff = 1.345 * scale

                var hessian = [Double](repeating: 0, count: 16)
                var gradient = [Double](repeating: 0, count: 4)
                for (error, g) in zip(errors, gradients) {
                    let e = Double(error)
                    let weight = abs(e) <= cutoff ? 1 : cutoff / abs(e)
                    let ix = Double(g.ix), iy = Double(g.iy), u = Double(g.u), v = Double(g.v)
                    let jacobian = [ix * u + iy * v, -ix * v + iy * u, ix, iy]
                    for row in 0..<4 {
                        gradient[row] += weight * jacobian[row] * e
                        for column in 0..<4 {
                            hessian[row * 4 + column] += weight * jacobian[row] * jacobian[column]
                        }
                    }
                }
                guard let step = solve(hessian, gradient) else { return }
                a += step[0]
                b += step[1]
                tu += step[2]
                tv += step[3]
                if abs(step[2]) < 0.003, abs(step[3]) < 0.003, abs(step[0]) < 1e-6, abs(step[1]) < 1e-6 {
                    return
                }
            }
        }
    }

    /// Solves the 4x4 system by Gaussian elimination, with a touch of damping for stability.
    private static func solve(_ matrix: [Double], _ vector: [Double]) -> [Double]? {
        var m = matrix
        var v = vector
        let largest = (0..<4).map { m[$0 * 4 + $0] }.max() ?? 0
        guard largest > 0 else { return nil }
        for i in 0..<4 { m[i * 4 + i] += largest * 1e-9 }
        for column in 0..<4 {
            var pivot = column
            for row in (column + 1)..<4 where abs(m[row * 4 + column]) > abs(m[pivot * 4 + column]) { pivot = row }
            guard abs(m[pivot * 4 + column]) > 1e-12 else { return nil }
            if pivot != column {
                for k in 0..<4 { m.swapAt(column * 4 + k, pivot * 4 + k) }
                v.swapAt(column, pivot)
            }
            for row in (column + 1)..<4 {
                let factor = m[row * 4 + column] / m[column * 4 + column]
                for k in column..<4 { m[row * 4 + k] -= factor * m[column * 4 + k] }
                v[row] -= factor * v[column]
            }
        }
        var result = [Double](repeating: 0, count: 4)
        for row in stride(from: 3, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<4 { sum -= m[row * 4 + k] * result[k] }
            result[row] = sum / m[row * 4 + row]
        }
        return result
    }

    /// How alike the reference points and the moved frame are, from -1 to 1.
    private static func correlation(_ points: [Point], _ frame: Plane, a: Double, b: Double, tu: Double, tv: Double) -> Double {
        let centreX = Double(frame.width) / 2
        let centreY = Double(frame.height) / 2
        var reference: [Double] = []
        var moved: [Double] = []
        frame.values.withUnsafeBufferPointer { values in
            for point in points {
                let u = Double(point.u), v = Double(point.v)
                if let value = sample(frame, values, Float(centreX + a * u - b * v + tu), Float(centreY + b * u + a * v + tv)) {
                    reference.append(Double(point.value))
                    moved.append(Double(value))
                }
            }
        }
        guard reference.count >= 50 else { return 0 }
        let meanReference = reference.reduce(0, +) / Double(reference.count)
        let meanMoved = moved.reduce(0, +) / Double(moved.count)
        var cross = 0.0, varianceReference = 0.0, varianceMoved = 0.0
        for (r, m) in zip(reference, moved) {
            cross += (r - meanReference) * (m - meanMoved)
            varianceReference += (r - meanReference) * (r - meanReference)
            varianceMoved += (m - meanMoved) * (m - meanMoved)
        }
        let denominator = (varianceReference * varianceMoved).squareRoot()
        return denominator > 0 ? cross / denominator : 0
    }

    // MARK: - Back to the app's convention

    /// The fit maps reference to frame, measured from the centre with the origin at the top left.
    /// The app wants frame to reference, in Core Image coordinates (origin at the bottom left),
    /// in full-size pixels.
    private static func fullSizeTransform(
        a: Double, b: Double, tu: Double, tv: Double,
        bufferWidth: Int, bufferHeight: Int, extent: CGRect
    ) -> AlignmentTransform {
        let centreX = Double(bufferWidth) / 2
        let centreY = Double(bufferHeight) / 2
        // Measured from the top-left corner instead of the centre.
        let tx = tu + centreX - a * centreX + b * centreY
        let ty = tv + centreY - b * centreX - a * centreY
        // Reverse it: frame to reference.
        let determinant = a * a + b * b
        let ra = a / determinant
        let rb = -b / determinant
        let rtx = -(a * tx + b * ty) / determinant
        let rty = (b * tx - a * ty) / determinant
        // Flip the vertical axis, so that up is positive as in Core Image.
        let height = Double(bufferHeight)
        let ciB = -rb
        let ciTx = rtx - rb * height
        let ciTy = height - ra * height - rty
        // Back to full-size pixels.
        let scaleX = Double(bufferWidth) / Double(extent.width)
        let scaleY = Double(bufferHeight) / Double(extent.height)
        return AlignmentTransform(a: ra, b: ciB, tx: ciTx / scaleX, ty: ciTy / scaleY)
    }
}
