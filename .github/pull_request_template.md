## Summary

Describe the user-visible change and why it is needed.

## Architecture and privacy

- [ ] The change keeps the `IrisMacOS → IrisProviders → IrisCore` boundary (or explains an intentional architecture-rule update below).
- [ ] No API keys, transcripts, audio, clipboard contents, or unredacted provider errors were added to code, tests, logs, or screenshots.
- [ ] New behavior has focused tests using fakes or in-memory stores rather than live accounts or system state.

## Verification

- [ ] `make format-check`
- [ ] `make lint`
- [ ] `make architecture-test`
- [ ] `make build-strict`
- [ ] `make test-strict`
- [ ] `make dist` (when packaging, signing, entitlements, or release workflow changed)

## UI changes

If applicable, add screenshots or a recording and note keyboard, VoiceOver,
Reduce Motion / Transparency, and increased-contrast checks.
