# iina-tests

> **Why this exists.** Upstream IINA has no automated tests. We offered a test target with 127 tests in [iina/iina#6492](https://github.com/iina/iina/pull/6492). It was closed with "We don't consider adding tests for now." Automated tests are basic engineering practice, so we maintain them here, along with the fork changes that depend on them.

The test suite for [StrongAI/iina](https://github.com/StrongAI/iina), the StrongAI fork of [IINA](https://github.com/iina/iina). It is checked out there as a git submodule at `iinaTests/`, and it builds only from inside that checkout.

## Running the tests

Clone the fork with its submodules, fetch the libraries IINA links against, and test the `iinaTests` scheme of `iina.xcworkspace`:

```console
git clone --recurse-submodules https://github.com/StrongAI/iina.git
cd iina
./other/download_libs.sh
xcodebuild test -workspace iina.xcworkspace -scheme iinaTests -destination platform=macOS
```

In Xcode, open `iina.xcworkspace`, choose the `iinaTests` scheme, and use Product > Test.

The tests run inside IINA.app, so they can test the app's own code. The `iinaTests` scheme sets `IINA_TEST_HOST=1`, which makes that copy of IINA keep its plugins in a temporary folder instead of loading the ones you have installed.

## Layout

- `Tests/` holds the test sources and fixtures. The target includes every file in this folder, so adding a test needs no project change.
- `iinaTests.xcodeproj` holds the `iinaTests` target, which depends on the `iina` target of `../iina.xcodeproj`.
- `iinaTests.xcconfig` holds the target's settings. The project-level settings come from IINA's own `Configs/`.
