# Architecture rules

From the repository root:

```sh
make architecture-test
```

This separate SwiftPM test package pins Harmonize **1.3.0** and SwiftSyntax
**601.0.1**, with resolved dependencies in `Package.resolved`. It does not add
dependencies to the application. Yams **5.4.0**, already in the resolved graph,
is a direct test dependency so configuration errors can be reported before
Harmonize's nonthrowing config loader runs. Tests are serialized because
Harmonize's shared synchronous AST caches can exhaust the dispatch pool during
parallel warm-ups.

Repository discovery walks upward from `#filePath` to an application
`Package.swift` with a `Sources` directory, independent of test-file depth and
working directory. Source selection preflights the root `.harmonize.yaml` and
its YAML schema, rejects a nearer config that would redirect Harmonize, and
requires an exact existing folder beneath `Sources` and a nonempty selection.
Fixture/test-named folders within `Sources` are still production inputs; no
implicit `Tests`/`Fixtures` name exclusion is applied there. Root excludes cover
the listed build/bundle outputs, not arbitrary generated code: all visible
Swift files under the selected production folders, including generated and
untracked files, participate. There is no git-tracked-files-only filter.

## Decisions and enforcement

| Decision | Rule |
| --- | --- |
| Core imports only Foundation/Swift and avoids selected live-I/O APIs | `coreImportsOnlyPortableModules`, `coreDoesNotReferenceSelectedLiveIOAPIs` |
| Concrete providers form their own one-way module | `providersDependOnlyOnCoreAndPortableModules`, exact six-target manifest graph, compiler import check |
| Providers avoid selected Foundation/platform I/O escapes and describe requests/use transport ports | `providersDoNotReferenceSelectedLiveIOAPIs` |
| Runtime cannot reference the two composition entry points | `runtimeDoesNotReachBackIntoComposition` |
| UI cannot reference the listed live-I/O adapters/APIs | `viewsDoNotReferenceSelectedLiveIOAdapters` |
| Preview assembly uses offline ports and supplied-snapshot permissions | `previewAssemblyDoesNotReferenceSelectedLiveIOAdapters` |
| Core, Providers, and the reviewed runtime capturer avoid selected direct storage/process APIs | `audioPipelineDoesNotReferenceSelectedStorageAPIs` |
| Every Observable class and the reviewed controllers has explicit MainActor annotation | `observableStateAndReviewedControllersAreMainActorAnnotated` |
| The named orchestrator remains an actor in the transcription scope | `dictationOrchestratorRemainsAnActor` |
| Four named transition files avoid the listed work/resource/clock identifiers | `pureTransitionsDoNotAcquireResourcesOrLaunchWork` |
| Concurrency escape hatches remain discoverable for review | Exact declaration/file unchecked-Sendable and `nonisolated(unsafe)` sets, plus detached reference-site counts by owner/file |

Scheduling and clock reads in Core's effect-owning orchestrator/session driver
are intentional. `ProcessInfo` and `DispatchQueue` are not globally banned in
Core; they remain forbidden in the four pure-transition files: `TakeLifecycle`,
`HotkeyIntent`, `InputReadiness`, and `HotkeyEdgeState`. The latter reads AppKit
event payloads and `NSEvent.ModifierFlags`, not live keyboard/permission state.
Those value spellings remain allowed; selected monitor-installation,
`CGEventSource`, and authorization spellings are guarded. Existing hotkey
classifier/chord tests remain the behavioral layer.

The Core, Provider, UI, preview, and audio API lists are targeted syntax checks,
not proofs that every possible I/O operation uses a port. Provider separation
still relies on imports and target dependencies, not a denylist of provider type
names that could collide with Core types such as `Error` or `Phase`.

## Focused I/O guards and limits

`SourcePolicy.swift` contains the selected identifier sets and exact guarded
paths; `SelectedIOPolicy.swift` contains the AST call/receiver checks and reviewed
preview exceptions. `IOTypeFacts.swift` contains their shared syntax-facts visitor
and file-local type/receiver lookup. Identifier checks cover references,
typealiases, selective imports, and dormant conditional branches. They intentionally do not resolve a
same-named declaration to a module. Literal documentation/comments do not count;
executable interpolation expressions do.

