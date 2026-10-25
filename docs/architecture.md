# Architecture

An overview of how Iris is put together and the contracts each layer keeps.
See [Input handling and recovery](input-recovery.md) for the lifecycle rules,
[Provider modules](providers.md) for the provider extension contract, and
[Settings and providers](settings-and-providers.md) for UI design notes.

## Targets and dependency direction

```text
Sources/
  IrisCore/        # portable domain, ports, settings, and application/session policy
    Config/        # AppSettings, SettingsRepository, migrations, provider configuration
    Domain/        # PCMFrame, hotkey configuration, state, events, typed notices
    Protocols/     # ports: audio, transport, hotkey, persistence, secrets, insertion
    Transcription/ # transitions, orchestrator, service, driver, deadlines, rewrite prompts
  IrisProviders/   # concrete providers, clients, codecs, and vendor configuration
    Meta/
    Grok/
    Mock/          # debug-only offline provider
  IrisMacOS/
    App/           # composition, provider assembly, controllers, observable UI model
      Preview/     # explicit offline preview assembly and capture tooling
    Runtime/       # input/permission/dictation lifecycle and live ports
    Adapters/      # persistence, permissions, cursor tracking, system events
    UI/            # menu bar, pill, and Settings
  MockASRServer/   # loopback WebSocket fixture for manual/integration use
Tools/
  ArchitectureRules/ # separate test-only Harmonize/SwiftSyntax package
```

```text
IrisMacOS ─────────► IrisCore
    └─────────────► IrisProviders ─────────► IrisCore
```

`MockASRServer` is an independent manual/integration fixture with no automated
test target. Both core and providers import only approved
modules: Foundation/Swift for core, plus IrisCore for providers. Import allowlists,
the declared target graph, and the compiler's dependency-import check protect
provider separation. There is no provider-type-name denylist: names such as
`Error` or `Phase` can legitimately appear in different modules.

Core's orchestrator/session owners intentionally schedule tasks, enforce
deadlines, dispatch blocking insertion through a port, and read monotonic time.
The source policy rejects selected network, disk, process, and Keychain API
identifiers; Foundation-only imports are not a blanket no-effects guarantee.
The core `ProviderRegistry` starts empty; `AppProviderAssembly` registers the
shipped providers and supplies application defaults. `AppSettings.legacyProviderName`
preserves the historical decode fallback independently of that default-provider policy. Repository
migrations use the injected registry.

## Ownership

- `AppComposition` constructs the live adapters and injects registries, service
  factories, probes, authorization, and clipboard access. Runtime components do
  not call back into composition; Settings views issue application commands.
- `SettingsController` owns settings loading, backed-up recovery, sanitization,
  persistence, prompt editing, and configuration-change publication.
- `ProviderAccessController` owns credential editing, connection invalidation,
  and descriptor-normalized configuration assembly. `ProviderCredentials` and
  `ProviderConnections` retain their caches/revision-based cancellation.
- `DictationRuntime` privately owns hardware and task lifetimes through
  explicit `DictationRuntimePorts`: capture, insertion, hotkey, focus,
  authorization, system events, and provider execution.
- `AppEnvironment` exposes controller read models, delegates commands, and
  coordinates startup/presentation and permission suspension with the runtime.
- `DictationTake` owns each take's resources and callbacks; generation checks
  reject stale continuations, including after the service's `requiresRestart`
  read and at rewrite entry.
- The orchestrator's `OrchestratorConfigurationOwner` is either `.stored` or `.supplied`.
  Stored configuration retains the existing `update(settings:config:)` behavior
  for subsequent takes. A supplied source owns its updates; the local update
  API returns `false` for that owner. The macOS runtime supplies a lock-protected
  `PressConfigurationBox` containing settings and provider configuration only.
- `TakeLifecycle`, `HotkeyIntent`, `InputReadiness`, and `HotkeyEdgeState` return
  pure transitions and decisions. The edge classifier uses AppKit event values,
  not live keyboard state. The orchestrator/runtime supply time and execute
  effects; cleanup and generation ownership remain outside these values.

## Session contracts

- **Failures are session-owned.** A genuine audio-delivery or server failure fails
  the take: capture stops once, one error surfaces, and success insertion is
  impossible afterward. Capture-failure callbacks carry the take ID assigned
  before capture starts and are ignored after that take is replaced. Busy-press
  guidance does not overwrite a retained provider or rewrite failure.
- **Send teardown preserves terminal ownership.** `SessionDriver.sendAudio`
  surfaces the retained terminal result when an in-flight write fails after the
  reader settles it. If the service receives a cancellation-class send reply
  before consuming a terminal, its owned `deliverySettlement` task lets the
  unread terminal win within the service shutdown budget. If no outcome settles,
  the task records an explicit network failure. The send caller returns
  promptly; `finish()` joins settlement and cleanup cancels/joins it.
- **Shutdown is bounded.** `TranscriptionClient.cancel()` is required, and
  `AsyncDeadline` bounds cleanup joins without waiting on a non-cooperative child.
  A missed deadline latches an explicit restart-required state. Repeated
  `stop()` calls on a quarantined orchestrator still return `.timedOut`.
