# Provider modules

Each provider owns its integration with Iris. The shared application supplies
platform I/O and renders capabilities; it does not switch on provider names.

## Layout

```text
Sources/IrisProviders/
  Meta/
    MetaProvider.swift               # identity, settings, speech + rewrite wiring
    MetaVoiceTranscribeClient.swift  # streaming session lifecycle
    MetaWireProtocol.swift           # wire events and options
  Grok/
    GrokProvider.swift
    GrokVoiceTranscribeClient.swift
    GrokWireProtocol.swift
    GrokTranscriptAccumulator.swift
  Mock/
    MockProvider.swift
    MockTranscriptionClient.swift
```

`IrisProviders` depends only on `IrisCore`; its approved imports are
Foundation/Swift and IrisCore. Core owns the provider protocols and shared session
driver; it has no dependency on any concrete client or codec. Application
composition registers providers and supplies the platform transport, explicit
probe factory, and rewrite registry.

## Add a provider

1. Add a folder under `Sources/IrisProviders`, import `IrisCore`, and implement
   `DictationProvider`. Make the provider and its required interface public so
   application composition can construct it across the target boundary. Define
   the `ProviderID` there (a static extension is optional).
2. Supply a `ConfigDescriptor`: field types, defaults, option labels, hints,
   visibility, and advanced placement. The shared forms use that metadata.
3. Supply speech connection details and a `TranscriptionClient`, mapping wire
   events into Iris's normalized events. `events()` is consumed continuously,
   beginning at startup; `endAudio()` sends the end marker and awaits completion.
   Implement `cancel()` to close the transport and unblock/join pending operations
   without finalizing. `SessionDriver` supplies this lifecycle for streaming
   providers; a `SpeechSessionCodec` value owns each provider's wire policy.
4. Optionally supply a `RewriteAdapter` and its `RewriteDescriptor`. Providers
   using the chat-completions format can configure `ChatCompletionsAdapter` with
   their own endpoint and instruction role. Other APIs supply their own request
   and response mapping.
5. Add `register(YourProvider())` to
   `Sources/IrisMacOS/App/AppProviderAssembly.swift`. `ProviderRegistry()` is empty.
6. Add a wire fixture to `Tests/IrisMacOSTests/Support/ProviderConformanceFixture.swift`.
   The suite enumerates the app's actual registry and fails for missing fixtures;
   new providers cannot silently miss cancellation coverage.

No provider-specific edits are needed in the settings views, speech transport
selection, or rewrite HTTP executor.

## Construction and credentials

The Settings credential editor supports `apiKey` only. Providers may declare no
secret fields (keyless operation) or that one `.secret` field; the assembled
provider conformance suite rejects any other secret key. Keyless descriptors
have no required secrets and composition's connection probe skips the API-key
guard. Adding OAuth or multiple editable credentials requires an explicit change
to that capability and its UI/conformance contract. Header/body placement of
an API key belongs to the provider.

Required-secret checks are descriptor-driven. `ProviderCredentials` owns cached
values, load failures, and key state; `ProviderAccessController` evaluates the
required cached fields; the environment coordinates loading/suspension for
startup readiness. These are distinct responsibilities within the existing
single-`apiKey` editor contract.

`connection(for:)` can return `nil`, but `makeClient(config:transport:)` is
non-optional. An unavailable live provider must return an explicitly failing
client such as `UnavailableTranscriptionClient`, not a mock transcript or a
different provider's traffic. Composition supplies an inert `DiscardedTransport`
when no connection is described; an offline fixture can intentionally avoid
using it. A provider without rewriting supplies no adapter and inserts raw
transcription even when the shared library has a selected prompt.

Normalization preserves unknown, case-sensitive configuration keys and changes
only provider-owned values. `displayValue(_:for:)` is presentation, not text to
persist back into the configuration. Key-issuance links in `ProviderInformation`
must be HTTPS when supplied.

`AppEnvironment` requires explicit stores, registry, permissions, runtime ports,
provider connections, clipboard, and application defaults. `DictationRuntimePorts`
requires capture/insertion/hotkey/focus/authorization/system-event ports and
service/rewrite factories. `RewriteChatClient` requires its registry and permits
an injected URLSession; `ProviderConnections` requires an injected probe. Live
assembly remains in `AppComposition`, with offline assembly in
`Sources/IrisMacOS/App/Preview` and test fixtures.

`MetaProvider.swift` and `GrokProvider.swift` are complete examples. The
[third-provider fixture](../Tests/IrisMacOSTests/ProviderExtensionTests.swift)
demonstrates registration, UI metadata, configuration normalization, a different
speech completion policy, a custom authentication header, a non-chat-completions
response format, and reasoning values absent from the built-in providers.

## Ownership and dispatch

- **PromptDefinition:** shared text, name, ID, and order only.
- **ProviderConfiguration:** one provider's persisted options plus its transient
  credentials. Rewrite model and reasoning are namespaced here.
- **RewriteDescriptor:** that provider's models, accepted reasoning tokens,
  defaults, aliases, and legacy model prefixes for migration.
- **RewriteAdapter:** constructs the provider's HTTP request and decodes its
  response. It can reuse a common wire format without sharing provider policy.
- **RewriteChatClient:** performs the HTTP request using an injected URLSession;
  its registry is required explicitly. It has no provider-specific endpoint,
  authentication, or response parsing.
- **ProviderRegistry:** registration and lookup. Mismatched identities and
  unregistered providers do not route to a fallback service.
