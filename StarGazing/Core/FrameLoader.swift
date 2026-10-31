import CoreImage
import Foundation

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
    let linear: CIImage
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
        guard frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
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
                let image = try decode(bytes, isRAW: frame.isRAW)
                loaded.append(LoadedFrame(id: frame.id, linear: image))
            } catch let failure as FrameFailure {
                unreadable[frame.id] = failure
            } catch {
                unreadable[frame.id] = .unreadable(error.localizedDescription)
            }
        }

        return LoadedBatch(
            frames: loaded,
            kind: kind,
            width: frames[0].width,
            height: frames[0].height,
            unreadable: unreadable
        )
    }

    private static func decode(_ data: Data, isRAW: Bool) throws -> CIImage {
        if isRAW {
            guard let raw = CIRAWFilter(imageData: data, identifierHint: nil),
                  let image = raw.outputImage else {
                throw FrameFailure.unreadable("RAW decode failed")
            }
            return image
        }
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw FrameFailure.unreadable("image decode failed")
        }
        // Core Image's working space is linear, so this puts JPEG/HEIC in the same space as RAW.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        return image.matchedToWorkingSpace(from: sRGB) ?? image
    }
}
