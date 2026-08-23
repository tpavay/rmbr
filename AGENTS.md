# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## What this repository currently is

rmbr rebuilds a person's days from their photo library.

Milestone 1 is the reconstruction engine and the settled screens that read it - Life, the month mosaic, the day page and the film-advance viewer, where videos play - reading **photographs only**: no calendar, no HealthKit, no Core Location.
`docs/reconstruction-engine.md` is the authoritative account of what is built, where it lives, and every place it departs from its specifications. Read it before changing the engine.
`docs/phase-0-findings.md` is the surviving artefact of the throwaway measurement spike that preceded it; its API appendix and its "Day model this wants to be" section are still current.

The specifications the engine implements live in the firstmate home, not in this repository: the reconstruction PRD, the reconstruction engine specification, and the day-page specification.

## Build, test and run

Single Xcode project at the repository root. Two targets, no packages.

```
xcodebuild -project rmbr.xcodeproj -scheme rmbr -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

xcodebuild -project rmbr.xcodeproj -scheme rmbr -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`DEVELOPMENT_TEAM` is committed as `QWGVB7TN4T`, applied through the `[sdk=iphoneos*]` conditional so device builds sign automatically while simulator builds stay unsigned.
A Team ID ships inside every built bundle and signs nothing without the private key, so it is configuration rather than a secret.
Verify a device compile without signing using `-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`.

Swift 6 language mode is on. Keep it on.

Every run prints a reconstruction report to the console - asset count, fetch and walk times, days indexed, Life rows - and the same figures appear in the diagnostics sheet, which is instrumentation rather than product and so has no on-screen control: a long press on the wordmark in Life opens it. That report is how first-run cost gets measured rather than estimated.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request and every push to `main`: one macOS job that compiles with `build-for-testing` and then runs the suite with `test-without-building`, so a change that does not compile is rejected before a simulator boots.
CI pins Xcode 26.3 and the iOS 26.2 simulator runtime; those two values move together and live in `env:` at the top of the workflow.
`docs/continuous-integration.md` is the authoritative account of the runner choice, the cost basis, and everything deliberately left out. Read it before adding a step.

Checks report but cannot block a merge: branch protection is unavailable for private repositories on GitHub Free, so this was chosen rather than overlooked. If that ever changes, the check to require is named **Build and test**.

## Place names and the Geoapify key

Place labels come from Geoapify rather than MapKit, because Apple forbids permanent storage of Map Data and rmbr's labels are permanent. `docs/reconstruction-engine.md` has the reasoning.

The API key lives in the device keychain and is entered through that same diagnostics sheet. It must never be committed, put in an `xcconfig` or an `Info.plist`, or compiled into a build. The master copy belongs in the macOS keychain via `secret set geoapify`.

Geoapify's terms require OpenStreetMap attribution wherever the stored label is shown; `Day.placeAttributions` carries it so a display path cannot drop it.

## Playing a video

`rmbr/UI/VideoPlayback.swift` and `rmbr/UI/VideoSurface.swift` hold everything: the PhotoKit fetch, the audio session policy, the one player, and the transport that draws it. `MediaViewer` in `DayPageView.swift` owns exactly one `VideoPlayback` for the whole strip, so a day of videos costs one decoder and every other frame stays the still it already was. Read the doc comments there before changing any of it; the reasoning for each choice is written where the choice is.

Two PhotoKit behaviours cost time to establish and are easy to hit again:

- The `AVPlayerItem` from `PHImageManager.requestPlayerItem` sits at `.unknown` and never moves on its own. Waiting on `AVPlayerItem.status` is waiting on a spinner that never resolves; `await item.asset.load(.isPlayable)` is what answers.
- `PHVideoRequestOptions.progressHandler` fires once with `1.0` for an original that is already on the device. Treating that as a download prints "fetching from iCloud, 100%" about a local file, so only a fraction strictly between 0 and 1 counts as evidence of one.

The two states an iCloud-only original produces cannot be reached on a simulator, whose originals are all local. `SimulatedCloudVideoSource` (debug builds only) drives them through the real code path:

```
xcrun simctl launch <device> com.TylerPavay.rmbr -rmbrSimulateCloudFetch 8
xcrun simctl launch <device> com.TylerPavay.rmbr -rmbrSimulateCloudFetch 4 -rmbrSimulateCloudFailure
```

## Sharp edges worth knowing before you hit them

`xcrun simctl privacy <device> grant photos <bundle-id>` writes the TCC row but does not make PhotoKit report authorised on the iOS 26 simulator - the prompt has to be answered for real. It *can* be answered without a human: get the device screen's geometry from the accessibility hierarchy and click into it. This corrects the phase-0 note that said the alert was unclickable.

```
osascript -e 'tell application "System Events" to tell process "Simulator" to return position of group 1 of group 1 of group 2 of group 1 of group 1 of group 1 of group 1 of group 1 of group 1 of group 1 of window 1'
# screenshot pixels / 3 + that origin = the point to click
osascript -e 'tell application "System Events" to click at {x, y}'
```

Scroll wheel events do **not** scroll the simulator's content, but a synthetic *drag* does, so the whole page can be driven without a human.
Post `CGEvent` mouse down / dragged / up through `.cghidEventTap` in a tiny Swift helper - a dozen or more `.leftMouseDragged` steps a few milliseconds apart, or the gesture recogniser reads it as a tap.
The same helper taps buttons that `System Events`' `click at` misses, which it does for SwiftUI controls layered over a scroll view.
Convert screenshot pixels to screen coordinates with `position of group 1 of window "<device name>"` as the device screen's origin and screenshot pixels / 3 as the offset.
Where a page's text is all that matters, the string-level tests in `rmbrTests/DayPresentationTests.swift` are still the cheaper assertion.

`xcrun simctl addmedia` takes EXIF `DateTimeOriginal` and GPS as the asset's creation date and location, which is enough to seed a realistically shaped library. It cannot create screenshots: `PHAssetMediaSubtype.photoScreenshot` is set by the system at capture, so screenshot exclusion has to be covered by unit tests.

Video seeds need different metadata from photographs. The creation date is taken from `com.apple.quicktime.creationdate`, which `ffmpeg` only writes with `-movflags use_metadata_tags`, and the location only lands in the altitude-bearing ISO 6709 form:

```
ffmpeg -i in.mov -c copy -movflags use_metadata_tags \
  -metadata creation_time="2026-08-20T19:41:30+0000" \
  -metadata com.apple.quicktime.creationdate="2026-08-20T19:41:30+0000" \
  -metadata location="+37.7596-122.4269+012.000/" out.mov
```

Further API-level gotchas established during phase 0 - HealthKit read permission being unknowable, `CLGeocoder` being deprecated in favour of `MKReverseGeocodingRequest`, `HKStatisticsQuery` signalling no-data as an error - are in the appendix of `docs/phase-0-findings.md`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
