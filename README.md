# rmbr

An iOS app that remembers your days for you.

rmbr reconstructs each day automatically from what your phone already has, so you never
have to write anything down. Apple Journal asks you to write. rmbr never does.

## Status

Milestone 1: the reconstruction engine, and a deliberately rough surface for reading a
day. It rebuilds days from **photographs only** - no calendar, no health data, no
location history.

That is not a shortcut. rmbr asks for photographs before the paywall and asks for
everything else after it, so the first days a new user ever sees are built from
photographs alone. This is that screen's engine.

A rebuilt past day has a place only where a photograph carried coordinates, because no
public API returns location history from before the app was installed. A day with no
geotagged photograph shows no place at all, and rmbr does not guess one.

## Running it

Open `rmbr.xcodeproj`, set Signing & Capabilities > Team on the `rmbr` target, and run.
Grant full access to the photo library when asked; limited access works, but every count
rmbr shows is then a count of what it can see rather than of what exists.

Place names need a Geoapify API key, entered once in the reconstruction sheet behind the
gauge control in the top right. Without one, days still rebuild - they just have
coordinates instead of names.

## What is where

- `docs/reconstruction-engine.md` - what the engine does, where the code is, and every
  place it departs from its specification.
- `docs/phase-0-findings.md` - the surviving artefact of the measurement spike that came
  before it.
- `AGENTS.md` - build and test commands, and the sharp edges.

Place names © OpenStreetMap contributors, via Geoapify.