- **Startup EOF cancels.** Ending the hotkey feed during startup cancels the
  reserved take without waiting for an ACK or finalizing a phantom recording.
  Cleanup remains bounded; late readiness cannot resurrect the take.
- **One reader, one writer.** `SessionDriver` runs a continuous reader and a
  serialized writer per session; actor-confined provider codecs own wire
  encoding and transcript accumulation. `ByteStream` carries typed
  `.text`/`.binary` messages, and a transport buffer overflow fails explicitly.
- **Streaming duration starts at readiness.** The monotonic session clock begins
  at the ACK, independently of connection/ACK timeout. The orchestrator owns a
  soft take deadline (54:30 by default) that drives ordinary finalization and
  insertion before the driver's hard cap (55 minutes) can reject audio. Audio
  writes check that hard cap as a backstop; limit guidance derives its minute
  value from the driver budget. Tests cover delayed ACK, injected clocks, the
  default uptime clock, and automatic soft-deadline insertion.
- **Close-delimited completion requires a normal close.** Meta endpointing and
  diarization may complete after `endStream` only for a clean stream end or a
  normal/going-away WebSocket close (1000/1001). Abnormal transport drops retain
  their close code and fail instead of inserting a truncated transcript. Close
  metadata does not change `TranscriptionError` kind/message equality.
- **Two observation channels.** UI views receive coalesced latest-only
  snapshots with retained notices; terminal events are delivered losslessly.
  Snapshots also carry the active take ID and whether insertion has started, so
  delayed cancellation is scoped to the intended take and cannot claim to stop
  an insertion already in flight. Terminated subscriptions are removed.
- **Completed results survive cleanup quarantine.** A cleanup timeout still
  latches restart-required, but a retained completed transcript is inserted
  before that quarantine. A timed-out insertion is invalidated through the
  inserter's generation token so late AX/pasteboard returns cannot post into a
  newly focused app.
- **Insertion target.** A target is captured at press start and forwarded
  through rewriting. Insertion deliberately follows the focused app at insert
  time and logs a change of process.

## Settings persistence

`SettingsRepository` versions the stored payload and reports missing, loaded,
unsupported-version, corrupt, and unavailable outcomes. An unreadable payload
blocks ordinary writes, so defaults never silently overwrite it. Explicit
recovery first writes a secret-redacted backup (retaining older backups). Known
non-secret fields are preserved; unknown providers/fields, unsupported schemas,
and unparseable nonempty payloads become a marked placeholder rather than an
unexamined byte copy. Load and save errors are surfaced together. A failed backup leaves the original
payload, in-memory edits, and load issue intact for an explicit retry. Secret
fields are stripped before persistence and live in the Keychain. A legacy
plaintext field remains only while its Keychain import is unconfirmed, because
it may be the only copy after a read/write failure; confirmed imports are
scrubbed from preferences.

Application defaults are injected for missing/unreadable settings and explicit
recovery. Retrying a legacy payload writes a new version only when migration
actually completed; rewrite choices remain untouched without a descriptor.
Speech-option changes invalidate connection verification, including both names
when a speech-bearing namespace is renamed; prompt/rewrite-only edits do not.
Failed saves still publish the sanitized in-memory configuration with a visible
persistence error.

## Notices

`InsertionNotice` carries a stable reason; `DictationNotice` carries insertion,
cancellation, restart, failure, or no-speech semantics and stable category/severity.
Runtime and insertion callbacks pass these values. `NoticePresentation` maps
them to wording, and the pill chooses its icon by category and announces the
message. `PillController.present` logs `NoticePresentation.logLabel` at the stable
severity; `AppEnvironment` logs a fixed dictation-error event. Neither call site
logs the message, even with private-log collection enabled. Provider error
details remain available in the UI without controlling the icon. These reviewed
call sites and the label test are not a global semantic logging/privacy proof.

Provider errors and blank finals arrive through the existing observation path;
typed failure/no-speech presentation belongs inside the pill's handling of those
states, without a second callback delivery of the same results. Insertion,
suspension cancellation, and restart notices retain their runtime callback path.

Core keeps portable diagnostic text, including generic app/client restart and
session guidance. Presentation owns typed-notice copy and startup blocker labels:
`StartupReadiness.MissingItem.label` is defined in
`Sources/IrisMacOS/UI/StartupReadinessPresentation.swift`.

