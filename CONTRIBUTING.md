# Contributing to Iris

Thanks for helping improve Iris. Iris is a native macOS menu-bar dictation
app, so the most useful contributions are small, tested changes that respect
the existing module boundaries and privacy rules.

## Development setup

Requirements for the build host (the built app still runs on macOS 14 or later):

- macOS 26.2 or later on Apple Silicon
- Xcode 26.5 or later (Swift 6.3)
- SwiftLint at the version pinned in `.swiftlint-version`

```sh
make setup
make build
make test
```

`make setup` fails when a required tool, including SwiftLint, is missing.

Quit Iris before rebuilding `Iris.app` with `make app` or `make run`: the
bundle build intentionally refuses to replace a running copy.

## Architecture

Keep the dependency direction one-way:

```text
IrisMacOS ─────────► IrisCore
    └─────────────► IrisProviders ─────────► IrisCore
```

- `IrisCore` is portable. Put domain values, ports, settings policy, and
  dictation-session policy there. Do not add AppKit, live networking, disk,
  process, clipboard, or Keychain access. The intentional
  `ProcessInfo.processInfo.systemUptime` monotonic clock is allowed.
- `IrisProviders` contains concrete provider clients and codecs. Providers
  describe requests and use core transport ports; they do not perform live
  I/O directly.
- `IrisMacOS` owns composition and the live macOS adapters. `AppComposition`
  is the place that constructs live system objects. Settings and UI code
  should call application commands rather than live adapters.
- A new target dependency, unchecked `Sendable` conformance, detached task,
  or listed live-I/O reference is an explicit architecture change. Update
  `Tools/ArchitectureRules` and its fixtures only with a concrete ownership
  or safety argument.

See `docs/architecture.md`, `docs/providers.md`, and
`Tools/ArchitectureRules/README.md` before changing a boundary.

## Privacy rules for changes

- Never commit API keys, session IDs, real transcripts, microphone recordings,
  clipboard contents, or unredacted provider errors.
- Keep API keys in the Keychain-backed secret store and out of plain
  preferences and logs. Do not add new plaintext copies; a legacy copy may
  remain only while its Keychain import is unconfirmed.
- Tests must use in-memory stores and injected fakes, not the user's Keychain,
  general pasteboard, live provider accounts, or real dictation.

## Before opening a pull request

Run the same gates as CI, sequentially:

```sh
make format-check
make lint
make architecture-test
make build-strict
make test-strict
```

Also run `make dist` when a change touches packaging, signing, entitlements,
or the release workflow.

For user-visible changes, update the README or the relevant file in `docs/`.
For UI changes, include before/after screenshots or a short recording when
that helps review, and check keyboard navigation, VoiceOver labels, Reduce
Motion, Reduce Transparency, and increased-contrast appearance.
