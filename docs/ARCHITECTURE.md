# Architecture

## Goals

1. Feel instant: drop a file, see progress, done.
2. Be easy to test: every piece of logic can be exercised by `swift test` with no UI, no network and no Keychain.

## Two layers

The app layer below is the plan; it gets built after the UI mockup is agreed. Only `DropUpCore` exists today.

```
┌──────────────────────── App (DropUp target) ────────────────────────┐
│ StatusItemController  NSStatusItem, drop target, progress icon      │
│ OnboardingView / SettingsView / ServerFormView   SwiftUI            │
│ AppModel   @Observable UI state, turns UploadEvents into a Status   │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ uses only protocols + UploadQueue
┌───────────────────────────────▼──────── DropUpCore (Swift package) ─┐
│ ServerConfig, RemotePath        model + validation                  │
│ SettingsStore      protocol  → UserDefaultsSettingsStore            │
│ CredentialStore    protocol  → KeychainCredentialStore              │
│ Uploader           protocol  → FTPUploader, SFTPUploader            │
│ UploaderFactory    protocol  → DefaultUploaderFactory               │
│ UploadQueue        actor, serial uploads, AsyncStream<UploadEvent>  │
│ FTPReplyParser, FTPPassiveParser   pure FTP protocol parsing        │
└─────────────────────────────────────────────────────────────────────┘
```

The app target holds no logic worth testing. If something needs a test, it moves into `DropUpCore`.

## Why SwiftUI with a little AppKit

SwiftUI handles every window (onboarding, Settings) and keeps view code small. AppKit is used for exactly one thing: the menubar icon. SwiftUI's `MenuBarExtra` cannot accept files dragged onto the icon, so `StatusItemController` creates an `NSStatusItem`, registers the status button's window for file-URL drags, and forwards dropped URLs to `AppModel.upload(_:)`.

Testability does not come from the UI framework choice. It comes from keeping the UI thin and putting logic behind protocols in the package.

## Upload flow

1. Files are dropped on the icon. `AppModel.upload` opens onboarding if no valid config exists, otherwise calls `UploadQueue.enqueue`.
2. The queue emits `.queued`, then processes files one at a time. For each it reads the current `ServerConfig` and the password from the `CredentialStore` at that moment, so Settings changes apply to the next file without a restart.
3. It rejects folders and unreadable items (`.unsupportedItem`), a missing config (`.notConfigured`) or a missing password (`.missingPassword`) before touching the network.
4. It asks the `UploaderFactory` for the right `Uploader` and calls `upload(_:progress:)`. Progress callbacks become `.progress` events.
5. The outcome is `.succeeded(remotePath:)` or `.failed(UploadFailure)`. One failure never stops the rest of the queue.
6. `AppModel` folds events into a single `Status` that drives the icon and its tooltip.

## Credentials

Only the password is secret. It is stored in the Keychain as a generic password, keyed by `ServerConfig.credentialKey` (`protocol://user@host:port`). Everything else is JSON in `UserDefaults`. When the server identity changes in Settings, the old Keychain item is removed.

## Testing

- `InMemorySettingsStore` and `InMemoryCredentialStore` ship in the package (also handy for SwiftUI previews).
- Tests use a `FakeUploader` that records requests and plays back scripted progress or errors.
- `UploadQueue.waitUntilIdle()` and `finish()` let a test enqueue files, wait, and then read the complete event list deterministically.
- The FTP parsers are pure value types, so protocol edge cases (multi-line replies, split packets, malformed PASV/EPSV) are tested without a socket.

## Next: the real transfers

**FTP.** Implement `FTPUploader` on Network.framework (`NWConnection`): connect, read the `220` greeting via `FTPReplyParser`, `USER`/`PASS`, `TYPE I`, `EPSV` with `PASV` fallback, open the data connection, `STOR <remotePath>`, stream the file in chunks while calling `progress`, close the data connection, expect `226`. Put the control-channel I/O behind a small transport protocol so the command sequence can be tested against a scripted fake server.

**SFTP.** Use [Citadel](https://github.com/orlandos-nl/Citadel) (pure Swift, on SwiftNIO SSH) for password auth and SFTP writes with progress. Shelling out to `/usr/bin/sftp` is not viable: it cannot take a password non-interactively and gives no byte-level progress. Host-key verification needs a decision: trust on first use with the fingerprint shown during onboarding is the likely default.

**Integration tests.** A CI job with Docker-based FTP and SFTP servers can exercise both uploaders end to end. These stay separate from the fast unit tests.
