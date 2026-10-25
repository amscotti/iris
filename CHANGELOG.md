# Changelog

All notable changes to Iris are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
`vX.Y.Z` tags.

## [Unreleased]

### Added

- Initial public macOS release preparation: menu-bar dictation with Meta or
  xAI bring-your-own-key providers, optional rewrite prompts, Keychain-backed
  API key storage, signed-release packaging support, architecture rules, and
  the full CI gate.
- Muse Wonder 1.0 is available as a Meta rewrite model preset. Muse Spark
  1.3 remains the default rewrite model.
- Added Cancel Dictation and Copy Last Dictation recovery actions, including
  take-scoped cancellation and explicit clipboard failure feedback.

### Changed

- Settings can now be enlarged beyond its default window size.
- Problem notices stay on screen longer, and the dictation indicator border
  strengthens when macOS Increase Contrast is on.
- Provider settings now explain disabled actions inline and announce
  connection and credential results to VoiceOver.

### Fixed

- Legacy rewrite choices now follow prompt IDs during settings migration
  instead of depending on decoded array order.
- Recognized speech is preserved through graceful take-limit finalization and
  provider cleanup timeouts; abnormal WebSocket closes no longer count as
  successful Meta endpointing completion.
- Lost hotkey releases reconcile from the periodic readiness check, screen
  lock/display sleep suspend capture independently, and a stalled native
  microphone tap fails visibly instead of pacing silence forever. Capture
  failures are take-scoped, and cleanup honors the remaining insertion budget.
- Insertion deadlines cancel late keystroke/paste side effects, partial
  clipboard fallbacks describe only the untyped remainder, and insertion has
  its own menu status.
- Recovery backups fail closed for unknown schemas/providers/fields and
  unparseable payloads; malformed values and forged placeholders cannot bypass
  redaction, damaged backup slots cannot overwrite later backups, and deferred
  migrations retain their actual schema version.
- Unknown persisted providers block readiness with a route to Providers, and
  saving one required secret before the first load cannot mark a multi-secret
  provider ready.
- Rewrite replies with non-stop finish reasons or refusals fall back to the
  original transcript; CJK turns/segments join without spurious ASCII spaces.
- Reduce Motion disables cursor-follow interpolation, preview is disabled
  during live takes, and stale provider errors clear after successful recovery.

### Build and documentation

- Tagged releases now require complete signing configuration and verify the
  signed app; packaging checks bundle versions, plist metadata, and release
  checksums, and setup/clean failures are safer.
- Corrected build-host requirements and release, privacy, permission, and test
  fixture documentation, including the manual notarized-asset upload path.
