# StarGazing Star Stacking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an iOS 26 app that stacks 5–200 night-sky photos (RAW, JPEG, HEIC) from the Photos library into one image, with mean, median, and star-trail modes, background processing, resumable checkpoints, and an animation-heavy UI.

**Architecture:** A pure-Swift processing core (decode, detect, align, mask, stack, post, export) with no UI imports, driven by a `StackJob` actor that checkpoints after each frame and runs under `BGContinuedProcessingTask`. SwiftUI sits on top, observing job state through an `@Observable` view model. Heavy image math uses Core Image and Metal where it pays off, with tiling so memory stays bounded on 6 GB devices.

**Tech Stack:** Swift 6, SwiftUI, Observation, Core Image (RAW via `CIRAWFilter`), Metal, Accelerate, Vision (fallback registration), Photos / PhotosUI, BackgroundTasks (`BGContinuedProcessingTask`), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-31-star-stacking-design.md`

## Global Constraints

- Minimum deployment target: iOS 26.
- Devices: iPhone 12 Pro and newer must run the app (A14, 6 GB RAM).
- Processing is on-device only. No network calls.
- Batch size: 5–200 frames. A run needs at least 5 usable frames after rejection.
- Mixed RAW and JPEG/HEIC batches are rejected. Mixed frame sizes are rejected.
- Output: 16-bit TIFF for RAW-only batches; 8-bit JPEG for JPEG/HEIC-only batches.
- Target: about 2 minutes for 100 frames of 48MP RAW on iPhone 12 Pro (a goal to measure, not a hard limit).
- Free in v1. No purchase flow.
- Max (star trail) mode does not align frames. Mean and median modes align first.
- Motion respects Reduce Motion, with a static fallback.

## Review Focus

1. A frame with clouds or too few stars is in the batch: it is skipped with its reason, and the run continues if at least 5 frames remain. Test in Task 4 and Task 8.
2. The user grants only limited Photos access: the picker still works and the run reports how many frames it could read. Test in Task 2.
3. RAW or HEIC frames with different EXIF orientation: all frames are normalized to the same orientation before alignment. Test in Task 2.
4. The app is killed mid-run and the checkpoint file is truncated or corrupt: the run restarts cleanly from frame 0 instead of crashing. Test in Task 8.
5. Saving the export fails (storage full or Photos write denied): the result is kept in the app's storage, and the user sees a retry option. Test in Task 9.

## File Structure

- `StarGazing/Core/Models.swift` — `Frame`, `StackMode`, `StackRequest`, `FrameFailure`, `StackResult`.
- `StarGazing/Core/FrameLoader.swift` — loads and validates a batch from Photos into linear-light buffers.
- `StarGazing/Core/StarDetector.swift` — star centroid detection.
- `StarGazing/Core/StarAligner.swift` — star-pattern matching, returns a transform.
- `StarGazing/Core/SkyMask.swift` — automatic sky mask and brush corrections.
- `StarGazing/Core/Stacker.swift` — tiled mean, median, and max stacking with sigma clipping.
- `StarGazing/Core/PostProcess.swift` — stretch, denoise, sky/foreground blend, crop, export encoding.
- `StarGazing/Job/StackJob.swift` — the actor that runs the pipeline and writes checkpoints.
- `StarGazing/Job/CheckpointStore.swift` — read and write checkpoints under Application Support.
- `StarGazing/Job/BackgroundRunner.swift` — wraps `StackJob` in `BGContinuedProcessingTask`.
- `StarGazing/UI/` — picker, run view, result view, before/after slider, view model.
- `StarGazing/Assets.xcassets/AppIcon.appiconset` — icon.
- `StarGazingTests/` — XCTest target, one file per core unit.

## Task 1: Spike (throwaway, not merged)

**Files:**
- Create: `Spike/StackSpike.swift` (not added to the app target)

**Interfaces:**
- Consumes: 10 JPEG frames from the simulator or a device.
- Produces: a measured time per frame for star detection, alignment, and mean stacking on iPhone 12 Pro, recorded in the commit message.

- [ ] **Step 1: Write a standalone command-line or Playground stack of 10 JPEG frames**

Align by translation only and mean-stack. No UI, no tests. Keep it under 150 lines.

- [ ] **Step 2: Run it on an iPhone 12 Pro**

Expected: a stacked JPEG is written and the per-frame timing is printed.

- [ ] **Step 3: Record the result and decide**

If per-frame time is over 3 seconds, note in the design that tiling and GPU work are required from the start. Otherwise, keep the plan as written.

- [ ] **Step 4: Discard the spike code**

Do not commit it to the app target. Commit only the findings to `docs/superpowers/specs/` as a dated note.

## Task 2: Project setup and models

**Files:**
- Modify: `StarGazing.xcodeproj` (deployment target 26.0; add `StarGazingTests` XCTest target)
- Modify: `StarGazing/Info.plist` or the target's Info settings: `BGTaskSchedulerPermittedIdentifiers` with the continued-processing identifier, `NSPhotoLibraryAddUsageDescription`
- Create: `StarGazing/Core/Models.swift`
- Test: `StarGazingTests/ModelsTests.swift`

**Interfaces:**
- Produces:
  - `enum StackMode { case mean, median, trails }`
  - `struct Frame { let id: UUID; let assetID: String; let width: Int; let height: Int; let isRAW: Bool; let exposureSeconds: Double; let iso: Double }`
  - `enum FrameFailure { case tooFewStars(found: Int), noStars, misaligned, outOfFocus, unreadable(String) }`
  - `struct StackRequest { let frames: [Frame]; let mode: StackMode }`
  - `struct StackResult { let outputURL: URL; let usedFrameIDs: [UUID]; let failures: [UUID: FrameFailure] }`

- [ ] **Step 1: Write the failing test**

```swift
func testStackRequestRejectsFewerThanFiveFrames() {
    XCTAssertThrowsError(try StackRequest.validated(frames: fixtureFrames(count: 4), mode: .mean))
}
func testStackRequestAcceptsTwoHundredFrames() throws {
    XCTAssertNoThrow(try StackRequest.validated(frames: fixtureFrames(count: 200), mode: .mean))
}
func testStackRequestRejectsTwoHundredOneFrames() {
    XCTAssertThrowsError(try StackRequest.validated(frames: fixtureFrames(count: 201), mode: .mean))
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `xcodebuild test -scheme StarGazing -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StarGazingTests/ModelsTests`
Expected: FAIL, `StackRequest` not defined.

- [ ] **Step 3: Implement the models and `StackRequest.validated(frames:mode:)`**

Implement the types listed under Interfaces. `validated` checks the 5–200 count.

- [ ] **Step 4: Run the tests and confirm they pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add StarGazing.xcodeproj StarGazing/Core/Models.swift StarGazingTests/ModelsTests.swift StarGazing/Info.plist
git commit -m "feat: project setup, iOS 26 target, core models"
```

## Task 3: Frame loading and batch validation

**Files:**
- Create: `StarGazing/Core/FrameLoader.swift`
- Test: `StarGazingTests/FrameLoaderTests.swift`

**Interfaces:**
- Consumes: `Frame`, `StackRequest`
- Produces:
  - `struct LoadedBatch { let frames: [LoadedFrame]; let bitDepth: Int; let width: Int; let height: Int }`
  - `struct LoadedFrame { let id: UUID; let linear: CIImage }`
  - `enum FrameLoader { static func validate(_ frames: [Frame]) throws -> BatchKind; static func load(_ frames: [Frame]) async throws -> LoadedBatch }`
  - `enum BatchKind { case raw, lossy }` where `.raw` → 16-bit, `.lossy` → 8-bit.

- [ ] **Step 1: Write the failing tests**

```swift
func testMixedRawAndJpegIsRejected() {
    XCTAssertThrowsError(try FrameLoader.validate([rawFrame(), jpegFrame()]))
}
func testMixedSizesAreRejected() {
    XCTAssertThrowsError(try FrameLoader.validate([frame(w: 4000, h: 3000), frame(w: 4032, h: 3024)]))
}
func testRawOnlyBatchIsSixteenBit() throws {
    XCTAssertEqual(try FrameLoader.validate([rawFrame(), rawFrame()]), .raw)
}
func testJpegAndHeicBatchIsEightBit() throws {
    XCTAssertEqual(try FrameLoader.validate([jpegFrame(), heicFrame()]), .lossy)
}
func testOrientationIsNormalizedToUpright() async throws {
    let batch = try await FrameLoader.load([rotatedHeicFrame(exifOrientation: 6), uprightHeicFrame()])
    XCTAssertEqual(batch.frames[0].linear.extent.size, batch.frames[1].linear.extent.size)
}
```

Fixtures: small generated files checked into `StarGazingTests/Fixtures/`, one RAW DNG, one JPEG, one HEIC, and one rotated HEIC.

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `xcodebuild test -scheme StarGazing -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StarGazingTests/FrameLoaderTests`
Expected: FAIL, `FrameLoader` not defined.

- [ ] **Step 3: Implement the loader**

Use `PHImageManager` for the Photos request, `CIRAWFilter` for DNG, and `CIImage(data:)` for JPEG and HEIC. Apply the EXIF orientation with `CIImage.oriented(_:)` and convert to linear light (`CGColorSpace.linearSRGB`). Validation runs before any decoding.

- [ ] **Step 4: Run the tests and confirm they pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add StarGazing/Core/FrameLoader.swift StarGazingTests/FrameLoaderTests.swift StarGazingTests/Fixtures
git commit -m "feat: frame loading with batch validation and orientation"
```

## Task 4: Star detection and alignment

**Files:**
- Create: `StarGazing/Core/StarDetector.swift`, `StarGazing/Core/StarAligner.swift`
- Test: `StarGazingTests/StarAlignmentTests.swift`

**Interfaces:**
- Consumes: `LoadedFrame`
- Produces:
  - `struct StarCentroid { let x: Double; let y: Double; let flux: Double }`
  - `enum StarDetector { static func detect(in frame: CIImage) -> [StarCentroid] }`
  - `struct AlignmentTransform { let a, b, tx, ty: Double }` (similarity: rotation and scale plus translation)
  - `enum StarAligner { static func transform(from: [StarCentroid], to: [StarCentroid]) throws -> AlignmentTransform }` throws `FrameFailure`.

- [ ] **Step 1: Write the failing tests**

```swift
func testDetectsSyntheticStarsWithinHalfPixel() {
    let stars = StarDetector.detect(in: syntheticField(points: [(100, 100), (400, 220), (250, 330)]))
    XCTAssertEqual(stars.count, 3)
    for (expected, found) in zip([(100.0, 100.0), (400, 220), (250, 330)], stars.sorted(by: { $0.x < $1.x })) {
        XCTAssertEqual(found.x, expected.0, accuracy: 0.5)
        XCTAssertEqual(found.y, expected.1, accuracy: 0.5)
    }
}
func testRecoversTranslationWithinTenthOfPixel() throws {
    let t = try StarAligner.transform(from: shifted(field, dx: 12.4, dy: -7.1), to: field)
    XCTAssertEqual(t.tx, 12.4, accuracy: 0.1)
    XCTAssertEqual(t.ty, -7.1, accuracy: 0.1)
}
func testRecoversSmallRotation() throws {
    let t = try StarAligner.transform(from: rotated(field, degrees: 0.3), to: field)
    XCTAssertEqual(atan2(t.b, t.a) * 180 / .pi, -0.3, accuracy: 0.02)
}
func testFrameWithTooFewStarsReportsFailure() {
    XCTAssertThrowsError(try StarAligner.transform(from: cloudyField(), to: field)) {
        XCTAssertEqual($0 as? FrameFailure, .tooFewStars(found: 2))
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `xcodebuild test -scheme StarGazing -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StarGazingTests/StarAlignmentTests`
Expected: FAIL, types not defined.

- [ ] **Step 3: Implement detection and alignment**

Detection: local-maximum search on a Gaussian-blurred luminance image with a threshold, then sub-pixel centroiding. Alignment: triangle-pattern matching between the two star sets, then a least-squares similarity fit over the matched pairs. Fewer than 4 matched pairs throws `.tooFewStars`.

- [ ] **Step 4: Run the tests and confirm they pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add StarGazing/Core/StarDetector.swift StarGazing/Core/StarAligner.swift StarGazingTests/StarAlignmentTests.swift
git commit -m "feat: star detection and similarity alignment"
```

## Task 5: Sky masking

**Files:**
- Create: `StarGazing/Core/SkyMask.swift`
- Test: `StarGazingTests/SkyMaskTests.swift`

**Interfaces:**
- Consumes: `LoadedFrame`
- Produces:
  - `struct SkyMask { let image: CIImage }` (1 = sky, 0 = foreground)
  - `enum SkyMasker { static func automaticMask(for frame: CIImage) -> SkyMask }`
  - `extension SkyMask { func painting(_ stroke: [CGPoint], radius: CGFloat, sky: Bool) -> SkyMask }`

- [ ] **Step 1: Write the failing tests**

```swift
func testAutomaticMaskSeparatesSkyFromDarkForeground() {
    let mask = SkyMasker.automaticMask(for: horizonImage(horizonY: 300, height: 600))
    XCTAssertGreaterThan(mask.value(atX: 50, y: 100), 0.9)
    XCTAssertLessThan(mask.value(atX: 50, y: 500), 0.1)
}
func testPaintingForegroundOverridesAutomaticSky() {
    let mask = SkyMasker.automaticMask(for: horizonImage(horizonY: 300, height: 600))
        .painting([CGPoint(x: 50, y: 100)], radius: 20, sky: false)
    XCTAssertLessThan(mask.value(atX: 50, y: 100), 0.1)
}
```

`value(atX:y:)` is a test helper that renders one pixel of the mask.

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `xcodebuild test -scheme StarGazing -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StarGazingTests/SkyMaskTests`
Expected: FAIL.

- [ ] **Step 3: Implement the mask**

Automatic: luminance threshold with a horizon search (row-wise brightness change), then a smoothed edge. Painting: composite a soft circular stamp onto the mask with Core Image.

- [ ] **Step 4: Run the tests and confirm they pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add StarGazing/Core/SkyMask.swift StarGazingTests/SkyMaskTests.swift
git commit -m "feat: automatic sky mask with brush corrections"
```

## Task 6: Tiled stacker

**Files:**
- Create: `StarGazing/Core/Stacker.swift`
- Test: `StarGazingTests/StackerTests.swift`

**Interfaces:**
- Consumes: aligned `LoadedFrame`s, `AlignmentTransform` per frame, `StackMode`
- Produces:
  - `struct Stacker { let tileSize: Int; let clipSigma: Double }` with default `tileSize: 512`, `clipSigma: 2.5`
  - `func stack(_ frames: [AlignedFrame], mode: StackMode, tile: TileRect) -> CIImage`
  - `struct AlignedFrame { let linear: CIImage; let transform: AlignmentTransform? }` (`nil` for trails mode)

- [ ] **Step 1: Write the failing tests**

```swift
func testMeanOfConstantFramesIsTheConstant() {
    let out = Stacker().stack(frames([0.2, 0.2, 0.2]), mode: .mean, tile: .full)
    XCTAssertEqual(out.pixel(0, 0).r, 0.2, accuracy: 1e-4)
}
func testSigmaClipRemovesBrightSatelliteFromFiveFrames() {
    let out = Stacker().stack(frames([0.2, 0.2, 0.2, 0.2, 0.95]), mode: .mean, tile: .full)
    XCTAssertEqual(out.pixel(10, 10).r, 0.2, accuracy: 0.01)
}
func testMedianRemovesOutlier() {
    let out = Stacker().stack(frames([0.2, 0.21, 0.2, 0.19, 0.95]), mode: .median, tile: .full)
    XCTAssertEqual(out.pixel(10, 10).r, 0.2, accuracy: 0.02)
}
func testTrailsKeepMaximumPerPixel() {
    let out = Stacker().stack(frames([0.1, 0.9, 0.3]), mode: .trails, tile: .full)
    XCTAssertEqual(out.pixel(10, 10).r, 0.9, accuracy: 1e-4)
}
func testTiledResultMatchesWholeImage() {
    let whole = Stacker(tileSize: 10_000).stack(randomFrames(5), mode: .mean, tile: .full)
    let tiled = Stacker(tileSize: 64).stack(randomFrames(5), mode: .mean, tile: .full)
    XCTAssertLessThan(maxDifference(whole, tiled), 1e-4)
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `xcodebuild test -scheme StarGazing -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StarGazingTests/StackerTests`
Expected: FAIL.

- [ ] **Step 3: Implement the stacker**

Iterate tiles. For each tile, sample each aligned frame through its transform, then compute the mode: sigma-clipped mean (two passes, reject beyond `clipSigma`), median, or max. Trails mode ignores transforms. Use Metal for the per-tile reduction if the CPU version is slower than the Task 1 target.

- [ ] **Step 4: Run the tests and confirm they pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add StarGazing/Core/Stacker.swift StarGazingTests/StackerTests.swift
git commit -m "feat: tiled mean, median, and trails stacking"
```

## Task 7: Post-processing and export

**Files:**
- Create: `StarGazing/Core/PostProcess.swift`
- Test: `StarGazingTests/PostProcessTests.swift`

**Interfaces:**
- Consumes: sky stack, foreground stack, `SkyMask`, `BatchKind`, `[AlignmentTransform?]`
- Produces:
  - `struct PostSettings { var stretch: Double; var denoise: Double }` with automatic defaults computed from the image histogram
  - `enum PostProcess { static func blend(sky: CIImage, foreground: CIImage, mask: SkyMask, settings: PostSettings) -> CIImage; static func commonCropRect(for transforms: [AlignmentTransform?], size: CGSize) -> CGRect }`
  - `enum ExportFormat { case jpeg, tiff16 }` chosen from `BatchKind`

- [ ] **Step 1: Write the failing tests**

```swift
func testCropIsIntersectionOfShiftedFrames() {
    let rect = PostProcess.commonCropRect(
        for: [AlignmentTransform(translationX: 10, y: 0), AlignmentTransform(translationX: -6, y: 4)],
        size: CGSize(width: 1000, height: 800))
    XCTAssertEqual(rect, CGRect(x: 10, y: 0, width: 984, height: 796))
}
func testRawBatchExportsSixteenBitTiff() {
    XCTAssertEqual(ExportFormat(for: .raw), .tiff16)
}
func testJpegBatchExportsEightBitJpeg() {
    XCTAssertEqual(ExportFormat(for: .lossy), .jpeg)
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `xcodebuild test -scheme StarGazing -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StarGazingTests/PostProcessTests`
Expected: FAIL.

- [ ] **Step 3: Implement post-processing**

Crop is the intersection of each frame's transformed bounds. Stretch: midtone curve from the histogram median. Denoise: a light bilateral filter scaled by `denoise`. Blend: `mask * sky + (1 - mask) * foreground`. Export: `CGImageDestination` with the right bit depth.

- [ ] **Step 4: Run the tests and confirm they pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add StarGazing/Core/PostProcess.swift StarGazingTests/PostProcessTests.swift
git commit -m "feat: post-processing, common crop, and export formats"
```

## Task 8: Job pipeline, checkpoints, and background runner

**Files:**
- Create: `StarGazing/Job/StackJob.swift`, `StarGazing/Job/CheckpointStore.swift`, `StarGazing/Job/BackgroundRunner.swift`
- Test: `StarGazingTests/StackJobTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–7
- Produces:
  - `actor StackJob { init(request: StackRequest, store: CheckpointStore); func run(progress: @Sendable (JobProgress) -> Void) async throws -> StackResult }`
  - `struct JobProgress { let framesDone: Int; let framesTotal: Int; let currentFailure: FrameFailure? }`
  - `struct CheckpointStore { func save(_ checkpoint: Checkpoint) throws; func load(jobID: UUID) -> Checkpoint? }` returns `nil` for missing or corrupt files.
  - `struct Checkpoint: Codable { let jobID: UUID; let completedFrameIDs: [UUID]; let failures: [UUID: FrameFailure]; let partialStack: URL }`

Note: `FrameFailure` must be `Codable`. Add that conformance in this task.

- [ ] **Step 1: Write the failing tests**

```swift
func testResumeFromCheckpointMatchesUninterruptedRun() async throws {
    let full = try await StackJob(request: fixtureRequest(frames: 5), store: store()).run { _ in }
    let interrupted = StackJob(request: fixtureRequest(frames: 5), store: store())
    await interrupted.runUntil(framesDone: 3)
    let resumed = try await StackJob(request: fixtureRequest(frames: 5), store: store()).run { _ in }
    XCTAssertTrue(imagesMatch(full.outputURL, resumed.outputURL))
}
func testCorruptCheckpointRestartsFromZero() async throws {
    try corruptCheckpointFile(jobID: fixtureJobID)
    let result = try await StackJob(request: fixtureRequest(frames: 5), store: store()).run { _ in }
    XCTAssertEqual(result.usedFrameIDs.count, 5)
}
func testFrameWithNoStarsIsSkippedAndRunContinues() async throws {
    let result = try await StackJob(request: requestWithCloudyFrame(total: 6), store: store()).run { _ in }
    XCTAssertEqual(result.failures.count, 1)
    XCTAssertEqual(result.usedFrameIDs.count, 5)
}
func testFewerThanFiveUsableFramesFailsTheRun() async {
    await XCTAssertThrowsErrorAsync(try await StackJob(request: requestWithCloudyFrame(total: 5, cloudy: 1), store: store()).run { _ in })
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `xcodebuild test -scheme StarGazing -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StarGazingTests/StackJobTests`
Expected: FAIL.

- [ ] **Step 3: Implement the job, store, and runner**

`StackJob` runs frame by frame: load, detect, align (skipped for trails), mask, then accumulate. After each frame it saves a checkpoint and reports progress. `BackgroundRunner` submits a `BGContinuedProcessingTaskRequest` for the job. When the system expires the task, it cancels the job, which saves its checkpoint first. Check the exact iOS 26 `BGContinuedProcessingTaskRequest` signatures against the SDK headers in Xcode before writing this file. Register the identifier in `BGTaskSchedulerPermittedIdentifiers` (Task 2).

- [ ] **Step 4: Run the tests and confirm they pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add StarGazing/Job StarGazingTests/StackJobTests.swift StarGazing/Core/Models.swift
git commit -m "feat: resumable stack job with checkpoints and background runner"
```

## Task 9: UI, animations, and save-to-Photos

**Files:**
- Create: `StarGazing/UI/PickerView.swift`, `StarGazing/UI/RunView.swift`, `StarGazing/UI/ResultView.swift`, `StarGazing/UI/BeforeAfterSlider.swift`, `StarGazing/UI/StackViewModel.swift`
- Modify: `StarGazing/StarGazingApp.swift`, `StarGazing/ContentView.swift`
- Test: `StarGazingTests/StackViewModelTests.swift`

**Interfaces:**
- Consumes: `StackJob`, `BackgroundRunner`, `StackResult`
- Produces:
  - `@Observable final class StackViewModel { enum Phase { case picking, running(JobProgress), done(StackResult), failed(String) }; var phase: Phase; func start(frames: [Frame], mode: StackMode); func saveToPhotos() async throws }`

- [ ] **Step 1: Write the failing tests**

```swift
func testStartMovesToRunningThenDone() async {
    let vm = StackViewModel(job: FakeJob(succeeds: true))
    await vm.start(frames: fixtureFrames(count: 5), mode: .mean)
    XCTAssertEqual(vm.phase, .done(fakeResult))
}
func testFailedRunShowsMessage() async {
    let vm = StackViewModel(job: FakeJob(succeeds: false))
    await vm.start(frames: fixtureFrames(count: 5), mode: .mean)
    if case .failed = vm.phase {} else { XCTFail("expected failed") }
}
func testSaveFailureKeepsResultForRetry() async {
    let vm = StackViewModel(job: FakeJob(succeeds: true), photos: FailingPhotosWriter())
    await vm.start(frames: fixtureFrames(count: 5), mode: .mean)
    await XCTAssertThrowsErrorAsync(try await vm.saveToPhotos())
    XCTAssertEqual(vm.phase, .done(fakeResult))
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `xcodebuild test -scheme StarGazing -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StarGazingTests/StackViewModelTests`
Expected: FAIL.

- [ ] **Step 3: Implement the UI**

- `PickerView`: `PhotosPicker` with a multi-select limit of 200. Shows the count and a mode picker (mean, median, trails).
- `RunView`: a grid of frame thumbnails. Each frame animates into a stack as it finishes, using matched-geometry effects. Progress uses `TimelineView`. Haptic on completion.
- `ResultView`: `BeforeAfterSlider` with a spring-driven drag. A list of skipped frames with reasons. Save button.
- Reduce Motion: check `@Environment(\.accessibilityReduceMotion)` and replace springs and matched-geometry motion with a crossfade.
- The view model owns the job; views only read `phase`.

- [ ] **Step 4: Run the tests and confirm they pass**

Same command. Expected: PASS. Then run the app on an iPhone 12 Pro and confirm the flow end to end.

- [ ] **Step 5: Commit**

```bash
git add StarGazing/UI StarGazing/StarGazingApp.swift StarGazing/ContentView.swift StarGazingTests/StackViewModelTests.swift
git commit -m "feat: stacking UI, animations, and save to Photos"
```

## Task 10: App icon

**Files:**
- Create: `StarGazing/Assets.xcassets/AppIcon.appiconset/` with a 1024px light master, a dark variant, and a tinted variant.

**Interfaces:**
- Consumes: the icon concept from the design (deep-indigo star-field frames fanning into one bright star point on a dark gradient).
- Produces: an asset catalog app icon that Xcode accepts without warnings.

- [ ] **Step 1: Create the three 1024px PNGs**

Render from a vector source (SVG or Figma). Light: the indigo gradient with the frame stack and star point. Dark: the same, darker. Tinted: a grayscale version the system can tint.

- [ ] **Step 2: Add them to the appiconset and check Contents.json**

Expected: Xcode shows the icon in the asset catalog with no missing-image warnings.

- [ ] **Step 3: Build and check on device**

Run: `xcodebuild build -scheme StarGazing -destination 'generic/platform=iOS'`
Expected: BUILD SUCCEEDED, and the icon shows on the home screen in light, dark, and tinted modes.

- [ ] **Step 4: Commit**

```bash
git add StarGazing/Assets.xcassets/AppIcon.appiconset
git commit -m "feat: app icon with light, dark, and tinted variants"
```

## Task 11: Performance check on iPhone 12 Pro

**Files:**
- Create: `StarGazingTests/PerformanceTests.swift` (XCTest `measure` blocks, device-only, skipped on simulator)

**Interfaces:**
- Consumes: `StackJob`
- Produces: a recorded time for 100 frames of 48MP RAW against the 2-minute target, and peak memory below the device limit.

- [ ] **Step 1: Write the performance test**

```swift
func testHundredRawFramesFinishesWithinTarget() throws {
    try XCTSkipIf(!isPhysicalDevice)
    let start = Date()
    _ = try runBlocking { try await StackJob(request: rawFixture(frames: 100), store: store()).run { _ in } }
    XCTAssertLessThan(Date().timeIntervalSince(start), 120)
}
```

- [ ] **Step 2: Run on iPhone 12 Pro and record time and peak memory**

Run: `xcodebuild test -scheme StarGazing -destination 'platform=iOS,name=<iPhone 12 Pro>' -only-testing:StarGazingTests/PerformanceTests`
Expected: PASS within 120 seconds. If it fails, record the time and profile before changing code.

- [ ] **Step 3: Commit**

```bash
git add StarGazingTests/PerformanceTests.swift
git commit -m "test: iPhone 12 Pro performance check for 100 RAW frames"
```
