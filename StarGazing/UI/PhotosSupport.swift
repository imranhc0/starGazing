import Foundation
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Where the app keeps checkpoints and finished stacks. None of it belongs in a backup: it is
/// working data, and a finished stack can be hundreds of megabytes.
nonisolated enum AppFiles {
    static var checkpoints: URL { directory("Checkpoints") }
    static var pending: URL { directory("Pending") }
    static var results: URL { directory("Results") }

    /// A finished stack that was never saved or cleared is kept this long.
    static let resultLifetime: TimeInterval = 7 * 24 * 3600

    private static func directory(_ name: String) -> URL {
        let base = URL.applicationSupportDirectory.appendingPathComponent("StarGazing", isDirectory: true)
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        excludeFromBackup(url)
        return url
    }

    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    /// Deletes files in `directory` last modified more than `age` seconds ago.
    static func purge(_ directory: URL, olderThan age: TimeInterval) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > age {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func purgeOldResults() {
        purge(results, olderThan: resultLifetime)
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

    /// Opens the system sheet where the user chooses which photos StarGazing may see, for the
    /// limited-access case.
    @MainActor
    static func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }

    /// Frame descriptions for the picked photos, in the order picked. Photos the app is not allowed
    /// to read (limited access) are left out; the caller compares counts and tells the user.
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
