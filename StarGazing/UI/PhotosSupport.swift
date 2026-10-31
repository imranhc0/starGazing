import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// Where the app keeps checkpoints and finished stacks.
nonisolated enum AppFiles {
    static var checkpoints: URL { directory("Checkpoints") }
    static var results: URL { directory("Results") }

    private static func directory(_ name: String) -> URL {
        let base = URL.applicationSupportDirectory.appendingPathComponent("StarGazing", isDirectory: true)
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

nonisolated enum PhotosAccessError: LocalizedError {
    case denied

    var errorDescription: String? {
        "StarGazing needs access to your photos. Allow it in Settings > Privacy & Security > Photos."
    }
}

nonisolated enum PhotosLibrary {

    /// Asks for read access (limited access is enough: the picked photos stay readable).
    static func requireReadAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PhotosAccessError.denied }
    }

    /// Frame descriptions for the picked photos, in the order picked. Unknown identifiers are dropped.
    static func frames(for identifiers: [String]) -> [Frame] {
        identifiers.compactMap { identifier in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                return nil
            }
            let isRAW = PHAssetResource.assetResources(for: asset).contains {
                UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true
            }
            return Frame(
                id: UUID(),
                assetID: asset.localIdentifier,
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                isRAW: isRAW,
                exposureSeconds: 0,
                iso: 0
            )
        }
    }

    /// A screen-sized preview of a photo, for the before/after comparison.
    static func thumbnail(assetID: String, maxPixel: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            var finished = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxPixel, height: maxPixel),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: image)
            }
        }
    }
}

/// Reads the original bytes of picked photos (RAW stays RAW) from the photo library.
nonisolated struct PhotosFrameSource: FrameSource {
    private let assetIDs: [UUID: String]

    init(frames: [Frame]) {
        assetIDs = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0.assetID) })
    }

    func data(for frameID: UUID) async throws -> Data {
        guard let assetID = assetIDs[frameID],
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw FrameFailure.unreadable("This photo is no longer in your library.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .original
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: FrameFailure.unreadable("The photo could not be read."))
                }
            }
        }
    }
}

nonisolated struct SystemPhotosWriter: PhotosWriter {
    func save(imageAt url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotosAccessError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}

/// Runs stacks for the app: through the system's continued-processing task when it will take
/// the job, in the foreground when it will not.
nonisolated struct AppStackRunner: StackRunner {
    let background: BackgroundRunner

    func run(_ request: StackRequest, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> StackResult {
        try await PhotosLibrary.requireReadAccess()

        let job = StackJob(
            request: request,
            source: PhotosFrameSource(frames: request.frames),
            store: CheckpointStore(directory: AppFiles.checkpoints),
            outputDirectory: AppFiles.results
        )
        do {
            return try await background.run(
                job,
                framesTotal: request.frames.count,
                title: "Stacking your night sky",
                subtitle: "\(request.frames.count) photos",
                onProgress: progress
            )
        } catch is BackgroundRunner.SubmissionFailed {
            return try await job.run(progress: progress)
        }
    }
}
