import CoreImage

nonisolated enum FloatContext {
    /// A context that computes in 32-bit float. The default working format is half-float
    /// (about three decimal digits), which is too coarse for stacking and 16-bit export.
    static func make() -> CIContext {
        CIContext(options: [.workingFormat: CIFormat.RGBAf])
    }
}
