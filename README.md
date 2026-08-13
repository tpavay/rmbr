# rmbr

An iOS app that remembers your days for you.

rmbr reconstructs each day automatically from the photos, places and health data your
phone already has, so you never have to write anything down. Apple Journal asks you to
write. rmbr never does.

## Status

Phase 0. Nothing is built yet beyond a measurement spike whose only job is to establish
what iOS will actually hand a freshly installed app about a person's past.

See `docs/phase-0-findings.md` for the findings, and for the data model they imply.

## Running the spike

Open `rmbr.xcodeproj`, set Signing & Capabilities > Team on the `rmbr` target to your own
team, and run on a physical iPhone. The simulator builds and runs, but its numbers say
nothing about a real library and the app prints a banner saying so.

Mode A surveys how much past exists. Mode B reconstructs a single chosen day. Both render
to one monospaced text view with a share button; that text is the entire interface, and it
is meant to be read once and thrown away.

