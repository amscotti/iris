# Settings and providers: design notes

Why Settings and the provider panes behave the way they do.

## Opening Settings in a menu-bar app

[Apple's accessory activation policy](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory)
explicitly allows programmatic activation and clicking windows while keeping
the application out of the Dock. A regular activation policy is not required.

The old implementation mixed a SwiftUI `SettingsLink`, a private
`showSettingsWindow:` action, and window-list heuristics. The foreground hook
mostly ran at creation rather than on every request. The earlier attempt to
insert `moveToActiveSpace` also combined mutually exclusive collection flags
on a SwiftUI-managed window, causing an AppKit exception.

The MenuBarExtra/Settings scene problem is also described in
[Peter Steinberger's investigation](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items).
His hidden-window and regular-policy workaround does not fit Iris's product
requirements. Iris owns a normal `NSWindow` through
`SettingsWindowController`, while SwiftUI continues to render the controls.

The controller:

- Keeps one window alive after closing; every opening path reuses it.
- Coordinates first presentation with AppKit's launch notification and the
  default run-loop mode, after menu tracking releases focus. It does not gate
  on the asynchronously updated `NSRunningApplication.isFinishedLaunching`
  flag, which can strand the first request after the notification has passed.
- Orders that specific window forward, activates the accessory app, and
  makes it key again when activation finishes.
- Uses `hidesOnDeactivate = false` and a normal window level. Other active
  windows, including System Settings permission panes, can cover it normally;
  it is not always-on-top. It does not repeatedly activate Iris or steal
  keyboard focus. Minimization/zoom remain disabled.
- Assigns a compatible `moveToActiveSpace` / `fullScreenAuxiliary` behavior
  set only to the window it creates, before presentation.

Relevant Apple references:
[showWindow](https://developer.apple.com/documentation/appkit/nswindowcontroller/showwindow(_:)),
[hidesOnDeactivate](https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate),
[normal window level](https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct/normal),
[moveToActiveSpace](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/movetoactivespace),
[fullScreenAuxiliary](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary).

## Settings UX

[Apple's Settings HIG](https://developer.apple.com/design/human-interface-guidelines/settings)
recommends stable, noncustomizable pane navigation, a title identifying the
current pane, restoring the last pane, and dimming minimize/zoom controls.
Those are native AppKit toolbar/window behaviors in Iris.

The visual direction is a compact macOS utility: system surfaces, system accent
color, SF body text, restrained rounded headings that echo the dictation pill,
and monospaced model/template text. The provider route graphic—voice → provider
→ text—shows which service is actually in use. Controls retain native keyboard
focus, labels, and adaptive colors.

The information architecture follows the person's task:

- **Choose a provider:** a source list opens one provider's detail panel.
  An explicit Use action changes the route; selecting a row does not silently
  change where speech goes.
- **Set it up:** credentials, connection feedback, recognition language, and
  custom vocabulary stay together, including for inactive providers.
- **Know the state:** key presence, key-access errors, and connection
  verification are separate. A stored key is never labeled Ready by itself.
- **See only what is relevant:** replacement credentials, model controls,
  reasoning effort, and permission troubleshooting appear on demand. This
  applies [progressive disclosure](https://www.nngroup.com/articles/progressive-disclosure/).
- **Keep control of rewriting:** None is always available; adding a prompt
  does not enable it. Prompts are shared text-only instructions. Model and
  reasoning controls live in each provider's settings.

## Controller and module ownership

`SettingsController` owns loading, sanitization, persistence, backed-up recovery,
prompt edits, and configuration-change publication. `ProviderAccessController`
owns credential mutations, connection invalidation, and descriptor-normalized
configuration assembly, using the caches and revision checks in
`ProviderCredentials` and `ProviderConnections`. A failed credential mutation
preserves the cached key and existing verification; successful edits invalidate
it. The key editor's `ProviderKeyDraftActions.save` submits a trimmed value,
preserves the original bound draft on failure, and clears it only on successful
persistence. `ProviderKeyDraftTests` exercises that same transition with a failed
save and successful retry. Speech-option changes invalidate affected checks,
including the removed and added names of a renamed speech-bearing namespace;
prompt/rewrite-only changes do not.

Key-presence queries follow descriptor metadata, while credential caching/key
state and startup readiness have their own owners. The shipped editor continues
to support only `apiKey`; these separate queries do not imply a new authentication
capability. Unreadable-settings recovery first writes a secret-redacted backup;
unknown or unparseable data is omitted in favor of a marked placeholder, not
preserved as unexamined bytes. A failed backup retains the load issue and in-memory edits without publishing a
replacement.
Controller regressions assert recovery retry and namespace-change publication;
application tests assert speech verification invalidation and missing-key gate
resumption after a credential save.

`AppEnvironment` exposes those read models and delegates commands, coordinating
startup, presentation, and permission suspension with `DictationRuntime`.
`SettingsWindowController` separately owns the window and native toolbar.
`AppComposition` constructs the live stores/adapters and injects the registry,
probe, ports, clipboard commands, and application defaults. Offline preview
assembly lives in `Sources/IrisMacOS/App/Preview`, using private memory stores.
`PreviewIsolationTests` exercises that actual assembly's independent settings/
credential stores and inert runtime/clipboard ports. The selected preview I/O
rule includes the developer capture tool, with narrow PNG/report/diagnostic
exceptions; it does not exclude the folder.

Concrete Meta/Grok/Mock integration lives in `Sources/IrisProviders`, which
depends on `IrisCore`. Core owns the provider contracts and shared session
policy. See [Architecture](architecture.md) for the target graph and
[rule maintenance](../Tools/ArchitectureRules/README.md) for its enforcement.

## Provider and recording behavior

A persisted provider name that is not registered in this build is a distinct
startup blocker, not a missing API key. The menu and Settings banner route to
Providers, which offers a registered replacement instead of an editor for the
unknown route. Descriptor-required secret fields seed credential state before
the first save, so a multi-secret provider cannot appear ready after only one
field is saved.

The Grok client follows the
[xAI speech-to-text documentation](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text):

- WebSocket `/v1/stt`, Bearer authorization on the upgrade, raw PCM audio.
- Wait for `transcript.created` before sending audio.
- Finish a one-shot session with `audio.done`; `transcript.done` completes it.
- `is_final` locks a chunk; `speech_final` stitches an utterance, not the whole
  held take. Keep completed utterances and replace overlapping chunk text.

Iris retains those segments if a completion marker contains no text and
finishes immediately on the final event instead of waiting for a socket close.
For an established recording, release stops capture, drains converted/buffered
audio, and only then sends the end marker, preventing the last word from being
discarded. Release or hotkey-feed EOF during startup instead cancels the reserved
take without waiting for an ACK. See [Input recovery](input-recovery.md).

`AppEnvironment` publishes controller settings and the configuration assembled
by `ProviderAccessController` together to the runtime's `PressConfigurationBox`.
A press captures the provider, key, prompt, and rewrite route together, so a
mid-take switch applies to the next take. The box contains only settings and
configuration; service/rewrite factories retain their registry dependency.
The orchestrator separately supports stored configuration with local updates or
an externally supplied source; local updates return `false` for a source-owned
instance. The Meta wire rate is normalized to the capturer's actual 16 kHz output.
A blank Grok rewrite model resolves to
Grok's default instead of Meta's.

Keychain reads are cached, including failures until an explicit retry. A legacy
plaintext secret remains in preferences only while its Keychain import is
unconfirmed; a read/write failure preserves that possible only copy, and a
confirmed import is scrubbed. Tests must supply their own persistence and secret
stores; the live stores are constructed only by the app entry point. All
environment tests use in-memory stores, and connection tests use injected probes.

## Provider-owned rewriting and latency

Provider-specific configuration, labels, wire clients, connection details, and
rewrite capabilities live under `Sources/IrisProviders/Meta` and
`Sources/IrisProviders/Grok`, with `MetaProvider.swift` and `GrokProvider.swift`
as the integration entry points.
The app consumes the `DictationProvider` and `RewriteAdapter` interfaces. A third
provider fixture exercises a different HTTP response format and custom reasoning
tokens without changes to application dispatch or settings views. See
[Provider modules](providers.md).

Prompts contain only text, name, ID, and order. Older per-prompt model/effort
choices migrate to provider settings, preferring the selected compatible prompt.
Switching providers preserves the shared prompt library and each provider's own
model and reasoning choice.

Rewriting is usually the slowest stage of a take: transcription typically
finishes within a few hundred milliseconds of release, while a rewrite can take
seconds. [Meta's reasoning documentation](https://dev.meta.ai/docs/reasoning) and
[xAI's reasoning documentation](https://docs.x.ai/developers/model-capabilities/text/reasoning)
both describe higher reasoning effort as a latency tradeoff, so the defaults use
the lowest available effort. The `latency` log category separates capture drain,
release-to-transcript, and rewrite durations. Sessions close on the final event
instead of waiting for a later socket close.

The reviewed rewrite/latency call sites include provider/model/reasoning metadata
instead of raw transcript or API-key values. Typed notices pass through `PillController.present` for stable
severity/label logging, icon choice, and announcement; `AppEnvironment` logs
dictation-error events without raw message details, even privately. Core keeps
portable app/client diagnostics; startup blocker labels live in
`Sources/IrisMacOS/UI/StartupReadinessPresentation.swift`, and typed-notice wording in
`NoticePresentation`. Selected source guards and these call-site checks are not
a global semantic privacy proof.

## Manual device check

Automated tests use provider/network doubles and private stores and do not
request or reset privacy grants. Some permission diagnostics read current
authorization status. Check live services, Keychain access, and permission
prompts by hand after significant changes:

1. Launch the built app, allow access to the stored key if macOS asks, then use
   Providers → Grok → Test connection.
2. Select Use Grok and dictate a short sentence into another app, including a
   pause mid-sentence and two consecutive takes. Repeat with Meta.
3. Open Settings from the menu on a fresh launch, after closing it, and after
   returning from System Settings; check multiple Spaces and full-screen apps.
