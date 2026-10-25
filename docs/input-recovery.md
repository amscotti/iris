# Input handling and recovery

How Iris observes the hotkey, survives permission and session changes, and
recovers from work that stops responding.

## Why hotkey observation is passive

An active Quartz event tap sits in the system's input delivery path: if the
process that owns it stalls, keyboard input for the whole desktop stalls with
it. Iris therefore never installs one.

`GlobalHotkeyMonitor` uses
[NSEvent's global event monitor](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29).
Apple documents these events as asynchronous copies: the observer cannot
modify them or prevent delivery to the target app. A local observer handles
Iris's own key events and always returns the original event unchanged.

Callbacks copy only key code, modifier flags, and repeat state into a small
value, then classify the edge (`HotkeyEdgeState`). They do not perform capture,
permission checks, or network I/O. Physical key state is queried during
observer setup and when the shortcut is retargeted, to require release of a key
held across recovery or a shortcut change. While a press is active or other
keys are tracked, each observed event also consults a synchronous physical
key-state probe (injected into `HotkeyEdgeState`; the monitor supplies the
WindowServer lookup) to drop stale tracked keys and to reconcile a release the
system never delivered. The probe is a cheap main-thread lookup on keyboard
events only. The Accessibility permission enables both key observation and
insertion.

## Permission and session lifecycle

- Check live microphone/Accessibility authorization before a take, rather than
  trusting a value cached before a long idle period. Revocation during a take
  suspends input and produces warning guidance to re-enable the lost grant.
- Verify the running code before accessing capture hardware. If the app bundle
  was replaced while running, require a quit and relaunch instead of starting
  capture under a stale code identity.
- Stop observers and cancel the input loop before microphone/Accessibility
  requests, permission resets, or potentially interactive Keychain operations.
- Suspend on sleep and login-session deactivation. Re-check authorization on
  wake, session activation, app activation, and a 30-second readiness poll.
- Cancel the old capture/session before opening a fresh input generation.
  A held key must be released before another take can begin.
- Reject late startup, final-transcript, and rewrite results after cancellation.
  Cancelling a take prevents insertion from starting; an insertion already in
  flight is joined within its own remaining insertion budget (or the shutdown
  deadline, whichever is longer), so it never overlaps the next take.
  Finalization re-checks generation after reading `service.requiresRestart`
  and at `enhance` entry before scheduling rewrite work.

Providers implement `TranscriptionClient.cancel()` to close their transport and
unblock pending work. The service and orchestrator also use generation checks,
so even a non-cooperative provider's late callback cannot restart or insert a
take.

The hotkey loop consumes edges continuously while take-owned startup and
finalization tasks run. A release during connection startup cancels the take
without waiting for the provider ACK. Presses during finalization or cleanup
are never replayed as delayed recordings. Busy guidance is shown only when it
will not replace a retained provider failure, rewrite failure, or published
final transcript. Live
provider errors use the same bounded cleanup barrier as explicit cancellation;
the forwarder requests cleanup and returns so teardown can join it safely.
An established toggle recording stops only on an unchorded shortcut release;
the paired press/cancel sequence from Option typing leaves it recording.

An orderly EOF of the hotkey feed during startup is treated as a terminal
release: it cancels the reserved take promptly and joins bounded cleanup,
rather than waiting for an ACK and finalizing a phantom recording. EOF after
recording has started finishes/joins that existing take. Cancelling the input
task always stops it; no late startup result can open a new generation.

`DictationRuntime` owns observers, capture/insertion ports, authorization, and
the input task. `AppEnvironment` coordinates startup, presentation, and
permission suspension. Native notifications and polling belong to the injected
`SystemEventObserving` adapter; tests supply an explicit event feed.
Runtime `lifecycleGeneration` scopes startup and snapshot observation. A stop
captures its retiring observer before awaiting cleanup; a concurrent start owns
a new observer that the old stop cannot cancel when it eventually returns.

Four pure values separate decisions from these effects:

- `HotkeyEdgeState` classifies copied event values and held-key release gates.
  Observer installation and physical key-state queries remain with the monitor.
- `TakeLifecycle` accepts capture readiness and returns release decisions. A
  startup release is terminal, so even a late ACK cannot restore recording.
- `HotkeyIntent` scopes each physical press/stop/cancel command to its accepted
  take ID. The orchestrator supplies the hotkey mode from that take's reserved
  configuration. A mode change between preflight and reservation cannot change
  its stop behavior; busy/stale edges cannot act on a later take.
- `InputReadiness` orders restart, stop, sleep/session, permission, and cleanup
  blockers. Live authorization queries stay in the runtime, outside the model.

Deterministic unit sequences cover these values without clocks, tasks, or live
ports. Actor/runtime integration tests also verify the effects and bounded joins.
Runtime notices carry typed cancellation/restart reasons; presentation chooses
the message and icon independently.

`InputRuntimeState.cancellationReason` maps the actual suspension cause to typed
settings-change, system-event, microphone-denied, or Accessibility-denied reasons.
The lost-grant notices use warning severity and name the grant to re-enable.
Suspension retains its first reason in `PermissionSnapshot` through the cleanup
barrier, even if wake or another permission operation arrives before cleanup ends.
Core attaches the actual take ID to a cancellation callback at the
atomic stop ownership transfer; the callback runs within the shutdown deadline
and is joined with cleanup. A later query of `activeTakeID` is not used to infer
whether a take was cancelled. Explicit user cancellation supplies both the
expected take ID and its reason through that same transfer, so a delayed menu
action cannot cancel a newer take or overwrite a suspension's first cause.
Insertion is a separate boundary: it is joined by ordinary stop, while its own
deadline invalidates late work through the inserter generation token.
Repeated suspension events announce only the actual cancelled take; idle stops
and ordinary runtime stop/quit produce no cancellation notice. If timeout wins,
restart guidance takes precedence and a late cancellation cannot replace it.

## Bounded cleanup and restart-required

Cleanup has a two-second deadline across the previous input task, capture
startup/stop, provider startup/writes/completion, and rewriting.
`AsyncDeadline` uses a continuation race, so a cancelled, non-cooperative child
cannot hold the caller open. Insertion is bounded on the normal completion
path (a base timeout plus a per-character pacing allowance), and cleanup joins
an in-flight insertion by its own remaining budget instead of the generic
deadline, so an inserter stuck on a stalled Accessibility or pasteboard call
still cannot leave a take open while a healthy slow insertion is not
misreported as wedged.

Anything that misses its deadline stays quarantined, and the sticky
restart-required state survives permission, activation, and wake changes. A
completed transcript already retained by the service is inserted before that
quarantine; a failed or cancelled outcome is not promoted to success. Runtime
suspension uses the current remaining insertion/cleanup budget (with a 45-second
minimum headroom) instead of a fixed shorter ceiling. The menu bar explains that
Iris must be restarted. Keystrokes a wedged inserter already posted cannot be
recalled, but the insertion generation prevents late posts after its deadline.
A soft take deadline at 54:30 uses this same normal finalization path before the
driver's 55-minute hard session limit.
Repeated `stop()` calls on a quarantined orchestrator still return `.timedOut`;
idle state does not mean its unfinished resources are reusable.

Genuine audio-delivery and server errors stop capture immediately, with one error
per take and one capture-stop operation. Capture failures carry the take ID
assigned after the previous capture drain, so a delayed old-device callback
cannot cancel a newer take. The native-input watchdog reads a lock-protected
monotonic heartbeat from the tap itself, not conversion dequeue time or pacer
output. Resources and callbacks belong to `DictationTake`; a late write from an
old take cannot change the next take's failure state. A connection that completes
after cancellation is closed again before cleanup reports success. A pump that overran its deadline after the service had already
published a final still inserts that final, then closes the service inside the
shutdown budget; only a cleanup that cannot join latches restart-required.

An in-flight send's teardown error cannot replace a terminal result retained by
`SessionDriver`. At the service boundary, `CancellationError` and
`URLError.cancelled` replies from an otherwise active send get an owned
`deliverySettlement` task. The send reply returns without joining the reader,
so an unread queued terminal can still arrive. Settlement is bounded by the
service shutdown budget (two seconds by default): an unsettled reader becomes an
explicit network failure instead of a hung recording. `finish()` joins that
task; cancellation and cleanup cancel/join it with the other take resources.

## Clipboard transactions and notice meanings

Clipboard reads have size/time budgets, and live mutations use a bounded access
lease. `preparePaste` and `restoreIfUnchanged` keep revision checks, writes, and
any safe rollback/recovery within that lease. An acquisition timeout does not
authorize a later write that could overwrite a newer user copy.

| Notice | Intentional meaning |
| --- | --- |
| `previousClipboardUnavailable` | The previous contents could not be kept safely: the snapshot may have exceeded size/time limits, become stale while reading, or otherwise been unavailable. After a successful transcript write and paste post, the transcript remains available. "Couldn't be kept" intentionally covers more than read failure. |
| `concealedClipboardNotRestored` | A password manager's concealed prior contents are deliberately not restored. The transcript remains on the clipboard, and the privacy decision is reported. |
| `clipboardChangedBeforePaste` | A saved snapshot's revision changed before writing the transcript. Nothing is inserted, and the newer user copy is preserved. |
| `restoreAccessUnavailable` | Restore access could not be acquired. It stays in the problem category because the current clipboard contents cannot be verified; it must not promise that the transcript is still present. |
| `clipboardRevisionUnavailable` | A negative `.written` revision cannot authorize a paste. This defends alternative `ClipboardPort` implementations. Live `preparePaste` reads its AppKit revision while holding the lease; an access timeout returns `.unavailable` instead. |
| `pastePostFailed` | The transcript write succeeded but posting Cmd-V failed. Keep the full transcript for manual pasting and do not restore the previous clipboard over it. |
| `partialClipboard` | A mid-text keystroke fallback copied only the untyped remainder; the already-typed prefix is not on the clipboard. |

**Copy Last Dictation** retains the latest non-empty final in memory and writes
it only when the user explicitly invokes the action. A failed recovery copy
surfaces a notice; insertion failures do not silently overwrite the clipboard.

An empty previous clipboard also leaves the transcript available. A clipboard
change during the restore window is left alone. A failed paste post keeps the
transcript for manual pasting; it does not restore the old clipboard over it.

## Rebuilding during development

Replacing a running app bundle invalidates its code signature, and macOS then
treats it as a different app for privacy approvals. Live bundle replacement is
unsupported:

1. Quit Iris.
2. Run `make app`, `make run`, or `make dist`.
3. Relaunch the built app and grant any permissions macOS requests from Settings.

`Scripts/assert_app_stopped.swift` checks the target bundle using running-app
metadata. `build_app.sh` checks before building, constructs and signs a staging
bundle, and checks again immediately before installation; a running copy makes
the build refuse replacement. It never terminates the app or resets privacy
settings. `make clean` runs the same guard before deleting any build outputs.

`swift build`, `swift test`, and the isolated settings preview never replace a
running app bundle. Ad-hoc builds can still need new privacy approvals after a
proper relaunch; stable signing is a distribution concern.

## Testing approach

Regression tests use fake event backends, in-memory credentials, and controlled
suspension points. They cover unchanged local event delivery, stale callback
rejection, held-key recovery, nested permission operations, sleep/wake
generation changes, cancelled startup, non-cooperative shutdown, wedged
insertion, and late transcription/rewrite results. They never install real
global monitors or request permissions.

`RuntimeSuspensionJourneyTests`, with its
[support fixture](../Tests/IrisMacOSTests/Support/RuntimeSuspensionJourneySupport.swift),
asserts revoked-grant recovery, cancel/complete/cancel sequences, wake and
permission overlap during cleanup, timeout quarantine after late resource
release, ordinary stop, and concurrent stop/start snapshot delivery. Its fake
runtime authorization can change independently of the UI permission snapshot.
`QueuedTerminalDeliveryTests` and `CancelledAudioDeliveryTests` control the
reader/send ordering; `FinalizationOwnershipTests` covers retired rewrite entry
and both configuration owners. Clipboard failure tests call the real inserter
with fake ports; adapter restoration tests use real private pasteboards.

`make architecture-test` additionally checks explicit MainActor annotations,
the orchestrator's actor declaration, selected effect identifiers in the four
transition files (`TakeLifecycle`, `HotkeyIntent`, `InputReadiness`,
`HotkeyEdgeState`), and reviewed detached reference-site counts by owner/file.
These syntax checks complement the runtime tests; they cannot prove a cleanup
join or every member's isolation. See the
[ArchitectureRules guarantee and maintenance guide](../Tools/ArchitectureRules/README.md).
