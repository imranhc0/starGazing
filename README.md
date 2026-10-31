# StarGazing

An iPhone app that stacks several night-sky photos into one clean image: less noise, sharp stars, or
long star trails. Pick 5 to 200 photos from your library (RAW, HEIC or JPEG), choose a mode, and
StarGazing lines the stars up, combines the photos, and saves the result back to Photos.

> **Status: early.** The app builds, its tests pass, and every screen has been checked in the
> simulator. It has **not yet been run on a real iPhone**. See [Known limitations](#known-limitations).

## What it does

- **Stacks photos from your library.** RAW (DNG), HEIC and JPEG, 5 to 200 photos at a time.
- **Three modes**
  - **Clean sky:** a sigma-clipped average that lowers noise and keeps stars sharp.
  - **Median:** also removes planes and satellites that cross only some frames.
  - **Star trails:** keeps the brightest value at each pixel, so stars become streaks.
- **Finds the stars itself.** It detects stars in every photo, aligns them, and picks the photo with
  the most stars as the reference. Photos it can't use (clouds, too few stars, can't be read) are
  skipped and listed with a reason.
- **Keeps the ground sharp.** The sky is aligned on the stars; the foreground is stacked as shot, and
  an automatic sky mask blends the two.
- **Picks up where it stopped.** Progress is saved after every photo. If the run is interrupted,
  the picker offers to resume it.
- **Before and after.** A draggable slider compares an original photo with the stacked result.
- **Saves to Photos.** 16-bit TIFF for RAW photos, JPEG otherwise. Everything runs on the device.

## Requirements

| | |
|---|---|
| Xcode | **27 or newer**. The project file uses Xcode 27's new format (`project.xcproj`). |
| iOS | 26.0 or newer |
| Devices | iPhone 12 Pro and newer are the target |

## Build, run and test

```bash
open StarGazing.xcodeproj          # then press Run in Xcode

# Run the tests from the command line
xcodebuild test \
  -project StarGazing.xcodeproj \
  -scheme StarGazing \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StarGazingTests
```

- If `xcodebuild` complains that it needs Xcode, point it at the full app for one command with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- If two simulators share a name, use `id=<simulator UUID>` in the destination instead.
- The first test run after adding files can fail with "Failed to create a bundle instance". Run it
  again. After changing a SwiftUI view's stored properties, do a clean build (`xcodebuild clean test`)
  if the app crashes on launch.
- `PerformanceTests` only runs on a physical iPhone and is skipped in the simulator.

**Debug screens.** In a Debug build you can open any screen with made-up data, without a photo
library: launch with `-demoScreen picker`, `resume`, `run` or `result`.

## How it works

```
Photos library
   │  FrameLoader      decode JPEG/HEIC/RAW into linear light, in the sensor's orientation
   ▼
StackJob (actor)
   │  1. per photo     detect stars, save them, checkpoint            (StarDetector)
   │  2. all photos    pick the reference (most stars), align the rest (StarAligner)
   │  3. final stack   sky: aligned, foreground: as shot              (Stacker, in tiles)
   ▼
PostProcess            blend through the sky mask (SkyMasker), stretch, denoise, crop to the
                       area every photo covers, orient like the reference photo, export
```

The processing core has no UI imports. The SwiftUI layer talks to it through small protocols
(`StackRunner`, `PhotosWriter`, `FrameSource`), which is how the tests run it with real images but
no photo library.

```
StarGazing/
  Core/     models, loading, star detection and alignment, sky mask, stacking, post-processing
  Job/      StackJob, checkpoints, the pending-stack store, the background runner
  UI/       the three screens, the view model, Photos access
  Assets.xcassets/   app icon (light, dark, tinted)
StarGazingTests/     unit tests for all of the above
Config/Info.plist    background-task identifier and Photos permission texts
Tools/MakeAppIcon.swift   redraws the app icon: swift Tools/MakeAppIcon.swift <appiconset folder>
docs/                design spec, implementation plan, style sheet, release guide
```

## Known limitations

- **Not tested on a real iPhone yet.** Speed, memory and background behaviour are unmeasured. The
  target is about 2 minutes for 100 photos on an iPhone 12 Pro.
- **Large RAW batches will probably run out of memory.** The final stack keeps every usable photo
  open at once. A proper fix needs a different design (spill aligned photos to disk) and a device to
  measure against.
- **No mask brush and no stretch or denoise sliders yet.** The design calls for both. When the
  automatic sky mask is wrong, there is no way to correct it.
- **Background stacking is unproven.** It uses iOS 26's continued processing task and falls back to
  running in the foreground, so keep the app open while it works. A copy re-signed by a
  side-loading tool gets a new bundle ID and loses the background option.
- **The foreground is not aligned.** That suits a camera on a tripod. Handheld or sky-tracking shots
  would blur the ground.
- **RAW decoding is untested** because there is no sample file in the repository.

## Documentation

- [Design spec](docs/superpowers/specs/2026-10-31-star-stacking-design.md): what the app must do.
- [Implementation plan](docs/superpowers/plans/2026-10-31-star-stacking.md): how it was built.
- [Style sheet](docs/STYLE_SHEET.md): colours, type and components from the reference design.
- [Releasing](docs/RELEASING.md): how a version tag builds the app on GitHub Actions and attaches it
  to a release.

## Releases and installing

Pushing a tag such as `v1.0.0` runs the tests, builds the app, and attaches an **unsigned** `.ipa`
and a simulator build to a GitHub release. The unsigned `.ipa` can't be installed as it is: it has to
be signed with your own Apple ID or developer certificate, for example with Sideloadly or Xcode.
Phones managed by an employer, school or lender may not allow the Developer Mode that this needs.
Details are in [docs/RELEASING.md](docs/RELEASING.md).

## Licence

No licence has been chosen yet, so by default all rights are reserved. Add a `LICENSE` file to
change that.
