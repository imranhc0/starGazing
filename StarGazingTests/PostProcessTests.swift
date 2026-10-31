import XCTest
import CoreImage
import ImageIO
@testable import StarGazing

final class PostProcessTests: XCTestCase {

    private func shift(_ tx: Double, _ ty: Double) -> AlignmentTransform {
        AlignmentTransform(a: 1, b: 0, tx: tx, ty: ty)
    }

    // MARK: - Common crop

    func testCropIsIntersectionOfShiftedFrames() {
        let rect = PostProcess.commonCropRect(
            for: [shift(10, 0), shift(-6, 4)],
            size: CGSize(width: 1000, height: 800)
        )
        XCTAssertEqual(rect, CGRect(x: 10, y: 4, width: 984, height: 796))
    }

    func testCropTreatsMissingTransformAsIdentity() {
        let rect = PostProcess.commonCropRect(
            for: [nil, shift(5, 0)],
            size: CGSize(width: 1000, height: 800)
        )
        XCTAssertEqual(rect, CGRect(x: 5, y: 0, width: 995, height: 800))
    }

    func testCropShrinksForRotationButStaysInsideTheFrame() {
        let angle = 1.0 * Double.pi / 180
        let rotated = AlignmentTransform(a: cos(angle), b: sin(angle), tx: 0, ty: 0)
        let rect = PostProcess.commonCropRect(for: [rotated], size: CGSize(width: 1000, height: 800))

        XCTAssertLessThan(rect.width, 1000)
        XCTAssertGreaterThan(rect.width, 950)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1000, height: 800).contains(rect))
    }

    // MARK: - Export format

    func testRawBatchExportsSixteenBitTiff() {
        XCTAssertEqual(ExportFormat(for: .raw), .tiff16)
    }

    func testLossyBatchExportsEightBitJpeg() {
        XCTAssertEqual(ExportFormat(for: .lossy), .jpeg)
    }

    func testTiffExportIsSixteenBit() throws {
        let url = temporaryURL("tiff")
        try PostProcess.export(TestImages.constant(0.2, width: 16, height: 16), format: .tiff16, to: url)
        XCTAssertEqual(try bitDepth(of: url), 16)
    }

    func testJpegExportIsEightBit() throws {
        let url = temporaryURL("jpg")
        try PostProcess.export(TestImages.constant(0.2, width: 16, height: 16), format: .jpeg, to: url)
        XCTAssertEqual(try bitDepth(of: url), 8)
    }

    // MARK: - Blend and stretch

    func testBlendTakesSkyWhereMaskIsOneAndForegroundWhereItIsZero() {
        let sky = TestImages.constant(1, width: 64, height: 64)
        let foreground = TestImages.constant(0, width: 64, height: 64)
        let allSky = SkyMasker.automaticMask(for: TestImages.constant(0.1, width: 64, height: 64))
        let mask = allSky.painting([CGPoint(x: 10, y: 10)], radius: 8, sky: false)

        let out = PostProcess.blend(
            sky: sky, foreground: foreground, mask: mask,
            settings: PostSettings(stretch: 0, denoise: 0, stretchPower: 1)
        )

        XCTAssertEqual(TestImages.pixel(out, 50, 50).r, 1, accuracy: 0.02)
        XCTAssertEqual(TestImages.pixel(out, 10, 10).r, 0, accuracy: 0.02)
    }

    func testAutomaticSettingsBrightenADarkImage() {
        let dark = TestImages.constant(0.01, width: 64, height: 64)
        let settings = PostSettings.automatic(for: dark)

        XCTAssertLessThan(settings.stretchPower, 1)
        let out = PostProcess.finish(dark, settings: settings)
        XCTAssertGreaterThan(TestImages.pixel(out, 10, 10).r, 0.05)
    }

    func testZeroStrengthLeavesImageUnchanged() {
        let image = TestImages.constant(0.3, width: 32, height: 32)
        let out = PostProcess.finish(image, settings: PostSettings(stretch: 0, denoise: 0, stretchPower: 0.4))

        XCTAssertEqual(TestImages.pixel(out, 5, 5).r, 0.3, accuracy: 0.005)
    }

    // MARK: - Helpers

    private func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("post-\(UUID().uuidString).\(ext)")
    }

    private func bitDepth(of url: URL) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return try XCTUnwrap(properties[kCGImagePropertyDepth] as? Int)
    }
}
