# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## What this repository currently is

rmbr rebuilds a person's days from their photo library.

Milestone 1 is the reconstruction engine and a deliberately rough day surface, reading **photographs only** - no calendar, no HealthKit, no Core Location.
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

Every run prints a reconstruction report to the console - asset count, fetch and walk times, days indexed, Life rows - and the same figures appear in the reconstruction sheet behind the gauge control. That report is how first-run cost gets measured rather than estimated.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request and every push to `main`: one macOS job that compiles with `build-for-testing` and then runs the suite with `test-without-building`, so a change that does not compile is rejected before a simulator boots.
CI pins Xcode 26.3 and the iOS 26.2 simulator runtime; those two values move together and live in `env:` at the top of the workflow.
`docs/continuous-integration.md` is the authoritative account of the runner choice, the cost basis, and everything deliberately left out. Read it before adding a step.

Checks are advisory rather than blocking: branch protection is unavailable for private repositories on GitHub Free. The check to require, once it can be, is named **Build and test**.

## Place names and the Geoapify key

Place labels come from Geoapify rather than MapKit, because Apple forbids permanent storage of Map Data and rmbr's labels are permanent. `docs/reconstruction-engine.md` has the reasoning.

The API key lives in the device keychain and is entered through the reconstruction sheet. It must never be committed, put in an `xcconfig` or an `Info.plist`, or compiled into a build. The master copy belongs in the macOS keychain via `secret set geoapify`.

Geoapify's terms require OpenStreetMap attribution wherever the stored label is shown; `Day.placeAttributions` carries it so a display path cannot drop it.

## Sharp edges worth knowing before you hit them

`xcrun simctl privacy <device> grant photos <bundle-id>` writes the TCC row but does not make PhotoKit report authorised on the iOS 26 simulator - the prompt has to be answered for real. It *can* be answered without a human: get the device screen's geometry from the accessibility hierarchy and click into it. This corrects the phase-0 note that said the alert was unclickable.

```
osascript -e 'tell application "System Events" to tell process "Simulator" to return position of group 1 of group 1 of group 2 of group 1 of group 1 of group 1 of group 1 of group 1 of group 1 of group 1 of window 1'
# screenshot pixels / 3 + that origin = the point to click
osascript -e 'tell application "System Events" to click at {x, y}'
```

Synthetic scroll wheel and drag events do **not** scroll the simulator's content, so anything below the first viewport cannot be inspected this way. Assert page content through the string-level tests in `rmbrTests/DayPresentationTests.swift` instead.

`xcrun simctl addmedia` takes EXIF `DateTimeOriginal` and GPS as the asset's creation date and location, which is enough to seed a realistically shaped library. It cannot create screenshots: `PHAssetMediaSubtype.photoScreenshot` is set by the system at capture, so screenshot exclusion has to be covered by unit tests.

Further API-level gotchas established during phase 0 - HealthKit read permission being unknowable, `CLGeocoder` being deprecated in favour of `MKReverseGeocodingRequest`, `HKStatisticsQuery` signalling no-data as an error - are in the appendix of `docs/phase-0-findings.md`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
