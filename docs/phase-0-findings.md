# Phase 0 findings

This document is the deliverable of the phase 0 measurement spike.
The app that produces these numbers is throwaway and will be deleted; this file is what survives it.

**Nothing below is filled in yet.**
Every blank is waiting on a run against the captain's real phone.
Do not estimate, interpolate or infer any figure here.
A blank is a true statement about what we know; a guess is not.

## How to produce the numbers

1. Open `rmbr.xcodeproj` in Xcode, select the `rmbr` target, and set Signing & Capabilities > Team to your own team.
   Nothing else needs changing.
2. Run on the physical iPhone, not the simulator.
   The app prints a `RUNNING IN THE SIMULATOR` banner when it is not on a phone, and that output is worthless for this document.
3. Grant Photos (full access, not limited), Health (allow all four categories) and Location (Always) when asked.
4. Press RUN in mode A and leave the app in the foreground until it finishes.
   It walks every asset in the library and every month of health history, so on a large library this takes minutes.
5. Share the output to yourself and paste the numbers into the tables below.
6. Switch to mode B, pick a handful of days with different shapes (a day out, a normal weekday, a travel day, a day with no photos), and run each.

## 1. Photos

Source: PhotoKit, default fetch (the user's own library; hidden assets and non-representative burst frames excluded, then counted separately).

| Measure | Value |
| --- | --- |
| Total assets (default fetch) | |
| Total including hidden | |
| Hidden assets | |
| Total including all burst frames | |
| Non-representative burst frames | |
| Oldest asset creationDate | |
| Newest asset creationDate | |
| Span in days | |
| Assets with no creationDate | |
| Assets with GPS coordinates | |
| GPS coverage as a percentage of all assets | |
| Photos | |
| Videos | |
| Total video duration | |
| Screenshots | |
| Screenshots as a percentage of all assets | |
| Live Photos | |
| Panoramas | |
| Favourites | |
| Assets belonging to a burst | |
| Distinct bursts | |

### 1.1 Photos per calendar year

The GPS column is the one that decides the product.
For any day before install, a photograph carrying coordinates is the only way a place can be known.

| Year | Total | With GPS | GPS % | Photos | Videos | Screenshots | Live | Favourites | Burst |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | | |

### 1.2 What this tells us

Fill in after the table:

- The earliest year with a usable density of assets is ____.
- The earliest year with a usable density of *geotagged* assets is ____.
- Below year ____ there is not enough material to reconstruct a day at all.
- Screenshots are ____% of the library, which is the share of assets a moments heuristic must discard before it sees anything.

## 2. Health

Source: HealthKit, each type queried independently.
An empty result is reported as empty rather than omitted.

**Read this before interpreting anything in this section.**
HealthKit does not report whether read access was granted.
`HKHealthStore` exposes only share authorisation and a "would I prompt again" flag.
An empty result for a type means either "the user refused this type" or "no such data exists", and the two are indistinguishable from inside the app by design.
Cross-check any empty type against the Health app before concluding the data does not exist.

### 2.1 Sleep analysis

| Measure | Value |
| --- | --- |
| Oldest sample | |
| Newest sample | |
| Total samples | |
| Sources | |

| Year | Samples |
| --- | --- |
| | |

### 2.2 Step count

| Measure | Value |
| --- | --- |
| Oldest sample | |
| Newest sample | |
| Total samples | |
| Sources | |

| Year | Samples | Total steps |
| --- | --- | --- |
| | | |

### 2.3 Distance walking/running

| Measure | Value |
| --- | --- |
| Oldest sample | |
| Newest sample | |
| Total samples | |
| Sources | |

| Year | Samples | Total metres |
| --- | --- | --- |
| | | |

### 2.4 Workouts

| Measure | Value |
| --- | --- |
| Oldest sample | |
| Newest sample | |
| Total samples | |
| Sources | |

| Year | Samples |
| --- | --- |
| | |

### 2.5 What this tells us

- The oldest health data of any kind is from ____, which is ____ years of past.
- Health history starts ____ than photo history, so the two do not cover the same span.
- The types that returned nothing are: ____.
  Verified against the Health app: ____.

## 3. Location

The blocking question.
Everything else in this document is a count; this one changes what the product can promise during onboarding.

| Measure | Value |
| --- | --- |
| Authorisation granted | |
| Location services enabled | |
| Visit monitoring started at | |
| Observation window | 8 seconds |
| CLVisit callbacks received | |
| Of those, completed visits that began before monitoring started | |
| Live location fixes | |

**Verdict:** ____ (CONFIRMED / REFUTED)

The expectation going in was that no pre-install visit history is reachable.
The API surface supports that expectation: `startMonitoringVisits()`, `startMonitoringSignificantLocationChanges()`, `CLLocationUpdate.liveUpdates` and `CLMonitor` are all future-facing, and none of them has a fetch, query, history or since-date variant.
`CLLocationManager.location` returns a single present-tense fix.
iOS does retain Significant Locations under Settings > Privacy & Security > Location Services > System Services, but no public API reads it.

If confirmed, the consequence is concrete and should be written into the product plan verbatim:

> A rebuilt past day has a place only where a photograph carried coordinates.
> Days with no geotagged photo have no place at all, and no permission granted later changes that retroactively.
> Location coverage of the past is exactly the GPS % column in section 1.1, and nothing more.
> Days from install forward can be richer, but only while the app is installed and monitoring.

## 4. Reconstructed days

Run mode B on several days of different shapes and record what came out.
The point is not that the grouping is good; the point is to see what the grouping actually is.

### Day: ____ (a day out)

| Measure | Value |
| --- | --- |
| Photos and videos | |
| Of those, geotagged | |
| Distinct places after clustering | |
| Workouts | |
| Sleep recorded | |
| Steps | |
| Moments proposed | |

Moments as printed:

```
(paste the MOMENTS section here)
```

Judgement: did the moments match what actually happened that day?
Which splits were wrong, and in which direction (too many moments, too few)?

____

### Day: ____ (an ordinary weekday)

| Measure | Value |
| --- | --- |
| Photos and videos | |
| Of those, geotagged | |
| Distinct places after clustering | |
| Workouts | |
| Sleep recorded | |
| Steps | |
| Moments proposed | |

```
(paste the MOMENTS section here)
```

Judgement: ____

### Day: ____ (travel, or somewhere unfamiliar)

| Measure | Value |
| --- | --- |
| Photos and videos | |
| Of those, geotagged | |
| Distinct places after clustering | |
| Workouts | |
| Sleep recorded | |
| Steps | |
| Moments proposed | |

```
(paste the MOMENTS section here)
```

Judgement: ____

### Day: ____ (no photos at all)

What did the app print, and is that an acceptable thing for the product to say about a day?

____

### 4.1 Heuristic tuning

The constants lived in the spike's `rmbr/DayReconstruction.swift`, in `enum MomentHeuristic`, and went with it when the spike was deleted; the engine's equivalents are in `ReconstructionTuningProfile`.
Values used for the runs above:

| Constant | Value used |
| --- | --- |
| `maxGapBetweenPhotos` | 45 minutes |
| `maxDistanceWithinMoment` | 250 m |
| `placeClusterRadius` | 150 m |
| `excludeScreenshots` | true |
| `collapseBursts` | true |

If a different value produced visibly better groupings, record the value and the day it was tested on.
Do not record an impression without the day it came from.

| Constant | Value tried | Day tested | Better or worse, and how |
| --- | --- | --- | --- |
| | | | |

## 5. Decisions this unblocks

Answer each of these once the tables above are filled in.
These are the reasons the spike exists.

1. **How far back can rmbr honestly claim to reconstruct?**
   The answer is the earliest year in section 1.1 with enough assets, not the oldest asset date.
   ____
2. **What fraction of past days can have a place on them?**
   Derived from GPS coverage per year, not from the library-wide average.
   ____
3. **What does onboarding promise?**
   If location history is unreachable, "we rebuild where you have been" is false for everything before install and must be replaced.
   ____
4. **Does a day need a fallback shape for when there is no raw material?**
   Section 4's empty day answers this.
   ____
5. **Is sleep dependable enough to be part of the day's frame?**
   Depends on how far back sleep samples go and whether the captain wears a watch overnight.
   ____

## 6. The Day model this wants to be

This section is the one artefact of the spike that outlives the code.
It is written from what the reconstruction actually had to deal with, not from what a day ideally contains.

### A day is a container of moments, and almost nothing else

Everything the reconstruction produced fell into two shapes: things that happened at a time and place, and figures that describe the whole day.
Photos, videos and workouts are the first.
Steps, distance and sleep are the second.
There was never a case where a whole-day figure wanted to be positioned in the timeline, or where a moment wanted to be a daily total.
The model should not pretend they are the same kind of thing.

### What a moment needs

A moment needs a time range and a set of source assets.
That is the whole of the required part.
Both come from the photos; nothing else in the day is dense enough in time to originate a moment.

Everything else a moment has is optional and frequently missing:

- **A place.** Present only when at least one asset in the moment carried coordinates. In practice a moment either has coordinates on most of its assets or on none, because geotagging is a property of the device and the settings at the time, not of the individual photograph.
- **A place name.** Present only when a place is present and a reverse geocode succeeded. Geocoding is rate limited and network dependent, so a name can be missing even when coordinates are known. The model must treat coordinates and name as two separate optional facts, not one.
- **A representative asset.** Always derivable when the moment exists, but the rule that derives it is a product decision, not a fact about the data. The spike used: favourite first, else the geotagged still photo nearest the temporal midpoint, else the still photo nearest the midpoint. Every part of that rule is arguable.
- **A duration.** A moment made of one photo has a duration of zero, which is true and useless. The model needs to distinguish "an instant" from "a span" or the presentation layer will print "0s" at the user.

### Where the sources disagree

**Time is not one thing.**
A photo's `creationDate` is device local time with no timezone attached.
A photo taken abroad reads back in whatever timezone the phone is in when you ask.
Health samples carry real instants.
So a photo and a workout on the same day can be ordered wrongly relative to each other if the captain crossed a timezone.
The model should carry a timezone alongside the day, and it must not assume the photo timestamps agree with it.

**A day does not start at midnight, and sleep proves it.**
Sleep for "Tuesday" starts on Monday evening.
The spike hardcodes a window from 18:00 the previous day to 12:00 on the day itself, which is a guess dressed as a constant.
Any model that defines a day as `[startOfDay, startOfDay + 1 day)` will cut every night in half.
Sleep needs its own window, defined relative to the day but not equal to it.

**Multiple sources double count.**
Steps and distance come from the phone and the watch at once.
HealthKit's merged total and the sum of the per-source totals are different numbers, and the per-source sum is larger.
Sleep is worse: two sources recording the same night produce overlapping intervals, and summing their durations claims the captain slept longer than the night is.
The spike merges overlapping intervals rather than summing them.
Any day model that stores "total asleep" must record how it was computed, because the naive number is wrong and looks plausible.

**Bursts and screenshots are noise with structure.**
A burst is dozens of assets that are one thing that happened.
A screenshot is an asset that is not a thing that happened at all.
Both need collapsing or discarding before anything counts photos, and both are visible in the data (`burstIdentifier`, `PHAssetMediaSubtype.photoScreenshot`), so this is cheap.
The count a moment reports to the user should be the collapsed count, but the raw count needs to survive in the model, because "40 photos in eight seconds" is itself a fact about the moment.

### What is unreliable and must be modelled as such

- **Coordinates are sparse and clustered.** Not sparse uniformly: a whole year can be at zero and the next at ninety per cent, following device and settings changes. A model that assumes a roughly constant hit rate will be wrong at the year boundary.
- **Place names are a network call away and can simply fail.** A moment can be known to be somewhere without being nameable.
- **Health read permission is unknowable.** The app cannot distinguish "the user refused sleep" from "there is no sleep data". Anything built on health has to degrade without knowing why it is degrading, and must never tell the user "you did not sleep" when it means "we cannot see".
- **Whole-day statistics can be zero and present, or absent entirely.** `HKStatisticsQuery` signals "no data" as an error, not as an empty result. Zero steps and no step data are different states and the model must keep them apart, because one means the captain did not move and the other means we do not know.

### The shape, stated plainly

A **Day** has a date, a timezone, an ordered list of moments, an optional sleep record, and a set of optional whole-day figures each of which is either a known value, a known zero, or unknown.

A **Moment** has a time range and a list of source assets, and optionally a coordinate, a place name derived from that coordinate, a representative asset chosen by an explicit named rule, and a collapsed and a raw asset count.

A **Sleep record** has its own window, a bedtime, a wake time, a total that records how overlapping sources were reconciled, and the set of sources that contributed.

The moment is the only unit the user is ever shown, and it is built entirely from photographs.
That is the sentence the rest of the product has to be designed around.

## Appendix: what the spike established about the APIs

Facts that cost time to work out and that the real implementation should not have to rediscover.

- `CLGeocoder` is deprecated as of iOS 26. The replacement is `MKReverseGeocodingRequest` in MapKit, whose results are `MKMapItem` with `name`, `address` and `addressRepresentations`. `MKMapItem.placemark` is deprecated alongside it.
- HealthKit has no count query. The only way to learn how many samples exist is to fetch them, which is why the survey walks month by month rather than year by year.
- `HKStatisticsQuery` reports "no data" as `HKError.errorNoData` rather than returning a statistics object with a nil sum.
- `HKHealthStore.statusForAuthorizationRequest(toShare:read:)` reports only whether iOS would prompt again. There is no API that reports whether read access was granted.
- `PHFetchResult.enumerateObjects` takes an escaping block, so accumulating into local variables needs an index loop instead.
- Default `PHFetchOptions` exclude hidden assets and non-representative burst frames. Both exclusions are worth measuring rather than assuming.
- `xcrun simctl privacy <device> grant photos <bundle-id>` writes the TCC row but does not make PhotoKit report authorised on the iOS 26 simulator. The on-screen prompt has to be answered for real.
- The iOS 26 simulator ships synthetic step count and distance samples but no sleep and no workouts, so an empty sleep section in a simulator run means nothing.
