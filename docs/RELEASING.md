# Releasing StarGazing

## Cut a release

1. Write the release notes in `docs/release-notes/<tag>.md` (copy the last one and edit it), and
   commit it. If the file is in the tagged commit, it becomes the release notes. If it isn't,
   GitHub generates a list from merged pull requests, which is nearly empty in a repo that doesn't
   use them.
2. Tag and push:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Pushing a tag that starts with `v` runs `.github/workflows/release.yml`. It builds the app on GitHub
Actions and attaches the result to a GitHub release named after the tag, with generated release
notes. Watch it under the repository's **Actions** tab; the release appears under **Releases**.

- **Version numbers** come from the tag: `v1.2.3` gives version `1.2.3`, and the build number is the
  workflow run number.
- **Pre-releases.** A tag with a hyphen, such as `v1.0.0-beta.1`, is marked as a pre-release.
- **Tests run first.** The workflow runs the unit tests (retrying once) before building. If they fail,
  nothing is published.
- **Re-running.** Re-running the job replaces the files on the existing release.

## What is attached

| File | What it is |
|---|---|
| `StarGazing-<tag>-unsigned.ipa` | The iPhone app, **not code-signed**. Cannot be installed as it is. |
| `StarGazing-<tag>-simulator.zip` | The app for the iOS Simulator. Unzip it and drag it onto a running simulator. |

The same files are also kept with the workflow run (Actions, then the run, then Artifacts).

## Why the iPhone build is unsigned

Signing needs an Apple Developer account's certificate and provisioning profile, which this
repository does not have. The unsigned `.ipa` can be re-signed and installed with your own
certificate (for example with a sideloading tool, or `codesign` and Xcode's device tools).

To have the workflow produce a signed, installable `.ipa` (and optionally upload to TestFlight),
store these as repository secrets and extend the workflow:

- a distribution certificate (`.p12`) and its password,
- a provisioning profile for `imranhc0.StarGazing`,
- optionally an App Store Connect API key for TestFlight.

## The runner

The project file uses the Xcode 27 format, so the job needs an Xcode 27 runner. GitHub offers one
as a preview image with the label `xcode-27`. If a job sits in the queue and never starts, that
label is probably not available to the repository: check GitHub's runner-images documentation and
change `runs-on` in the workflow. The first step fails with a clear message if the runner's Xcode is
older than 27.
