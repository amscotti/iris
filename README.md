# Iris

Iris is a menu-bar dictation app for macOS, named for the messenger of the
gods: it carries your voice into text. Hold a hotkey, speak, and the
words are typed at the cursor in whatever app has focus. A small capsule
follows the pointer with a live waveform while you talk; on release, the
final transcript is inserted (plus a trailing space by default). Optional
rewrite prompts can clean up the text through the same API before it lands.

The app has no Dock icon. Open Settings, turn on Launch at Login, or quit from
the menu-bar extra.

**What you need:** an Apple Silicon Mac running macOS 14 or later, Microphone
and Accessibility permission, and your own Meta Model API or xAI API key. Iris
has no Iris account, subscription, or bundled API credits; the provider you
choose bills usage to your provider account.

## Install

1. Download `Iris-<version>-macos.zip` and its `.sha256` file from the
   [latest release](../../releases/latest)
   (Apple Silicon, macOS 14 or later). Optionally verify the download with
   `shasum -a 256 -c Iris-<version>-macos.zip.sha256`, then move `Iris.app`
   to Applications.
2. The workflow-produced release build is not notarized, so macOS blocks its
   first launch. Try to open it once, then go to **System Settings →
   Privacy & Security** and click **Open Anyway** (on macOS 14, Control-click
   the app and choose **Open** instead).
3. From the menu-bar icon, open **Settings → Permissions** and grant
   Microphone, then Accessibility.
