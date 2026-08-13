# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## What this repository currently is

Phase 0 only: a throwaway measurement spike, not the product.
Its findings and the data model they imply live in `docs/phase-0-findings.md`, which is the artefact intended to outlive the code in `rmbr/`.
Read that file before designing anything.

## Build and run

Single Xcode project at the repository root, no packages, no test target.

```
xcodebuild -project rmbr.xcodeproj -scheme rmbr -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

`DEVELOPMENT_TEAM` is intentionally empty, so a device build needs a team selected in Xcode once.
Verify a device compile without signing using `-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`.

The spike can be driven without tapping a simulator:

```
xcrun simctl launch --console-pty booted com.TylerPavay.rmbr -autorun-survey [-skip-permission-requests]
xcrun simctl launch --console-pty booted com.TylerPavay.rmbr -autorun-day 2026-08-12
```

`-skip-permission-requests` suppresses all three permission sheets so the refused and empty paths can be exercised unattended.

## Sharp edges worth knowing before you hit them

`xcrun simctl privacy <device> grant photos <bundle-id>` writes the TCC row but does not make PhotoKit report authorised on the iOS 26 simulator.
The on-screen prompt has to be answered with a real mouse click; `System Events`' `click at` presses the element behind the alert rather than the alert itself.

Further API-level gotchas established during phase 0 (HealthKit read permission being unknowable, `CLGeocoder` being deprecated in favour of `MKReverseGeocodingRequest`, `HKStatisticsQuery` signalling no-data as an error) are recorded in the appendix of `docs/phase-0-findings.md`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
