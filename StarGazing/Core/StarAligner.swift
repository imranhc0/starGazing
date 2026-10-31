import Foundation

/// A similarity transform (rotation, uniform scale, translation) that maps
/// points of `from` onto `to`: x' = a·x − b·y + tx, y' = b·x + a·y + ty.
nonisolated struct AlignmentTransform: Sendable, Equatable {
    let a: Double
    let b: Double
    let tx: Double
    let ty: Double

    func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        (a * x - b * y + tx, b * x + a * y + ty)
    }
}

nonisolated enum StarAligner {
    static let minimumStars = 4
    /// Brightest stars used to generate two-point match hypotheses.
    static let hypothesisPool = 30
    /// Brightest stars used for inlier counting and the final fit.
    static let inlierPool = 150
    static let inlierTolerance = 2.0
    static let scaleTolerance = 0.005

    static func transform(from: [StarCentroid], to: [StarCentroid]) throws -> AlignmentTransform {
        guard from.count >= minimumStars, to.count >= minimumStars else {
            throw FrameFailure.tooFewStars(found: from.count)
        }

        let source = brightest(from, inlierPool)
        let target = brightest(to, inlierPool)
        let sourcePool = Array(source.prefix(hypothesisPool))
        let targetPool = Array(target.prefix(hypothesisPool))

        var best: (transform: AlignmentTransform, inliers: Int)?
        for i in sourcePool.indices {
            for j in sourcePool.indices where j > i {
                let p1 = sourcePool[i]
                let p2 = sourcePool[j]
                let sourceDistance = distance(p1, p2)
                guard sourceDistance > 1 else { continue }

                for k in targetPool.indices {
                    for l in targetPool.indices where l != k {
                        let q1 = targetPool[k]
                        let q2 = targetPool[l]
                        let targetDistance = distance(q1, q2)
                        guard abs(targetDistance - sourceDistance) / sourceDistance < scaleTolerance else {
                            continue
                        }
                        let candidate = twoPointTransform(p1: p1, p2: p2, q1: q1, q2: q2)
                        let count = inlierPairs(of: candidate, source: source, target: target).count
                        if count > (best?.inliers ?? 0) {
                            best = (candidate, count)
                        }
                    }
                }
            }
        }

        guard let winner = best, winner.inliers >= minimumStars else {
            throw FrameFailure.misaligned
        }

        let pairs = inlierPairs(of: winner.transform, source: source, target: target)
        return leastSquaresFit(pairs)
    }

    // MARK: - Hypotheses and fit

    private static func brightest(_ stars: [StarCentroid], _ count: Int) -> [StarCentroid] {
        Array(stars.sorted { $0.flux > $1.flux }.prefix(count))
    }

    private static func distance(_ a: StarCentroid, _ b: StarCentroid) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Similarity that maps p1→q1 and p2→q2, using complex arithmetic: z' = a·z + t.
    private static func twoPointTransform(
        p1: StarCentroid, p2: StarCentroid, q1: StarCentroid, q2: StarCentroid
    ) -> AlignmentTransform {
        let a = complexDivide(
            (q2.x - q1.x, q2.y - q1.y),
            (p2.x - p1.x, p2.y - p1.y)
        )
        let ap1 = complexMultiply(a, (p1.x, p1.y))
        return AlignmentTransform(a: a.0, b: a.1, tx: q1.x - ap1.0, ty: q1.y - ap1.1)
    }

    /// Source stars that land within `inlierTolerance` of a target star, paired with that target star.
    private static func inlierPairs(
        of transform: AlignmentTransform, source: [StarCentroid], target: [StarCentroid]
    ) -> [(StarCentroid, StarCentroid)] {
        var pairs: [(StarCentroid, StarCentroid)] = []
        for star in source {
            let mapped = transform.apply(x: star.x, y: star.y)
            var nearest: (StarCentroid, Double)?
            for candidate in target {
                let dx = mapped.x - candidate.x
                let dy = mapped.y - candidate.y
                let d = (dx * dx + dy * dy).squareRoot()
                if d <= inlierTolerance, d < (nearest?.1 ?? .infinity) {
                    nearest = (candidate, d)
                }
            }
            if let nearest {
                pairs.append((star, nearest.0))
            }
        }
        return pairs
    }

    /// Least-squares similarity over matched pairs. Optimal a = Σ conj(p̃)·q̃ / Σ|p̃|², t = q̄ − a·p̄.
    private static func leastSquaresFit(_ pairs: [(StarCentroid, StarCentroid)]) -> AlignmentTransform {
        let n = Double(pairs.count)
        let pMean = pairs.reduce((0.0, 0.0)) { ($0.0 + $1.0.x / n, $0.1 + $1.0.y / n) }
        let qMean = pairs.reduce((0.0, 0.0)) { ($0.0 + $1.1.x / n, $0.1 + $1.1.y / n) }

        var numerator = (0.0, 0.0)
        var denominator = 0.0
        for (p, q) in pairs {
            let pc = (p.x - pMean.0, p.y - pMean.1)
            let qc = (q.x - qMean.0, q.y - qMean.1)
            let product = complexMultiply((pc.0, -pc.1), qc)
            numerator = (numerator.0 + product.0, numerator.1 + product.1)
            denominator += pc.0 * pc.0 + pc.1 * pc.1
        }

        let a = denominator > 0 ? (numerator.0 / denominator, numerator.1 / denominator) : (1, 0)
        let ap = complexMultiply(a, pMean)
        return AlignmentTransform(a: a.0, b: a.1, tx: qMean.0 - ap.0, ty: qMean.1 - ap.1)
    }

    // MARK: - Complex arithmetic on (re, im) pairs

    private static func complexMultiply(_ u: (Double, Double), _ v: (Double, Double)) -> (Double, Double) {
        (u.0 * v.0 - u.1 * v.1, u.0 * v.1 + u.1 * v.0)
    }

    private static func complexDivide(_ u: (Double, Double), _ v: (Double, Double)) -> (Double, Double) {
        let denominator = v.0 * v.0 + v.1 * v.1
        let numerator = complexMultiply(u, (v.0, -v.1))
        return (numerator.0 / denominator, numerator.1 / denominator)
    }
}
