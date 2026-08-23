# Continuous integration

`.github/workflows/ci.yml` is the whole of it: one job, four steps, on every pull request,
on every push to `main`, and on demand.
This file is why it looks like that.

## What it does

Select Xcode, compile the app and the test bundle, then boot a simulator and run the suite.
Compiling and testing are separate `xcodebuild` invocations on purpose, and that is the only
real ordering decision in the pipeline.

## The runner

`macos-26`, pinned, arm64.

rmbr's deployment target is iOS 26.0 and its tests are hosted in the app on a simulator, so
every check the project has needs an Apple SDK and an iOS 26 simulator runtime.
No Linux runner can provide either, at any price.
That is not a preference; it is the shape of the project.

`macos-26` rather than `macos-latest` because `macos-latest` is a moving pointer.
It resolves to macOS 26 today and will resolve to macOS 27 when that image goes GA, silently
changing the operating system under a project that never asked for it.

Xcode is pinned to 26.3 with `xcode-select`, against an image whose default is 26.6.
The project's only hard floor is Xcode 26.0, since `IPHONEOS_DEPLOYMENT_TARGET` is 26.0 and
`objectVersion` is 77, so newest would have been defensible.
26.3 is chosen instead because it is the toolchain rmbr is actually developed against, which
is what makes a green run here mean the same thing as a green run on a laptop.

The simulator runtime is pinned with it, and the two move as a pair.
Xcode 26.3 carries the iOS 26.2 SDK, so iOS 26.2 is the runtime it can drive; the image
happens to also carry iOS 26.4 and 26.5 runtimes that a 26.3 toolchain has no business
targeting.
Leaving `OS=` off the destination lets `xcodebuild` choose among them, which is a coin toss
nobody needs.

Everything the job uses is preinstalled on the image: Xcode 26.3 at
`/Applications/Xcode_26.3.app`, the iOS 26.2 runtime with an `iPhone 17 Pro` device, and
`xcbeautify` 3.2.1.
Nothing is downloaded, and nothing is installed with Homebrew.
If a future image drops Xcode 26.3, `xcode-select` fails on the spot with a legible error and
`XCODE_VERSION` and `SIMULATOR_OS` get bumped together in one edit.

## The ordering

Build, then test. Never the single fused `xcodebuild test`.

Measured on this pipeline's own first two runs:

| | green run | red run, one syntax error |
| --- | --- | --- |
| Select Xcode | under 1s | under 1s |
| Build | 22s | 22s, failed |
| Test | 129s | skipped, no simulator booted |
| **Job total** | **2m 38s** | **28s** |

A simulator boot is the most expensive and least interesting thing in the run.
In the green run the test step took 129 seconds, of which roughly 86 passed before the first
test executed at all: creating the device, booting it, installing the app, launching the test
host.
Executing all 88 tests took about 35 seconds on the runner, against 0.85 seconds on an
M-series laptop.

Splitting build from test is what makes the red column of that table possible.
A change that does not parse, does not type-check, or violates Swift 6 concurrency is rejected
in 28 seconds rather than 158, and no simulator is ever booted on its behalf.

That is also the honest answer to "make the cheapest thing that can fail, fail first."
For this repository the compile *is* the cheapest thing that can fail, and there is nothing
worth putting in front of it.
A pre-flight job on a Linux runner would spend its own queue and checkout, roughly 15 seconds,
on the critical path of every green run, in order to shave at most a few seconds off a
time-to-red that is already 28 seconds, and the macOS job would still have to run afterwards.
It is a worse pipeline that looks like a better one.

## What it costs

GitHub's published standard-runner rates are $0.062 per minute for macOS and $0.006 per
minute for a 2-core x64 Linux runner: macOS compute is 10.3 times the price of Linux compute,
and each job is rounded up to a whole minute.
Included allowance is 2,000 minutes a month on GitHub Free and 3,000 on Pro, and standard
runners are free in public repositories.

So a green run occupies the runner for 2 minutes 38 seconds, bills 3 minutes, and costs about
**$0.19**.
A run rejected at the build step bills 1 minute and costs about **$0.06**.
The same work on a laptop is 6.9 seconds to build and 17.7 seconds to test; the runner is
several times slower per unit of work and pays about 86 seconds of simulator startup that a
warm laptop does not.

Three things keep that number from growing:

