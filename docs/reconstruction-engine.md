# The reconstruction engine, milestone 1

This describes what is built, where the code lives, and every place the implementation
departs from the specifications it was written against.
It is not a restatement of those specifications.
The authorities remain the reconstruction PRD, the reconstruction engine specification and the day-page specification in the firstmate home.

## What milestone 1 reads

Photographs, and nothing else.

That is deliberate and is not a shortcut.
rmbr asks for photographs before the paywall and asks for calendar, health and location after it, so the first days a new user ever sees are built from photographs alone.
This milestone is that screen's engine, not a stepping stone toward it.

No calendar, HealthKit or Core Location read exists anywhere in the target.
Every source outside photographs reports `CoverageState.notCollected` and every whole-day figure it would have supplied is `EvidenceValue.unknown(.sourceNotCollected)` - which is not zero, and is not a permission diagnosis.

## Shape of the code

| Layer | Directory | Depends on |
| --- | --- | --- |
| Normalised contract | `rmbr/Model` | Foundation only |
| Engine | `rmbr/Engine` | Foundation only |
| Sources | `rmbr/Sources` | Photos, Security, URLSession |
| App and interface | `rmbr/App`, `rmbr/UI` | SwiftUI, the model |

The engine is pure and synchronous.
It is written against `CaptureRecord`, a normalised value type, rather than `PHAsset`, which is why every rule in it is exercised by tests on a laptop with no device, no permission sheet and no network.

The order of a composition is: assign captures to a civil day, filter hard exclusions, build place anchors from the coordinates that survive, build moments, allocate the display budget, and emit `Day`.
Place naming happens afterwards and never blocks it.

## Day boundary

`DayBoundaryPolicy` has two implementations.

`MidnightDayBoundaryPolicy` is what milestone 1 uses for every day, because the settled sleep-aware rule needs sleep evidence and sleep evidence needs HealthKit.
`SleepAwareDayBoundaryPolicy` is written, tested and unreachable: it closes a day at the start of the longest qualifying measured-sleep episode beginning between local noon and local noon the next day, and falls back to midnight per night rather than per library.
Milestone 2 supplies `BoundaryEvidence.sleepEpisodes` and switches the policy; no other file changes.

## Time zones

`PhotoKit` gives a capture date with no time zone.
`SourceTime.floatingLocal` stores the local wall-clock components together with the zone rmbr was in when it first read them, so a later phone-zone change cannot move a photograph to a different day, and the page prints the hour the photograph claims rather than the hour the phone would translate it into.

The boundary zone is the device zone at indexing time, which is the lowest tier of the specification's cascade.
The tier that won is recorded on the day as `DayWarning.boundaryTimeZoneFromDevice`.
A photograph taken abroad can therefore still land on the wrong civil day; that is a property of the source, and the higher cascade tiers need location evidence this milestone does not read.

## Places

Coordinates come only from photograph metadata.
Phase 0 established empirically that no public API returns pre-install visit history, so a rebuilt past day has a place only where a photograph carried one, and `PlaceOccurrence.visitInterval` is permanently `unknown(.notCollectedBeforeInstall)`.

Clustering does not reproduce the spike's 150 m rolling centroid, which chains: each new point drags the centroid while staying inside the radius, so a cluster's real span grows without bound.
`PlaceAnchorResolver` admits a fix only when it is within 25 m of an existing centroid **and** the anchor's whole span stays inside 75 m.

Naming uses Geoapify, not MapKit, and the reason is licensing rather than quality.
Apple's Developer Program License Agreement permits caching Map Data "on a temporary and limited basis" only, and a returned `MKMapItem.name` is Map Data; rmbr's whole point is that the label recorded on the day it happened stays that label forever.
Geoapify licenses indefinite storage and requires OpenStreetMap attribution, so every stored label carries its attribution string and the day exposes `placeAttributions` for the page to print.

The API key lives in the device keychain, entered once through the reconstruction sheet.
It is never in the repository, never in an `xcconfig`, never in `Info.plist` and never compiled into a build.
The master copy belongs in the macOS keychain via `secret set geoapify`.

## Backfill

The recent window is the current calendar month plus the 23 complete months before it, always 24 month buckets and never 730 days of arithmetic.
Every calendar day in it gets a Life row, not only the days that hold something.
A day with captures gets its day row; a single empty day gets a row of its own; a run of two or more consecutive empty days collapses into one row that names the span and counts it.
Time therefore runs continuously through the window and no day is unreachable, which it was not before: Life used to list only the days that held captures, so an empty day could be opened only from its month.
The walk still stops at the library's first photograph rather than at the window's edge, so a person whose library starts last week does not scroll two years of empty rows.

