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

## Transfers

`DropUpCore` talks to servers through three small protocols: `ServerConnector` opens a logged-in `ServerSession`; a session can check whether a file exists, list folders and files, upload and download a file with byte progress and cancellation, and delete, rename, and make or remove folders. When an upload is cancelled after the server created the file, the queue opens a fresh session to the same server and deletes it; a cancel that lands earlier touches nothing. The upload queue keeps one session open while files are waiting and closes it when the queue runs dry. The Browse window uses `BrowseSession`, which keeps its own connection open while the window is, runs one command at a time (a listing or a change), and reconnects once if the server dropped an idle login. Changes go through `FileOperations`, which are built from the session's plain commands so FTP and SFTP behave the same: they refuse to replace anything, delete folders bottom-up, and never follow a symbolic link (a folder is first tried as a file, which removes a link but is refused for a real folder). Downloads go through `DownloadQueue`, which saves each file under a temporary name and moves it into place when complete, numbering names that are already taken, so a cancelled download leaves nothing behind.

**FTP** (`FTPSession`, in `DropUpCore`). The command sequence is plain Swift over a `ByteStream`, so it is unit tested against a scripted fake server. It logs in, asks for UTF-8 and binary mode, then uses EPSV (falling back to PASV) and always connects the data channel to the control connection's host, because servers behind NAT advertise addresses clients can't reach. `STOR` streams the file in 256 KB chunks and treats the `226` reply as success. Existence checks use SIZE then MDTM; folder listings use MLSD then LIST. Commands containing line breaks are refused so a file name can't inject FTP commands. The real byte stream is `NetworkByteStream` (Network.framework) in `DropUpTransport`.

**SFTP** (`DropUpTransport`). Uses [Citadel](https://github.com/orlandos-nl/Citadel), pinned to an exact version, with password authentication. Several 32 KB writes are kept in flight so uploads are fast on high-latency links. Host keys are trusted on first use: the first key a server presents is remembered per `host:port`, and a different key later fails with a message showing the new fingerprint instead of connecting.

**Name conflicts.** `ConflictPolicy.keepBoth` (default) asks the server whether the name is taken and uploads as `name-1.ext`, `name-2.ext`, … `replace` overwrites.

## Testing the transports

- Unit tests use `FakeSession`, `FakeConnector` and a scripted `FakeFTPServer`.
- Integration tests (`DropUpIntegrationTests`) upload real files to a real FTP server (pyftpdlib) and a real SFTP server (asyncssh) started by `scripts/test-servers.py`. CI runs them on macOS, so the Network.framework stream is exercised too. They are skipped when the servers aren't running.
