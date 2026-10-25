# Security policy

## Supported versions

Security fixes target the latest GitHub release and the `main` branch. Older
pre-release builds are not maintained separately; please update before
reporting an issue that may already be fixed.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Use **Report a
vulnerability** under this repository's GitHub **Security** tab so the report
stays private until a fix is available.

Include:

- the Iris version and macOS version;
- the affected provider, without any API key or session ID;
- clear reproduction steps and the expected impact;
- relevant log excerpts with transcripts, clipboard text, account details,
  and secrets removed.

Please never send an API key, a real transcript, microphone audio, or
clipboard contents in a report. Rotate any credential that may have been
exposed before submitting the report.

## Scope

Reports involving Keychain storage, settings persistence, clipboard restore,
text insertion into another app, provider traffic, update/signing integrity,
or permission handling are especially valuable. Issues that require a user
to paste an API key into a third-party service, or vulnerabilities in Meta
or xAI services themselves, should be reported to that provider.
