# Contributing to Wokintosh

Bug reports, documentation improvements and focused pull requests are welcome. For a larger feature or visual redesign, open an issue first so we can agree on its purpose and fit with a small-screen dashboard.

## Development setup

- Apple silicon Mac running macOS 14 or later.
- Xcode command-line tools and Swift 6 or later. The package uses Swift 5 language mode.
- Python 3.10 or later for the standard-library collector and its tests.
- SSH is needed only to exercise a remote collector. Linux collector work does not require a Mac.

```sh
git clone https://github.com/anandman/wokintosh.git
cd wokintosh
swift test --scratch-path /private/tmp/wokintosh-build
python3 -m unittest discover -s collector/tests -v
script/build_and_run.sh --build-only
```

The last command prints the staged app path without opening or stopping any app. Build products and staging stay outside the source tree, which also avoids cloud-provider metadata breaking code signatures. The default interactive `script/build_and_run.sh` stops a running Wokintosh copy before launching the development build; use `--build-only` if you are keeping your usual dashboard running.

Quit your usual copy before opening a development build. To keep test layouts separate, launch the staged executable with an owned temporary profile and sample data:

```sh
/private/tmp/wokintosh-stage-$UID/Wokintosh.app/Contents/MacOS/Wokintosh --data-dir /private/tmp/wokintosh-contributor-profile --preview
```

Sample data is labeled PREVIEW. Do not grant real Music or Calendar access, install hooks in your normal harness configuration, or invoke widget actions unless that is part of your intended manual test. Collector tests use fixtures rather than changing your agent settings.

## Project layout

- `Sources/Wokintosh/`: macOS app, widgets, native sources, settings and window behavior.
- `Sources/WokintoshCore/`: shared models, layout, persistence, transport and installation logic.
- `Tests/WokintoshCoreTests/`: Swift regressions.
- `collector/wokintosh_agent.py`: portable macOS/Linux collector, with tests under `collector/tests/`.
- `script/`: build, development packaging and signed release workflows.

There are no third-party runtime dependencies. Keep the collector compatible with Python 3.10 and both macOS and Linux. Preserve existing layouts, collector protocol compatibility, hook configurations and state when upgrading.

## Changes and validation

Keep changes focused, use plain names, and add meaningful regression coverage for behavioral fixes. Run the relevant tests, then the full Swift or collector suite when shared behavior changes. Exercise collector changes on Linux as well as macOS. For interface changes, include screenshots and check a 1280 × 720 layout with a readable text floor; widgets must adapt to independent sizes rather than assume equal-sized tiles.

Permissions and app launches remain explicit user actions. Unknown agent state should remain unknown; avoid inventing progress or inferring blocked goals from prose. Keep transcript bodies, calendar details, machine credentials and real user profiles out of fixtures, logs and screenshots.

Local handoff notes, agent instructions and development scratch documents are gitignored and must not be committed. Check `git diff` and `git status` before submitting.

## Pull requests

Explain the concrete problem, what users see after the change, and how you verified it. Include relevant test results and any limitations. Documentation and screenshots should describe the final behavior. Original contributions are provided under the project’s [MIT license](LICENSE); retain the [third-party notices](THIRD_PARTY_NOTICES.md).

## Releases

`script/package.sh` makes an ad hoc development ZIP. `script/release.sh` requires a Developer ID Application signing identity and a saved notarytool keychain profile; it produces signed, notarized and stapled release artifacts without publishing them. Never commit signing credentials, private keys or notarization secrets. Versions are set in `script/version.sh`.
