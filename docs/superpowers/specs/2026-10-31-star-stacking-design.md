# StarGazing: Star Stacking App — Design

Date: 2026-10-31
Status: Approved by user 2026-10-31

## Intent and why

StarGazing is an iPhone and iPad app that combines several night-sky photos into one clean image: less noise, sharp stars, and optional star trails. The existing pro-quality stacker, Starry Landscape Stacker, is Mac-only. The iOS alternatives are basic, have few reviews, or lack editable sky masks. The app should bring pro-level stacking to iOS with a polished, animation-rich experience.

## Goals

1. Stack existing photos from the Photos library into one image.
2. Support RAW (DNG) from day one, plus JPEG and HEIC.
3. Automatic star detection and alignment across frames.
4. Automatic sky/foreground masking, with a brush to correct it.
5. Stacking modes: sigma-clipped mean (default), median, and max (star trails).
6. Separate foreground stacking, blended with the sky.
7. Export to Photos as JPEG or TIFF (16-bit when source is RAW).
8. Animation-heavy UI: transitions, stacking visuals, and a before/after comparison that feels physical.
9. A distinctive app icon.
10. Stacking continues in the background, with progress shown to the user, and an interrupted stack resumes from its last checkpoint.

## Non-goals (for v1)

- Live capture or in-camera stacking. This is planned for a later version.
- Monetization. The app is free for now.
- Mac or iPad-specific layouts beyond what runs on iPad by default.
- Cloud processing. All processing happens on-device.
- Support for iOS versions before 26.

## Anti-goals

- Stacking that smears stars, leaves visible satellite trails when median or sigma clipping could remove them, or introduces halos around stars.
- Crashes or out-of-memory failures on large batches (100+ frames, RAW).
- Animations that block or slow down the stacking work.
- A UI that hides the controls behind animation.
- Losing a partly finished stack when the app is backgrounded, killed, or the phone restarts.

## Constraints

- Platform: iOS 26 minimum. Swift, SwiftUI.
- Devices: iPhone 12 Pro and newer must be supported. That is an A14 chip and 6 GB of RAM, so memory use must stay well under that limit.
- Processing: on-device only. Use Metal or Core Image for heavy work, with Accelerate where it fits.
- Memory: batches must be processed in tiles or streamed, so large RAW sets do not load fully into memory.
- Background: stacking must continue when the app is backgrounded or the screen locks, using `BGContinuedProcessingTask`.
- Input: the Photos library. Reading RAW requires Core Image RAW decoding or an equivalent.
- Current project state: the Xcode project (`StarGazing.xcodeproj`) contains only the default SwiftUI template (`ContentView.swift`, `StarGazingApp.swift`, `Assets.xcassets`).

## Decisions

These were made by the user or by the design, and the builder should follow them:

- Existing photos first. Live capture is a future phase.
- RAW (DNG) and JPEG/HEIC are all supported from v1.
- Minimum iOS 26.
- Devices: iPhone 12 Pro and newer.
- Background processing is required, using `BGContinuedProcessingTask`.
- Free for now. No paywall or purchase flow in v1.
- Processing is on-device.
- Sky masking is automatic, with a brush for manual correction.
- Stacking modes: sigma-clipped mean (default), median, max (star trails).
- Output: JPEG, and 16-bit TIFF for RAW sources.

## Calls made in review (builder: follow these; they are the design's choices, not the user's)

1. **Star trails (max mode):** No alignment for tripod shots, since trails are meant to move. Mean and median modes align first.
2. **Foreground stacking:** Sigma-clipped mean, aligned with the same star transform, so handheld or tracked shots work too.
3. **Failed frames** (clouds, too few stars, out of focus): Skip them and list each one with its reason. A run needs at least 5 usable frames.
4. **Mixed batches:** Reject a batch that mixes RAW with JPEG/HEIC, or mixes sizes. Convert everything to linear light before stacking. Output is 16-bit for RAW-only batches and 8-bit for JPEG/HEIC-only batches.
5. **Edges after alignment:** Crop automatically to the area every frame covers.
6. **Stretch and denoise:** Automatic defaults, with one strength slider each and a live preview.
7. **Time target:** No fixed limit. Target about 2 minutes for 100 frames of 48MP RAW on iPhone 12 Pro, as a goal to measure against during the spike, not a hard requirement.
8. **Checkpoints and resume:** Process one frame at a time and save a checkpoint after each. On resume, skip frames already done. If the system ends the continued task, the run resumes from the last checkpoint on the next launch.

## Background processing

`BGContinuedProcessingTask` (iOS 26) lets a user-started stack keep running in the background, with progress shown to the user, and avoids the 30-second limit and the wait for charging that apply to older background options. Call 8 still applies, in case the system ends the task early.

## Pipeline

1. Import: the user picks 5–200 frames from Photos. The app reads each frame's metadata (exposure, ISO, dimensions).
2. Star detection: each frame is scanned for star centroids.
3. Alignment: each frame is aligned to a reference frame by matching star patterns. Vision registration can be a fallback. Skipped for max (trail) mode, per call 1.
4. Masking: an automatic sky mask is generated. The user can paint corrections.
5. Stacking: sky and foreground are stacked separately. Sky uses the chosen mode.
6. Post: stretch, light denoise, and blend sky with foreground.
7. Export: save to Photos.

Each step runs tile by tile, and progress is checkpointed after each frame.

## Experience and animation

- Photo grid to stacking view uses matched-geometry transitions.
- During stacking, frames animate into a single stack as each is aligned. Progress is driven by a shader or `TimelineView`.
- Before/after comparison uses a draggable slider with spring physics.
- Haptics mark completion and mode changes.
- All motion respects Reduce Motion, with a static fallback.

## App icon

A stack of deep-indigo star-field frames fanning out into one bright star point on a dark gradient. One 1024px master, with dark and tinted variants in the asset catalog.

## Left to the builder

- Architecture and module boundaries.
- Choice of alignment algorithm and the sky-mask method.
- Whether to use Metal shaders or Core Image for each stage.
- Checkpoint format and storage location.
- Test strategy, including sample data sets.
- Bundle identifier and signing.
- Milestone order, after the spike.

## Milestones (suggested)

1. Spike: align and mean-stack 10 JPEG frames, and measure speed on iPhone 12 Pro.
2. Core engine: alignment, masking, all three stacking modes, RAW input, checkpoints.
3. Background processing with `BGContinuedProcessingTask`, and resume.
4. UI and animations on top of the engine.
5. Icon, performance on 100+ frame RAW batches, and TestFlight.