- **ProviderAccessController:** merges descriptor defaults/plain values with
  cached secrets, normalizes them through the provider, and runs injected probes.

Reasoning values are extensible `PromptEffort` strings, validated by the
provider's descriptor. A new provider can advertise a new value without adding
a case to a central enum. The registry is injectable in the environment,
configuration decoder, speech checks, and rewrite client.

The orchestrator captures one configuration at the beginning of a take. Its
speech client and rewrite adapter use that same provider, key, model, and
reasoning snapshot, including when settings change during recording.
Its `OrchestratorConfigurationOwner` is either locally stored or a supplied source. Local
`update(settings:config:)` retains its existing next-take behavior and returns
`true`; a supplied-source owner returns `false` from that API and reads its
source at the next reservation. The macOS runtime publishes settings/configuration
together through `PressConfigurationBox`; registries stay with the injected
service/rewrite factories rather than in that box.

## Migration

Old prompts may contain `model` and `effort`. During repository loading, registered
providers' legacy-model prefixes identify compatible choices. The selected
compatible prompt wins, otherwise the first in display order. Unrecognized
custom model names belong to the formerly active provider. Explicit
provider-level choices are never overwritten. After encoding, prompt records
contain only text/identity/order; migration is idempotent.

`SettingsMigrations` uses the repository's injected registry. Plain `AppSettings`
decoding does not assemble providers or choose their rewrite settings.

## Session and observation contracts

- One `SessionDriver` owns readiness, connection, serialized writes, the live
  reader, and cleanup. Codecs are actor-confined values, including Grok's transcript
  accumulator. Meta and Grok clients no longer maintain unchecked shared state.
- `ByteStream` requires typed `messages()` and `write(TransportMessage)`. The
  convenience byte write is always binary, including bytes that look like JSON.
  Codecs decode JSON control frames from `.text` only; `.binary` frames are
  audio and are never parsed as control events.
- Transport input buffers at most 512 messages; normalized provider events buffer
  at most 256. Overflow fails explicitly instead of dropping a turn or returning
  a partial success. The service actively consumes these streams while recording.
- `TranscriptionService.finish()` returns `TranscriptionOutcome`; terminal success
  is independent of view subscriptions. Genuine audio-send failures fail that
  result. `SessionDriver.sendAudio` surfaces its retained terminal result when
  write teardown races the reader, including before the service reads the event.
- If an active service receives a cancellation-class send reply with no settled
  outcome, it owns a bounded `deliverySettlement` task rather than joining the
  reader inside `appendAudio`. An unread terminal can win; absent a settled outcome,
  the task fails explicitly as a network error. `finish()` joins settlement,
  and cleanup cancels/joins it. Caller cancellation still resolves as cancelled.
- `DictationOrchestrator.snapshots()` keeps only the latest UI snapshot, including
  its last notice/terminal revision. `terminalEvents()` is lossless. `states()` is
  a lossless diagnostic stream; it is not used to drive application views.
  Public observation/diagnostic streams also serve tests and embedding consumers.
- Session duration uses monotonic uptime from readiness ACK to each audio-write
  check, with a 55-minute default cap and guidance derived from the configured
  budget. Connection/ACK timeout is separate. Delayed-ACK and default-clock tests
  are in `SessionTimingTests`; budget/message cases remain in `SessionRecoveryTests`.
- `cancel()` must close and unblock resources. `AsyncDeadline` bounds the whole
  runtime cleanup without a structured-task-group join defeating the deadline.
  A timeout requires restart; `DictationOrchestrator.stop()` keeps returning
  `.timedOut` while resources are quarantined. Swift has not forcibly killed
  that work.
- EOF of the hotkey feed during startup cancels the reserved take without
  waiting for an ACK or finalizing a phantom recording. Providers still must
  unblock their owned operations during cancellation.
- The `finish()` stream convenience is for one-shot consumers only. Do not consume
  it and `events()` simultaneously on the same client.

## Insertion destination

The runtime captures `InsertionTargetSnapshot` through its injected focus port
before capture starts and passes it through rewriting to insertion. Iris
deliberately follows the focused app at insertion time: a changed process is
logged, not reactivated. Accessibility and secure-field checks use the current
focus. Runtime graph tests verify the captured target survives a focus change;
inserter tests verify this follow-current-focus policy.

## Boundaries

Core imports Foundation/Swift and owns scheduling, deadlines, and monotonic
timing alongside its domain/port logic. `IrisProviders` describes connections
and requests; the macOS target supplies URLSession, Keychain, audio capture,
and windows. Import allowlists, the target graph, and compiler dependency-import
checking protect this direction, not a collision-prone provider-type-name
denylist. `providersDoNotReferenceSelectedLiveIOAPIs` guards selected Foundation/
platform live-API identifiers and recognized file operations throughout
`IrisProviders`, while permitting request values and transport-port writes.
`audioPipelineDoesNotReferenceSelectedStorageAPIs` covers Core, Providers, and
the reviewed runtime capturer. These are selected syntax defenses, not complete
semantic I/O, storage, logging, or data-flow proofs; Core's scheduling and
portable diagnostic text remain intentional.
Tests register fixture providers and inject memory stores and network doubles.
Adding or testing a provider does not require reading the user's Keychain.
`make architecture-test` enforces this direction alongside registry-driven
provider conformance tests and the compiler's dependency-import check.
See the [architecture rule guarantees](../Tools/ArchitectureRules/README.md).