Older months contribute at most one representative day each, chosen by an ordered cascade that stops at the first tier with a candidate and stores one reason code.
A month whose days all fail the positive-signal gate stays visibly thin rather than promoting its least bad day.
Any other old day composes when it is opened, reached through the month destination.

The window's days and every representative are composed and cached when indexing finishes, off the main actor, and the reconstruction report states how many days that was and what it cost.
The month destination is a mosaic of every calendar day, so it shows the days that hold nothing as well as the days that do; a cell composes its day the first time it scrolls into view, and the grid is lazy, so a month costs the dozen or so cells actually on screen rather than all thirty-one.

The place-label ledger is excluded from backup, as the capture index is.
It holds coordinates the person visited, and re-fetching labels after a restore is a cheaper loss than a copy of that leaving the device.
Exclusion is a precondition rather than a best effort: the flag is set and read back, and a store whose directory cannot be confirmed excluded refuses to write at all.

Geoapify answers from several datasources - OpenStreetMap, OpenAddresses and Who is On First were all seen in live probes - so a stored label carries two credits: the service credit owed for using Geoapify at all, and the datasource credit owed by that particular result.
`Day.placeAttributions` returns the deduplicated union, and Life, the month listing and the day page all render it.

## Deliberate departures

These are the places the implementation and the specifications disagree, and why.

1. **Display budget cap.**
   The reconstruction PRD would raise the budget to cover every media-bearing moment; the engine specification caps it at ten outright and allocates coverage inside that cap.
   The specification governs mechanism, so ten is hard.

2. **`EvidenceValue.unknown` carries a reason.**
   The engine specification's `EvidenceValue` has a bare `unknown`; the PRD requires an `UnknownReason`.
   The richer form is used, so "out of scope" and "read but empty" never collapse into one state.

3. **Automatic POI confidence is not the calibrated model.**
   The specification requires 0.85 calibrated confidence with a 0.20 margin over the runner-up.
   That model needs a labelled venue corpus that does not exist, and picking the nearest business by distance is exactly what the naming rules forbid.
   Until the corpus exists, a provider name is used only when the returned feature is within 25 m of the anchor - effectively containment - **and** the result carries a category, which is the provider's only reliable point-of-interest signal: `result_type` reads `building` even for a park.
   Anything else falls to neighbourhood, then city, then no place phrase.
   There is no building tier and a street address is never printed (settled 2026-08-17): reverse geocoding answers with the nearest feature, so a coordinate outside 1101 W Van Buren resolves to 1035 West Van Buren Street 28 m away - a precise-looking false statement about where somebody was. Precision comes from a person's own correction, not from the geocoder.

4. **No Vision signals.**
   Aesthetics, `isUtility`, face quality and near-duplicate feature prints are unimplemented.
   They occupy the lower tiers of the within-moment ranking ladder, below the metadata signals that are implemented, and a composition must be valid before they run in any case.
   Where they would have broken a tie, a stable identifier does, so selection stays deterministic rather than arbitrary.

5. **`placeCount` is unknown rather than zero when no place was established.**
   A day with no geotagged capture has not established that the person went nowhere.
   Reporting `known(0)` would be a claim rmbr cannot support.

6. **A stale index triggers a full rebuild.**
   Library changes are detected by comparing asset count and newest capture date against the snapshot, and a mismatch re-walks the library rather than applying an incremental `PHChange` diff.
   Those two numbers cannot see one limited selection swapped for another, so under a limited grant the signature also carries a hash of the chosen identifiers.
   At the measured cost of a walk this is cheap; the incremental path is the obvious next refinement.

## What the numbers were

Measured, not estimated.

On a synthetic 6,018-asset simulator library shaped like the captain's (59 % geotagged, spanning 2008 to 2026), a cold first run cost **0.243 s** end to end: 0.049 s fetch, 0.096 s property walk, 0.098 s persist.
The whole-archive survey that builds every day's moments and place anchors and picks each old month's representative cost a further **0.080 s**, over 2,612 days with captures.
A warm launch reuses the snapshot and skips the walk entirely.

At the captain's library size - 24,000 records over 6,502 days reaching back to 2008, exercised by `ScaleTests` - the index builds in **0.093 s**, the archive survey takes **0.269 s**, month selection takes **0.066 s**, and composing one day costs **0.081 ms**, against a 16.7 ms frame.
Eighteen years of history becomes 1,111 Life rows.

The device figures will differ: simulator PhotoKit is backed by a Mac SSD.
The app prints the same report to the console on every run, so the device number is one launch away.