- **Provider I/O:** `providersDoNotReferenceSelectedLiveIOAPIs` scans all
  `Sources/IrisProviders`. Foundation imports remain allowed, but selected
  `URLSession`/task/configuration, `NSURLConnection`, Foundation stream, CFStream,
  and other listed live API identifiers fail. The AST file-I/O checks also catch
  recognized `Data`/`String` `contentsOf` constructors (which could load from a
  remote URL) and writes. `URL`, `URLComponents`, `URLRequest`, serialization,
  `SpeechConnection`, and `RewriteHTTPRequest` are permitted values;
  `ByteStream.connect`/`write` remain permitted port operations. This does not
  establish that every external call or unlisted network API is port-mediated.
- **Preview assembly:** all of `Sources/IrisMacOS/App/Preview`, including DEBUG
  branches and the developer capture tool, participates. The selected live
  capture/hotkey, persistence/Keychain, transport/rewrite, clipboard/focus,
  permission-query, and composition adapter spellings are forbidden. Provider
  registry/descriptors (`AppProviderAssembly.defaultRegistry`, provider
  descriptors) and offline `MockTranscriptionClient` remain allowed. The AST
  accepts `PermissionsManager` construction only with the exact argument labels
  `microphoneStatus:accessibilityGranted:` and no trailing closure: this is its
  supplied-snapshot preview/test initializer. Direct/qualified `.init`, file-local
  typealiases, and explicitly typed contextual `.init` are inspected; uncalled
  constructor/metatype references fail conservatively. A type annotation alone
  is not construction. External factories, inferred closure result types, or
  arbitrary injected permission instances are not semantically resolved.
- **Developer preview output:** four exact **file + qualified owner + API +
  reference-count** exceptions allow directory creation, JSON lifecycle-report
  output, PNG output, and the report's code-signature Boolean. They are documented
  in `previewIOExceptions`; additional live adapters in those owners still fail.
  PNG/report filesystem I/O is intentional developer tooling, not runtime audio
  storage. No whole preview file/folder is excluded. Removed, moved, or duplicated
  exception sites fail; same-count replacements still require ordinary review.
- **Audio no-direct-storage contract:** all Core and Providers files, plus the
  exact `Runtime/AVAudioEngineCapturer.swift` path, reject selected `AVAudioFile`,
  `AVAudioRecorder`, file handles/managers, output streams, UserDefaults/Keychain,
  processes, and listed C stdio/process spellings. The AST also checks obvious
  `Data`/`NSData` and `String`/`NSString` writes and `contentsOf` constructors.
  Application persistence and permission-reset diagnostics outside this scope
  are intentional. Core's settings repository can still use its injected
  persistence port; no blanket `save`/`write` identifier ban is applied.

The AST storage matcher follows explicit file-local nominal aliases, simple
bindings/parameters/properties, optional/try/await wrappers, direct constructors,
and selected value producers: JSON/property-list serialization/encoders,
`String.data(using:)`, `PCMFrame.asData()`, `TransportMessage.data`,
`RewriteHTTPRequest.body`, and the preview bitmap factories. It includes captured
write-function references on recognized receivers, while allowing transport and
unrelated receivers' `write` methods. Lexically unknown/shadowing bindings stop
lookup rather than inheriting an outer Data type. This is a small syntactic
approximation: it does not type-check overloads, resolve external/cross-file
aliases or arbitrary factory/property returns, track reassignment/data flow,
expand macros, or audit dynamic/Objective-C dispatch. Selected nominal/factory
spellings are treated conservatively, even if shadowed by a custom implementation.

These checks are not a full semantic no-storage/networking proof or a privacy
guarantee. They do not prove what data an allowed port, logger, or external helper
persists. Runtime/provider/clipboard behavior and content-sensitive logging still
require implementation review and behavioral tests.

SwiftPM's `--explicit-target-dependency-import-check error` and Swift 6 strict
compilation enforce semantic module/concurrency boundaries. The application's
strict gates also enable `MemberImportVisibility` for direct extension-member
imports; that feature is not imposed on the separate tool's third-party packages.
The source rules use
Harmonize plus SwiftSyntax visitors. They inspect modified/selective imports and
all conditional-compilation branches; comments and literal string text are
ignored. Executable interpolation expressions, key paths, selector expressions,
and macro arguments are inspected as source syntax. Generated macro expansions
are not expanded or inspected.

Unchecked conformances are inspected on classes, structs, enums, actors, and
extensions, including nested declarations, `Swift.Sendable`, additional
attributes such as `@retroactive`, and multiline spelling. Keys retain the file
and written qualified declaration name; they do not semantically resolve aliases
of `Sendable` or of an extended type. Multiple unchecked declarations collapsing
to the same owner/file key (for example local helpers in overloads) fail rather
than disappearing into the set comparison.