- **`cancel-in-progress` on pull requests.** Pushing three times to a branch in five minutes
  pays for one run, not three. It is deliberately *not* applied to `main`, because with no
  branch protection available on this plan (see below) the `main` run is the only thing that
  reports whether `main` is green, and superseding it would throw that away.
- **`timeout-minutes: 20`.** A healthy run is under three minutes. The default job timeout is
  six hours, which at the macOS rate is about $22 for one wedged simulator. This bound is a
  cost control, not a performance target.
- **No larger runners.** Included minutes cannot be spent on them at all, and they are billed
  even in public repositories.

## Proof that it works, in both directions

A workflow that has only ever gone green has not been tested. Both of these ran on the pull
request that introduced this file:

- **Green.** Run `32649998989`: 2m 38s, 88 tests in 15 suites passed.
- **Red.** Run `32650222909`: a one-line syntax error pushed deliberately. The build step
  failed after 22 seconds, the test step was **skipped**, the whole job took 28 seconds, and
  `xcbeautify --renderer github-actions` annotated the offending line inline in the diff with
  `Expected initial value after '='`. The commit was then removed from the branch.

## Caching: none, on purpose

There is nothing here worth caching.

The project has no Swift Package Manager dependencies, no CocoaPods, no Carthage, and installs
nothing from Homebrew, so the usual dependency caches have no dependencies to hold.
That leaves `DerivedData`, which is the cache people reach for and the one that does not pay.
A clean build of this project produces 148 MB of `DerivedData` in 6.9 seconds.
Saving and restoring 148 MB through the Actions cache takes longer than rebuilding it from
nothing, before considering that Xcode's incremental build state keys on absolute paths and
module hashes and is not sound to move between machines.
A stale-but-accepted `DerivedData` cache does not make CI slower, it makes CI lie, which is
the one thing this pipeline exists to stop.

## What is deliberately not here

- **A lint or format gate.** SwiftLint is not on the image and would cost a Homebrew install
  on every run; more to the point, pointing a fresh linter at an existing 60-file codebase
  turns unrelated pull requests red for style. That is a decision about house style, not about
  continuous integration, and it should be made separately and applied in its own change.
- **Path filtering to skip documentation-only changes.** It saves about $0.12 and two minutes
  on the subset of pull requests that touch only Markdown, and the naive form of it
  (`paths-ignore` on a required check) reproduces exactly the failure in issue #6: a check
  that never reports and a merge state that never resolves. The sound version needs a second
  job and a changed-files mechanism, which is more machinery than the saving justifies.
- **Parallel testing.** 88 tests run in 0.85 seconds. Spawning parallel test runners would
  cost more in process startup than the entire suite costs to run.
- **Retrying failed tests.** `-retry-tests-on-failure` converts a flaky red into a green and
  makes the signal untruthful. If a test is flaky, that is a bug to fix, not to paper over.
- **Code coverage and result bundles.** Coverage instrumentation slows the build to produce a
  number nobody is reading yet, and `xcbeautify --renderer github-actions` already annotates
  the failing test inline, which is what a result bundle would have been downloaded for.
- **A device build.** `-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` catches
  the narrow class of code that compiles for the simulator and not for a device. The codebase
  currently has no `#if targetEnvironment(simulator)` and no architecture conditionals at all,
  so there is nothing for it to catch, and it would roughly double the compile time. Worth
  adding the day the first conditional appears.
- **SHA-pinned actions.** `actions/checkout@v7` is a tag, not a digest. Digest pinning is the
  hardening practice; against one first-party action in a private repository it costs more
  readability than it buys.

## The one thing this cannot do on GitHub Free

The workflow reports a real result on every pull request, but on this plan nothing can *force*
anyone to wait for it.
Branch protection and rulesets are unavailable for private repositories on GitHub Free, and
the API says so directly:

```
GET /repos/tpavay/rmbr/branches/main/protection
403: "Upgrade to GitHub Pro or make this repository public to enable this feature."
```

So the check is advisory: it turns the pull request red or green, and any tooling that waits
on a merge state now has something to wait for, which is what issue #6 was actually stuck on.
Making it blocking needs one of three things, and the choice is not the pipeline's to make:
upgrade the account to Pro, which also raises the included allowance from 2,000 to 3,000
minutes a month; make the repository public, which makes branch protection *and* all standard
runner minutes free; or accept an advisory check.

Nothing in `ci.yml` changes under any of those.
When protection does become available, the check to require is named **Build and test**.