4. In **Settings → Providers**, select the provider whose account you want to
   use and paste its API key: a [Meta Model API](https://dev.meta.ai/) key or
   an [xAI](https://console.x.ai/) key. You only need one provider. Iris
   switches to the provider whose key you add first; change it later with
   **Use Meta** / **Use Grok**.
5. Hold Right Option, speak, and release.

Prefer to build it yourself? See [Build](#build).

## Privacy

Iris has no server of its own; you bring your own API key.

- While you hold the hotkey, microphone audio streams directly to the provider
  you selected (Meta or xAI), which transcribes it under that provider's terms.
  The capture/transcription pipeline keeps audio in memory and does not create
  audio recordings on disk.
- If you select a rewrite prompt, the transcript is also sent to that
  provider's chat API.
- API keys are stored in your Keychain and stripped from plain preferences once
  Keychain storage is confirmed. A legacy plaintext key may remain only while
  its import is pending, including after a failed Keychain read/write, so its
  only copy is not lost. Reviewed dictation, pill, transport, and rewrite
  logging call sites record status metadata, counts, and timings rather than
  raw transcripts or API keys.
  Provider error details remain in the UI; dictation and pill logs omit them,
  including in private log mode.
- Usage is billed to your own provider account.

Source rules guard selected known I/O/storage APIs in the audio and provider
scopes. Those checks and the logging review are regression defenses, not a full
semantic privacy or data-flow proof. See the
[rule guarantees](Tools/ArchitectureRules/README.md#focused-io-guards-and-limits).

## Inspiration

The hold-to-talk overlay, cursor-following pill, and streaming transcription
come from dictation in the [Meta AI desktop app](https://www.meta.ai/). That
product is a full desktop application. Iris is just the voice transcription
piece: capture, transcribe, and insert, using
[Muse Voice Transcribe](https://dev.meta.ai/docs/speech-to-text)
on the Meta Model API, or [Grok Speech to Text](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text)
on the xAI API. Switch providers in Settings → Providers; each one keeps its
own API key in the Keychain and its own preferences, so switching never
wipes the other provider's setup. Rewrite prompts use that same key: Meta posts
to `api.meta.ai`, Grok posts to `api.x.ai` with `grok-4.6`.

Iris is an independent project. It is not affiliated with, endorsed by, or
sponsored by Meta Platforms, Inc. or xAI; product names are trademarks of their
respective owners.

## Build requirements

- **App runtime:** macOS 14 or later on Apple Silicon.
- **Build host:** macOS 26.2 or later on Apple Silicon, with Xcode 26.5 or later
  (Swift 6.3). Xcode 26.5 requires the newer build-host OS; the app itself still
  targets macOS 14.
- SwiftLint at the version pinned in `.swiftlint-version` (required by
  `make setup` and asserted by `make lint`; CI installs it)

## Build

```sh
make setup
make build
```

`make setup` fails when a required tool, including SwiftLint, is missing.

Pushes to `main` and pull requests run format, lint, architecture rules, a warnings-as-errors
build (including test targets), warnings-as-errors tests, and a release
packaging check (`make dist`) on macOS 26 with Xcode 26.5
(see `.github/workflows/ci.yml`). The local compilation and architecture gates are:

```sh
make build-strict
make test-strict
make architecture-test
```

`make build` / `make test` are the plain (warnings allowed) local variants.
Strict compilation also checks explicitly declared target dependencies and
direct defining-module imports for extension members (`MemberImportVisibility`).
Architecture rules use a separate, pinned Harmonize/SwiftSyntax
test package; those dependencies are not linked into Iris. See the
[rule guarantees and maintenance guide](Tools/ArchitectureRules/README.md) for
the selected syntax checks and their limits.
`Scripts/build_app.sh` also builds with `-warnings-as-errors` unless
`ALLOW_WARNINGS=1` is set.

## Test

```sh
make test
```

App-environment tests use private, in-memory settings and secret stores.
They do not access your Keychain or make live provider requests. Explicit
Settings-window lifecycle and startup-gate tests do present Settings; the other
test-isolation guarantees still apply. The complete input graph also uses
injected capture, keyboard, focus, insertion,
authorization, and system-event ports. Provider conformance tests enumerate the
application's registered providers and exercise active startup, send, and finish
cancellation. Non-cooperative failure tests use manually released continuations.
Controller tests cover persistence recovery and credential policy; pure
transition sequences cover stale input, startup cancellation, and readiness
precedence. Run `make architecture-test` for the complementary source/module rules.
Send-race tests distinguish retained provider failures from write teardown and
bound cancellation-only delivery settlement. Runtime suspension journeys cover
revoked grants, repeated takes, overlapping cleanup, timeout quarantine, and
concurrent stop/start observation. Preview-isolation and bound-editor-draft tests
exercise the actual offline assembly and the editor's save transition.
Clipboard adapter tests use uniquely named private pasteboards, never
`NSPasteboard.general`. Permission diagnostics may read current authorization
status; tests do not request or reset privacy grants.

## Lint and format

```sh
make lint
make format
make format-check
```

Formatting is owned by `swift-format` (via `xcrun swift-format`).
Linting uses `swiftlint` with the formatting rules disabled so the two tools agree.
Both gates cover the architecture package's tests; formatting also covers its
manifest.

## Run

```sh
make run
```

This assembles `Iris.app` via `Scripts/build_app.sh` and opens it.
Use the microphone menu to open Settings or quit.

**Quit Iris before rebuilding its app bundle.** The build refuses to replace
a running copy, builds/signs in a staging directory, then checks again before
installation. Use quit → rebuild → relaunch; live bundle replacement is not
supported. `swift build` and `swift test` do not replace `Iris.app`.

To build the debug bundle without launching:

```sh
make app
```

A release-optimized `Iris.app` plus zip:

```sh
make dist
# or VERSION=0.2.0 BUILD=12 make dist
```

writes `dist/Iris-<version>-macos.zip` plus a `.sha256` checksum.
`make zip` refuses a missing bundle or a bundle whose
`CFBundleShortVersionString` does not match `VERSION`.
`VERSION` should be numeric `X.Y.Z` (it becomes `CFBundleShortVersionString`;
the Release workflow rejects anything else);
`BUILD` is the numeric `CFBundleVersion` (`github.run_number` on CI,
default `1` locally, so local and CI zips for the same `VERSION` differ
by build number by design). The build is incremental; run `make clean`
first for a from-scratch bundle.

## Layout

- `Sources/IrisCore` — portable domain, ports, and session/orchestration policy;
  effect owners also schedule work, enforce deadlines, and read monotonic time
- `Sources/IrisProviders` — concrete Meta/Grok clients, codecs, and debug Mock provider; depends on core
- `Sources/IrisMacOS` — menu-bar app and system adapters
  - `App/` — composition, settings/provider-access controllers, the `AppEnvironment` UI model,
    and offline preview assembly in `App/Preview/`
  - `Runtime/` — `DictationRuntime`, readiness policy, and injected runtime ports
  - `Adapters/` — platform adapters, including native system-event observation
  - `UI/` — Settings, menu-bar extra content, and pill presentation
- `Sources/MockASRServer` — local stand-in server for manual/integration use,
  with no automated test target (unit tests use an in-process transport double)
- `Tests/IrisCoreTests` — domain/session/provider and pure-transition unit tests
- `Tests/IrisMacOSTests` — app-target tests (settings, pill, insertion, hotkey)
- `Tools/ArchitectureRules` — pinned, test-only Harmonize/SwiftSyntax architecture rules and syntax fixtures
- `docs/` — [architecture](docs/architecture.md), [input recovery](docs/input-recovery.md),
  [provider modules](docs/providers.md), and [settings design notes](docs/settings-and-providers.md)

## MockASRServer

A tiny executable that speaks the production wire shapes
(JSON handshake, session ACK, transcript events) over plain WebSocket,
for manual and integration use:

```sh
swift run MockASRServer -- --port 8080
swift run MockASRServer -- --help
```

Connect to `ws://127.0.0.1:8080` (the server binds loopback only).
A handshake whose `authorization.accessToken` contains `bad-key`
gets a 401 error, which exercises the auth-failure path.
Inbound messages are capped at 1 MiB, fragmented messages are reassembled,
unmasked client frames are dropped per RFC 6455, and a peer idle for
30 seconds is disconnected.

## Permissions the app will request

- **Microphone** — to capture dictation audio. The bundle includes
  `NSMicrophoneUsageDescription` explaining why.
- **Accessibility** — to detect the configured hotkey globally and to insert the
  finalized transcript at the cursor in the frontmost app. Iris triggers the
  system prompt from **Settings → Permissions**, not automatically on first
  hotkey use; grant it under Privacy & Security.

Grant both from Settings → Permissions (or the system panes it opens).
Iris checks live authorization before capture and suspends dictation around
permission changes. Its hotkey monitor observes asynchronous event copies,
so it does not sit in the desktop's input-delivery path. Sleep/wake recovery
cancels an old take and requires a fresh press. See
[Input recovery](docs/input-recovery.md) for the design and the rebuild
policy. After a local ad-hoc rebuild, macOS may require approval for the new
build; request it after relaunching from Settings.

The audio pipeline and logging policy are described under [Privacy](#privacy).
API keys are kept in the Keychain; legacy plaintext copies are scrubbed after
confirmed import and retained only while that import is pending.

## Dictation

Hold Right Option (the default), speak, release: the pill follows the cursor
with a live waveform, and the finalized transcript is typed at the cursor.
In hold-to-talk mode, pressing another key while holding the shortcut (for
example ⌥ plus a letter to type a symbol) cancels the take silently, so Option
still types accents and symbols. In press-to-start/stop mode, an established
recording stops on the release of a second unchorded shortcut press; a typing
chord leaves that recording running. While a take is active, **Cancel Dictation**
discards it without inserting. **Copy Last Dictation** explicitly copies the
latest non-empty final when you need to recover it after an insertion failure;
nothing is copied automatically in response to that failure. The menu shows
**Inserting…** until the insertion worker finishes.
A take is finalized normally at 54:30, before the provider's 55-minute hard
session cap, so long dictations are inserted rather than discarded. Screen lock,
display sleep, and workspace sleep/session changes suspend capture independently.
Grant microphone access first, then Accessibility; without either, the menu
bar explains what to enable and nothing is inserted. Text is never injected
into a positively identified secure field — it is copied to the clipboard instead.
(Best-effort check: only a field macOS positively reports as `AXSecureTextField`
is refused; an unreadable focus target is treated as insertable.)
In clipboard-paste mode, Iris restores restorable previous contents only if
the clipboard revision still belongs to its paste. Empty or concealed previous
contents are not restored; after a successful transcript write, the transcript
stays available instead. Not restoring a copied password is deliberate and is
reported for privacy. A previous snapshot that could not be kept within its
size/time budget, or became unusable while being read, is also not restored.
A failed paste post leaves the transcript for manual pasting. A newer user copy
is preserved: if a saved snapshot's revision changed before the transcript
write, insertion is skipped; a copy made during the restore window is left alone.

If a clipboard owner stops responding while Iris reads its previous contents,
later clipboard operations have a bounded wait. A paste that cannot write or
verify the clipboard is skipped with a notice, rather than freezing Settings
or claiming that the transcript was copied. If a keystroke insertion stops
mid-text, only the untyped remainder is copied; the notice says so explicitly.
An insertion deadline cancels late keystroke and paste side effects instead of
allowing them to land in a newly focused app.

Optional rewrite prompts live in Settings → Prompts and in the menu-bar
Prompts menu. None (the default) inserts the transcript as-is. A selected
prompt rewrites the take after it finalizes; if the rewrite fails, the
original text is still inserted.

Live check: park the cursor in TextEdit, hold Right Option, speak, release,
and confirm the words land at the cursor exactly once. The scripted offline
pipeline (mock provider, scripted hotkey/audio, recording inserter) runs
under `make test`. The mock provider is not shown in Settings.

## Settings

Open Settings from the menu-bar extra (⌘, while the menu is open). When setup
is incomplete, the menu lists each missing step as a shortcut to its fix; once
ready, it shows how to dictate and which provider is in use. One retained
window, six native toolbar panes, with the last pane restored:

- **Providers** — select Meta or Grok to manage its key, rewrite model and
  reasoning, language, and custom words. **Use Meta / Use Grok** changes the
  active provider. Less-common speech controls are under **Advanced options**.
- **Shortcut** — choose the key and hold-to-talk or press-to-start/stop behavior.
- **Prompts** — one shared library of text-only rewrite instructions and an
  always-visible None choice. All prompts use the active provider's own model
  and reasoning settings. New prompts start unselected.
- **Typing** — keystroke or clipboard insertion, space, and newline preferences.
- **Appearance** — a live pill preview, waveform colors, translucency, and motion.
  Reduce Motion freezes the bars and snaps the pill rather than interpolating
  its cursor-follow movement. Preview is disabled during a live take.
- **Permissions** — microphone and Accessibility status with direct actions
  and collapsed troubleshooting.

**Key saved** means a credential is stored, not that the provider has accepted
it. **Test connection** verifies the speech-session handshake without recording
audio. **Paste** rejects clipboard entries marked concealed by a password
manager, so they cannot silently become a provider key. If a persisted provider
is unavailable in this build, Iris blocks readiness and routes you to choose a
registered provider instead of accepting a key for it. Failed saves preserve the draft and explain the problem. A cancelled or
failed Keychain read waits for **Try again**, instead of prompting on every
activation. Each provider's credentials are loaded when needed and cached for
the app session.

Unreadable or newer-version settings block persistence instead of being
overwritten by defaults. **Retry reading settings** retries the original payload.
**Back up and use defaults** explicitly writes a secret-redacted backup before
recovery. Known non-secret fields are preserved; unrecognized or unsupported data
is represented only by a marked placeholder (with its original byte count), never
by unexamined bytes. If the backup fails, the original stays untouched. Load and save errors are both
shown. A transient read failure must be resolved before replacement is allowed.

Settings stays an accessory window: opening it never changes Iris's activation
policy or adds a Dock icon. The same AppKit controller handles initial setup,
the Settings menu item, and Edit prompts. Microphone capture uses 16 kHz mono
PCM for both providers; the wire configuration always matches that rate.

Design rationale and a manual device checklist are in
[Settings and providers](docs/settings-and-providers.md).

### Settings preview

Inspect the native UI with temporary data, without Keychain access, microphone
capture, a global hotkey, or live network calls:

```sh
make app
open -n Iris.app --args --preview-settings
```

The window is titled **Iris Preview**, and edits stay in memory. To also capture
the panes and a focus/lifecycle report, supply an output directory:

```sh
open -n Iris.app --args --preview-settings --preview-output=/absolute/output/directory
```

These flags are available only in debug builds.
`PreviewIsolationTests` exercises the actual preview assembly with separate
memory stores and inert input/clipboard ports. The preview source rule guards
selected live-adapter APIs; requested PNG/report output has narrowly reviewed
exceptions, rather than an excluded preview folder.

## Adding a provider

Provider integration lives in each provider's folder:

- `Sources/IrisProviders/Meta/MetaProvider.swift`
- `Sources/IrisProviders/Grok/GrokProvider.swift`
- `Sources/IrisProviders/Mock/MockProvider.swift`

Implement `DictationProvider` to supply identity, settings and help text,
connection details, the transcription client, and optional rewrite support.
The provider owns model defaults, reasoning choices, request/response formats,
and configuration normalization. The shared app renders and dispatches those
capabilities through `ProviderRegistry`.

To add another provider, add its folder/implementation and one
`register(YourProvider())` entry in `AppProviderAssembly.defaultRegistry()`.
The core registry starts empty. Add its wire fixture to the application provider
conformance suite so startup/write/finish cancellation is verified. There are no provider
switches to update in Settings or the application transport/rewrite code.
Chat-completions-compatible providers can reuse `ChatCompletionsAdapter`;
other APIs implement `RewriteAdapter` directly. See
[Provider modules](docs/providers.md) and the third-provider test fixture for
the full extension contract.

`SessionDriver` owns the continuous reader and serialized writer; provider codecs
own wire encoding and accumulation. `TranscriptionService` consumes live normalized
events and retains an explicit terminal outcome. UI views receive coalesced latest
snapshots with retained notices, separately from lossless terminal events.
If a write fails after the provider has already settled a terminal result,
`SessionDriver` surfaces that result. A cancellation-class send reply with no
settled service outcome gets bounded, take-owned settlement: an unread terminal
can win, otherwise an explicit network failure ends the take.
Unknown providers fail explicitly; they never
fall back to another provider or produce a mock transcript.

### Rewrite settings migration

Model and reasoning are stored in each provider's `providerConfigs` namespace.
The settings repository migrates older per-prompt choices to their owning provider, preferring the
selected compatible prompt, then the first compatible prompt in display order.
Existing provider-level choices take precedence. Prompt text, IDs, order, and
selection are preserved; switching providers no longer rewrites prompt records.

### Diagnosing latency

Console category `latency` reports capture drain, release-to-transcript, and
rewrite durations. Rewrite timings include the captured provider, model, and
reasoning choice; these logging call sites omit raw transcript and API-key values.
Meta's Minimal and Grok's Low are the fastest available defaults. Higher reasoning can add noticeable
post-dictation time.

## Accessibility and keyboard

- The pill is mouse-transparent and never takes keyboard focus, so typing
  focus stays in the target app while dictating.
- VoiceOver announces when recording starts, when rewriting begins, when
  dictation finishes, and when a take needs attention (the pill never takes
  focus). It reads the pill as one element labeled Dictation with the live
  status as its accessibility value.
- The waveform honors reduced motion (system setting, or the override in
  Settings → Appearance) by rendering static bars.
- The whole flow is keyboard-operable: the menu-bar extra opens Settings,
  and its Preview Dictation Indicator item runs a scripted capsule walkthrough for
  reviewing the overlay without speaking. That walkthrough is also the
  easiest way to capture a screenshot or screen recording.

## If dictation fails

Failures show a brief warning icon in the pill (a clipboard icon when the text
was copied instead of typed, and an information icon for non-failure
cancellations), and the full message appears in the menu bar. Stable
notice metadata and diagnostic events are logged
(`subsystem io.github.amscotti.iris`, Console.app: categories `dictation`,
`audio`, `hotkey`, `insertion`, `pill`, `transport`, `rewrite`, `latency`,
`permissions`, `keychain`, `login-item`). The reviewed dictation/pill call sites
omit the message itself, even from private logs; see [Privacy](#privacy).

- Wrong or missing API key: the menu bar points at Settings; nothing retries
  on its own. Set the key again and press the hotkey once more. A missing startup
  key holds input monitoring until saving a key clears the gate; saving it does
  not start capture.
- Microphone access off: the menu bar tells you to enable it in Settings.
  Request it from Settings → Permissions; do not expect a prompt from the
  hotkey.
- Microphone or Accessibility access lost during a take: the take is cancelled
  with warning guidance to re-enable access. Monitoring stays suspended until
  authorization returns; recovery requires a fresh press.
- Dropped network, rate limit, or an abnormal close with no completion event:
  capture stops immediately, the menu bar shows an error, and nothing is
  inserted. A normal Meta close after `endStream` can instead complete the
  turns already received. Release the shortcut and begin a fresh take after
  cleanup completes.
- A press during finalization or cleanup does not start a delayed recording.
  Busy guidance never replaces a retained provider or rewrite failure.
- If cleanup exceeds its two-second deadline, or text insertion stops
  responding, the menu bar asks you to restart Iris. Input stays suspended
  until restart; permission changes and wake events cannot reactivate an
  unfinished generation.
- A press that ends almost immediately with no speech is treated as an
  accidental tap and discarded silently — no error, nothing inserted. This
  covers a blank result or a server close with no completion event; a quick
  auth, rate-limit, or network failure still surfaces.
- Secure fields (password managers, secure text fields) are positively
  identified, and Secure Keyboard Entry is respected for the app that holds
  it: keystroke injection is refused there and the text is copied to the
  clipboard instead.

## Distribution and signing

`make app` builds a debug `Iris.app` with a rasterized icon (hand-drawn
`Assets/icon.svg`, converted at build time with `sips` + `iconutil` — the
only image source in the repo), the `io.github.amscotti.iris` bundle id,
and the hardened runtime, signed ad-hoc unless `SIGN_IDENTITY` is set.

`make dist` does the same with `swift build -c release` and zips the bundle.

Pushing a version tag publishes that zip as a GitHub Release (after CI):

```sh
git tag -a v0.1.0 -m "Iris 0.1.0"
git push origin v0.1.0
```

The tag must be annotated (`-a`) and numeric (`vX.Y.Z`): the Release
workflow rejects lightweight tags, verifies the tag, and validates the
version before it becomes `CFBundleShortVersionString`. Tagged builds require
all three `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, and
`MACOS_SIGN_IDENTITY` secrets; if any is missing, the workflow fails instead of
publishing an ad-hoc app.

A manual non-tag run of the Release workflow builds
`Iris-0.1.0-macos.zip` and its checksum as an artifact without publishing a
GitHub Release. This path may remain ad-hoc when the signing secrets are
incomplete.

The GitHub-built app targets Apple Silicon. For an unnotarized asset,
Gatekeeper blocks the first launch; allow it from System Settings → Privacy &
Security → Open Anyway (macOS 15+) or Control-click → Open (macOS 14).

Local builds are ad-hoc signed unless `SIGN_IDENTITY` names a codesign identity.
macOS identifies an ad-hoc build by its exact code hash, so after each update
Microphone and Accessibility must be allowed again (if Iris still appears
enabled but does not work, use Settings → Permissions → Advanced
troubleshooting → Reset permission state). Signing every release with the same
certificate keeps those grants across updates:

- **Developer ID (recommended):** also allows notarization, which removes the
  Gatekeeper step. `Scripts/build_app.sh` documents the sign → notarize →
  staple → `make zip` sequence.
- **Your own certificate:** create a Code Signing certificate in Keychain
  Access (Certificate Assistant → Create a Certificate), set it to Always Trust
  for code signing, then run `SIGN_IDENTITY="<certificate name>" make dist`.

The Release workflow signs with a Developer ID certificate when all three
`MACOS_*` secrets above are set (a self-signed certificate is not trusted on
the CI runner, so use one only for local builds). The workflow does not
notarize or staple the app: a signed but unnotarized download still needs the
Open Anyway step.

To replace a tag's assets with a locally notarized build, run these commands
from the repository root on a Mac with your Developer ID, a locally configured
`notarytool` keychain profile, and an authenticated `gh` client. Replace the
example identity and profile values:

```sh
VERSION=0.1.0
SIGN_IDENTITY="Developer ID Application: Your Team (TEAMID)" \
  VERSION="$VERSION" make dist
xcrun notarytool submit "dist/Iris-${VERSION}-macos.zip" \
  --keychain-profile "your-local-profile" --wait
xcrun stapler staple Iris.app
make zip VERSION="$VERSION"
gh release upload "v${VERSION}" \
  "dist/Iris-${VERSION}-macos.zip" \
  "dist/Iris-${VERSION}-macos.zip.sha256" \
  --clobber
```

The final `make zip` re-zips the stapled app and regenerates its checksum;
`gh release upload --clobber` replaces both release assets. The app is
non-sandboxed by design for global shortcut monitoring and HID insertion, so
Mac App Store distribution is out of scope. The audio-storage contract and its
selected source guards are described under [Privacy](#privacy).

## Project docs

- [Contributing](CONTRIBUTING.md) — local setup, architecture boundaries, and test gates.
- [Security](SECURITY.md) — how to report a vulnerability privately.
- [Changelog](CHANGELOG.md) — notable changes in each release.

## License

Iris is released under the [MIT License](LICENSE).
