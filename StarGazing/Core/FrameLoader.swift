import CoreImage
import Foundation
import ImageIO

/// Supplies the encoded bytes for a frame. The app implements this over
/// PHImageManager; tests supply fixed data.
nonisolated protocol FrameSource: Sendable {
    func data(for frameID: UUID) async throws -> Data
}

nonisolated enum BatchKind: Sendable {
    case raw
    case lossy
}

nonisolated enum FrameLoaderError: Error, Equatable {
    case empty
    case mixedFormats
    case mixedSizes
}

nonisolated struct LoadedFrame: Sendable {
    let id: UUID
    /// Linear light, in the sensor's own orientation. Every frame of a shoot shares it, even when
    /// the orientation tag flips between shots (a phone on a tripod pointing at the sky).
    let linear: CIImage
    /// The file's own orientation tag, used to orient the finished image the way the user shot it.
    let orientation: CGImagePropertyOrientation
}

nonisolated struct LoadedBatch: Sendable {
    let frames: [LoadedFrame]
    let kind: BatchKind
    let width: Int
    let height: Int
    let unreadable: [UUID: FrameFailure]

    var bitDepth: Int {
        kind == .raw ? 16 : 8
    }
}

nonisolated enum FrameLoader {

    static func validate(_ frames: [Frame]) throws -> BatchKind {
        guard let first = frames.first else {
            throw FrameLoaderError.empty
        }
        guard frames.allSatisfy({ $0.isRAW == first.isRAW }) else {
            throw FrameLoaderError.mixedFormats
        }
        // Photos reports display-oriented sizes, so a portrait and a landscape tag on the same
        // sensor data differ. Compare the sizes without regard to which way is up.
        func shape(_ frame: Frame) -> [Int] { [min(frame.width, frame.height), max(frame.width, frame.height)] }
        guard frames.allSatisfy({ shape($0) == shape(first) }) else {
            throw FrameLoaderError.mixedSizes
        }
        return first.isRAW ? .raw : .lossy
    }

    /// Frames that cannot be read are listed in `unreadable` and do not fail the batch.
    static func load(_ frames: [Frame], source: FrameSource) async throws -> LoadedBatch {
        let kind = try validate(frames)
        var loaded: [LoadedFrame] = []
        var unreadable: [UUID: FrameFailure] = [:]

        for frame in frames {
            do {
                let bytes = try await source.data(for: frame.id)
                let decoded = try decode(bytes, isRAW: frame.isRAW)
                loaded.append(LoadedFrame(id: frame.id, linear: decoded.image, orientation: decoded.orientation))
            } catch let failure as FrameFailure {
                unreadable[frame.id] = failure
            } catch {
                unreadable[frame.id] = .unreadable(error.localizedDescription)
            }
        }

        // The decoded size is the truth for cropping; Photos metadata is display-oriented.
        let size = loaded.first?.linear.extent.size ?? CGSize(width: frames[0].width, height: frames[0].height)
        return LoadedBatch(
            frames: loaded,
            kind: kind,
            width: Int(size.width),
            height: Int(size.height),
            unreadable: unreadable
        )
    }

    private static func decode(_ data: Data, isRAW: Bool) throws -> (image: CIImage, orientation: CGImagePropertyOrientation) {
        if isRAW {
            guard let raw = CIRAWFilter(imageData: data, identifierHint: nil) else {
                throw FrameFailure.unreadable("RAW decode failed")
            }
            let tag = raw.orientation
            raw.orientation = .up
            // Stacking needs linear sensor data, not a finished photo. Switch off the decoder's
            // global and local tone curves and its noise reduction (which would smooth faint stars
            // before they are stacked).
            raw.boostAmount = 0
            raw.localToneMapAmount = 0
            raw.luminanceNoiseReductionAmount = 0
            raw.colorNoiseReductionAmount = 0
            raw.sharpnessAmount = 0
            guard let image = raw.outputImage else {
                throw FrameFailure.unreadable("RAW decode failed")
            }
            return (image, tag)
        }
        // Core Image already colour-matches into its linear working space when it decodes a
        // JPEG/HEIC, so no further conversion is wanted here.
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: false]) else {
            throw FrameFailure.unreadable("image decode failed")
        }
        let raw = (image.properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value
        return (image, raw.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up)
    }
}
