# Distribution, diagnostics and foreground alerts

Status: implemented and locally validated, 2026-10-25. Physical acceptance and
private signing/provisioning remain operator steps; see `VALIDACAO.md`.

## Journeys and boundaries

- The developer builds an installable release with a private signing key. CI builds
  explicitly unsigned artifacts without credentials; neither flow publishes to stores.
- The operator opens a machine's diagnostics, runs bounded read-only checks, sees
  a safe explanation and copies a report. No prompts, pairing codes or permissions
  are submitted. File Browser checks only query authorized roots; no paths enter reports.
- The user sees an in-app alert when the open chat observes new pending approvals
  or transitions from running to idle. Idle does not prove successful completion.
  Initial snapshots do not imply completion; repeated snapshots do not repeat alerts.

## Decisions

- Android release signing never falls back to the debug key. Signing inputs come
  from environment references supplied by the developer's secret manager; no key
  is generated, retrieved or committed. Unsigned verification remains available.
- Diagnostics belong to a separate read-only screen, accessible from machine
  configuration. They reuse each backend's production client and trust checks.
  Reports use fixed labels, validated version strings and numeric status codes:
  not arbitrary exceptions, response bodies, hostnames, machine names, paths,
  usernames, passwords, session titles or IDs. TLS failures are classified through
  typed transport errors, not guessed from arbitrary server text.
- Foreground alerts reuse the chat's existing polling, with no additional worker,
  background polling, OS notification permissions or external service. The user
  explicitly chose this scope instead of push infrastructure. Background/closed-app
  notification delivery is not provided. No cross-session monitoring is implied.
- Package updates that could change encrypted-storage persistence are deferred
  until upgrade validation on devices with existing data. Do not trade a warning
  for an untested credential migration.

## Verification and follow-up

### Dependency maintenance

`mobile_scanner` moves from 7.2.0 to 7.4.2: upstream 7.4.1 fixed the AGP 9/KGP
warning and release keep rules, and 7.4.2 fixes camera orientation listeners.
Source: <https://github.com/juliansteenbakker/mobile_scanner/releases>, checked
2026-10-25. `flutter_secure_storage` stays on 9.2.4 pending real-device migration
acceptance; its Swift Package Manager warning is not resolved by this change.
`package_info_plus` 9.0.1 supplies installed build metadata; 10.2.2 was checked
but conflicts with the existing secure-storage Windows dependency (`win32` major).
No dependency override is used to hide that incompatibility.
The compatible `package_info_plus` 9.x still emits a KGP compatibility warning;
this remains a known follow-up alongside secure-storage migration, not a resolved
warning. A native metadata bridge was considered, but would add custom platform
maintenance to replace a standard plugin solely for a non-fatal upstream warning.

### CI action references

Release tags and their commit SHAs were resolved against the canonical GitHub
repositories on 2026-10-25. Public repository advisory endpoints returned no
published advisories; this is not a comprehensive security audit. GitHub-hosted
`ubuntu-latest`/`macos-latest` runners are used, not an older self-hosted runtime.
Application Java 17 and Node 22 are unchanged.

| Action | Previous ref | Selected stable release (SHA pinned in workflow) | Source |
| --- | --- | --- | --- |
| actions/checkout | v4 | v7.0.1 | <https://github.com/actions/checkout/releases/tag/v7.0.1> |
| actions/setup-java | v4 | v6.1.0 | <https://github.com/actions/setup-java/releases/tag/v6.1.0> |
| actions/setup-node | v7.0.0 SHA | v7.1.0 | <https://github.com/actions/setup-node/releases/tag/v7.1.0> |
| actions/upload-artifact | v4 | v7.0.2 | <https://github.com/actions/upload-artifact/releases/tag/v7.0.2> |
| subosito/flutter-action | v2 | v2.23.0 | <https://github.com/subosito/flutter-action/releases/tag/v2.23.0> |

Unsigned Android artifacts and a ZIP preserving the iOS app structure are
verification outputs, not store submissions. CI contains no release keystore,
Apple provisioning, upload tokens or automatic deployment. Local signed commands
require the operator's existing private signing configuration.

### Physical acceptance (not automated)

1. Keep the previous installation and private recovery material safe. Check the
   signing identity before attempting an upgrade; changing keys is not a data migration.
2. On Android and iPhone, reconnect through Tailscale; test valid/invalid login,
   inaccessible server and trusted HTTPS without disabling certificate checks.
3. Reopen after termination/reboot; verify machines, drafts and biometric unlock.
4. Test real camera QR capture, microphone dictation and the native file picker.
   Review before sending; use a test account/project for any paid model operation.
5. Verify diagnostics contain no machine or conversation data when copied.
6. Observe a chat run and a new permission/question; then background the app and
   confirm no promise of closed-app notifications is made.

Run the documented Makefile quality gate, native lint, release/unsigned builds,
and isolated simulator workflows. Physical acceptance remains required for
Keystore/Keychain, upgrades, QR, microphone, biometric unlock and tailnet TLS.
No tool-generated simulation is evidence of a physical-device pass.
Run Flutter test, drive and build commands sequentially: they share generated
native plugin registrants. Concurrent unit tests can regenerate debug-only plugin
entries while Gradle compiles release sources. `make precommit` is sequenced.
The real password/recovery KDF regression has a bounded two-minute timeout for
instrumented coverage runs; its derivation strength and assertions are unchanged.

Revisit foreground-only delivery when closed-app notifications are requested:
that requires a host observer, APNs/FCM credentials, delivery guarantees and
an explicit decision about relay hosting and private metadata.