`nonisolated(unsafe)` declarations use the same exact file/qualified-owner
inventory. The sole reviewed exception is
`AVAudioEngineCapturer.captureFailureHandler`; its safety argument is that
`captureFailureLock` serializes installation and reads while the handler is
invoked outside the lock. There is no folder- or type-wide allowance.

Detached policy counts **reference sites**, whether immediately called,
parenthesized, or captured as a function value. It recognizes `Task`,
`Swift.Task`, `_Concurrency.Task`, generic specializations, explicit scoped/chained
typealiases in the source selection (including module qualification inferred
from the top-level source directory), `Self`-qualified aliases, and immutable
`let T = Task<...>.self` bindings. Explicit `.Type` annotations on variable
bindings and function parameters are followed too. Closures use their enclosing
named function; property initializer closures use the containing type, or `<global>` at file
scope. Overloads with the same name share an owner count. A syntactically
shadowed `Task` is conservatively reviewed too. Alias lookup is not compiler
name/type resolution: external aliases, arbitrary inferred/factory-returned
metatypes, and dynamic calls are outside its guarantees. One stored reference
can launch multiple tasks; same-count replacements within an owner also require
ordinary diff review. These counts cannot prove cancellation or joining.

Observable discovery includes new and nested `@Observable`/
`@Observation.Observable` classes automatically, alongside an exact reviewed
controller-role set. It requires an unconditional, explicit class-level
MainActor annotation, not inferred/inherited or conditionally applied isolation,
and does not audit every member's isolation. The orchestrator actor rule checks
declaration kind/count; it does not prove `DictationTake` confinement or ownership
of all effects.

Registry-driven provider conformance, controller tests, pure transition sequences,
and runtime cancellation/cleanup regressions remain the behavioral enforcement
layer. See [Architecture](../../docs/architecture.md) and
[Input recovery](../../docs/input-recovery.md).

## Manifest inspection and SwiftPM locks

The graph check still evaluates the real root `Package.swift` using
`swift package dump-package`; it does not parse Swift manifest source as text.
Each inspection uses a unique scratch directory beneath the tool package's
`.build/manifest-inspection/` and `--manifest-cache local`, then removes that
owned scratch directory. This avoids using the application's `.build` lock from
inside the architecture test runner. The child inherits stderr, so warnings and
toolchain errors appear in test output; only stdout is piped for JSON. Launch,
exit, JSON/schema, and external-product failures have explicit diagnostics.
`byName` and `target` dependencies are accepted; product dependencies are rejected
in all root-package targets. Conditions contribute declared edges, without
evaluating their platform predicates. The six-target expected graph is unchanged.

Run the gates sequentially: concurrent commands against the same SwiftPM scratch
directory can wait for its lock. A lock/toolchain stall elsewhere is not a
passing graph result; inspect inherited stderr and stop conflicting commands
before retrying.

## Maintenance

- A new module edge, listed live-I/O reference, or reviewed isolation role is an
  explicit design change. New Observable classes are discovered automatically.
  Update the relevant decision and rule rather than weakening a folder selection.
- For an unchecked conformance or `nonisolated(unsafe)` declaration, inspect
  synchronization/ownership and add its **qualified declaration and file**
  with a concrete safety argument. Removed or relocated exceptions must also
  be removed/updated; stale entries fail.
- For every detached reference, identify who cancels/joins the resulting work and
  which deadline/quarantine applies. Update the qualified owner/reference count
  only after that review and add behavioral coverage. New or removed reference
  sites change the exact set/counts even in approved files.
- Add safe and violating syntax fixtures in `PolicyFixtureTests.swift` and
  `IOPolicyFixtureTests.swift` whenever a matcher changes. Fixtures include the
  import kinds/modifiers/conditional branches above, extension/retroactive
  unchecked syntax, detached references and explicit aliases, Observable
  discovery, and the intentional scheduling/clock
  distinction, offline/live permission initializer shapes, transport-vs-Data
  writes, lexical shadowing, and exact preview output exceptions. Fixture snippets
  are parsed as syntax, not type-checked programs. Unresolved factory/alias limits
  have explicit fixtures; an unmatched expression is not thereby proved safe.
  `RepositoryFixtureTests.swift` checks discovery/config/path failures and
  dump-package JSON shapes without launching SwiftPM or creating fixture files.
  Revalidate when upgrading Harmonize, SwiftSyntax, or the Swift toolchain;
  retain exact version pins and `Package.resolved`.
- Run `make format`, `make lint`, `make format-check`, `make architecture-test`,
  `make build-strict`, and `make test-strict`. CI runs the same gates before
  release packaging.