For permission/sleep/session suspension, `InputRuntimeState` supplies the typed
cause and `PermissionSnapshot` retains the first cause through cleanup. System
sleep, display sleep, workspace session state, and screen lock are independent
inputs; wake/activation from one source cannot clear another source's suspension.
Externally revoked microphone/Accessibility grants produce `.microphoneDenied` or
`.accessibilityDenied` warning guidance. Core captures the actual take ID when
`requestStop` atomically transfers ownership to the cleanup task. The
cancellation callback is bounded and joined with that cleanup, rather than
discovering the take through a later `activeTakeID` query. Explicit user
cancellation carries its reason and expected take ID through the same closure;
it does not overwrite the suspension reason. An idle stop has no take to announce;
ordinary runtime stop/quit suppresses cancellation notices.
`lifecycleGeneration` prevents a retiring stop/start observation from cancelling
or delivering snapshots through its replacement. Clipboard notices distinguish
copied text from problems: unavailable restore access remains a problem because
it cannot prove the transcript is still on the clipboard. See
[clipboard outcomes](input-recovery.md#clipboard-transactions-and-notice-meanings).

## Executable architecture decisions

Configured verification commands, run sequentially after changes are complete:

```sh
make build-strict
make test-strict
make architecture-test
```

Strict application compilation enables SwiftPM's explicit dependency-import
check, `MemberImportVisibility`, and Swift 6 concurrency checking. Extension
members therefore require their defining module's direct import instead of
depending on transitive visibility. The separate architecture package pins Harmonize 1.3.0,
SwiftSyntax 601.0.1, and Yams 5.4.0 for configuration validation; none enters the
application dependency graph. Its serialized suite checks import allowlists,
selected live-I/O identifiers/call shapes, runtime-to-composition references, the
four named transition files, and the exact six-target manifest graph.

`coreDoesNotReferenceSelectedLiveIOAPIs` and
`viewsDoNotReferenceSelectedLiveIOAdapters` guard explicit identifier lists.
`providersDoNotReferenceSelectedLiveIOAPIs` adds provider-scoped live-API and
recognized Foundation file-I/O checks while permitting request values and
`ByteStream` operations. `audioPipelineDoesNotReferenceSelectedStorageAPIs`
scans all Core and Providers files plus the exact
`Sources/IrisMacOS/Runtime/AVAudioEngineCapturer.swift` path for selected direct
storage/process APIs and recognized Data/String file operations.

`previewAssemblyDoesNotReferenceSelectedLiveIOAdapters` scans all
`Sources/IrisMacOS/App/Preview`, including the developer capture tool.
Supplied-snapshot permissions are allowed;
four exact file/qualified-owner/API/reference-count exceptions permit directory
creation, PNG/report output, and the report's code-signature Boolean. No entire
file or folder is excluded; same-count replacements still require diff review.
These selected syntax guards do not resolve arbitrary
external helpers, data flow, dynamic calls, or macro expansions, and do not prove
what an allowed port or logger persists.

`observableStateAndReviewedControllersAreMainActorAnnotated` automatically
includes new and nested Observable classes in IrisMacOS alongside the reviewed
controller roles, requiring unconditional class-level MainActor annotations. It does not
audit every member's isolation. `dictationOrchestratorRemainsAnActor` checks the
named declaration kind/count, not confinement of every take resource.

Unchecked-Sendable exceptions are scoped by written qualified declaration/file
with safety reasons, including extension conformances; stale or duplicate keys
fail. `nonisolated(unsafe)` has the same exact-inventory policy: the sole
reviewed exception is `AVAudioEngineCapturer.captureFailureHandler`, whose
reads and writes are serialized by `captureFailureLock`; any new, moved, or
removed declaration requires updating that inventory and its safety argument.
Detached policy counts syntax **reference sites** by owner/file, including
explicit aliases and captured function references. A single reference can launch
multiple tasks, and same-count replacements still need ordinary diff review.
Neither count nor syntax matching proves cancellation or joining.

Repository discovery walks upward from `#filePath`, validates the root
`.harmonize.yaml` and rejects nearer conflicting configs, and requires exact,
nonempty source folders. Manifest inspection evaluates the real `Package.swift`
with a unique tool-owned `.build/manifest-inspection/` scratch cache and inherited
stderr, avoiding the application's SwiftPM build lock. Root exclusions cover
listed build/bundle outputs; visible generated and untracked Swift files within
the selected production folders participate. Macro expansions are not expanded.

Syntax fixtures cover modified/selective imports, conditional branches, explicit
aliases, qualified references, extension/unchecked declarations, nested Observable
classes, detached reference spellings, recognized storage receivers, snapshot
permission initializers, and narrow preview-output exceptions. Source analysis is
not a type-checked call graph or proof of task ownership: registry-driven conformance and
cancellation/sequence tests protect those behavioral contracts. The authoritative
syntax coverage and limitations are in the
[ArchitectureRules maintenance guide](../Tools/ArchitectureRules/README.md).

## Test isolation

Application/runtime tests inject in-memory settings and secret stores, and fakes
for clipboard, focus, key posting, capture, hotkey events, authorization, and
system events. Clipboard adapter tests use uniquely named private pasteboards,
never `NSPasteboard.general`; persistence adapter tests use disposable named
UserDefaults suites. Permission diagnostics may read current authorization
status, but tests do not request or reset grants or read/write the user's
Keychain. Provider conformance tests enumerate the application's actual registry.
`RuntimeSuspensionJourneyTests` combines the real edge classifier with fake
observers, independently mutable authorization, per-take services, and bounded
resource gates. `PreviewIsolationTests` exercises the actual offline assembly;
its optional developer screenshots/report are separate from those unit tests.
Every command that mutates the app bundle goes through the running-app guard.
