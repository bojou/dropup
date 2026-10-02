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
3. It rejects unreadable items (`.unsupportedItem`), a missing config (`.notConfigured`) or a missing password (`.missingPassword`) before touching the network.
4. It asks the `UploaderFactory` for the right `Uploader` and calls `upload(_:progress:)`. Progress callbacks become `.progress` events.
5. The outcome is `.succeeded(remotePath:)` or `.failed(UploadFailure)`. One failure never stops the rest of the queue.
6. `AppModel` folds events into a single `Status` that drives the icon and its tooltip.

A dropped folder is one job, named with a trailing `/`. `LocalTree.scan` lists everything inside it first (links and special files are skipped and counted, never followed; depth and item counts are capped), then the queue makes the folder on the server with the same numbering rule as files (`photos`, `photos-1`) and sends the files one by one, reporting one progress bar for the whole folder. If it fails or is cancelled, the files already sent stay on the server. Downloading a folder mirrors this: `RemoteTree.walk` lists the server side with `listEntriesWithLinks` (FTP asks `LIST` as well as `MLSD`, because `MLSD` on some servers reports a link to a folder as a folder), skips links and names that could reach outside the folder, and builds a new local folder that is removed again if anything fails.

## Credentials

Only the password is secret. It is stored in the Keychain as a generic password, keyed by `ServerConfig.credentialKey` (`protocol://user@host:port`). Everything else is JSON in `UserDefaults`. When the server identity changes in Settings, the old Keychain item is removed.

## Testing

- `InMemorySettingsStore` and `InMemoryCredentialStore` ship in the package (also handy for SwiftUI previews).
- Tests use a `FakeUploader` that records requests and plays back scripted progress or errors.
- `UploadQueue.waitUntilIdle()` and `finish()` let a test enqueue files, wait, and then read the complete event list deterministically.
- The FTP parsers are pure value types, so protocol edge cases (multi-line replies, split packets, malformed PASV/EPSV) are tested without a socket.

## Transfers

`DropUpCore` talks to servers through three small protocols: `ServerConnector` opens a logged-in `ServerSession`; a session can check whether a file exists, list folders and files, upload and download a file with byte progress and cancellation, and delete, rename, and make or remove folders. When an upload is cancelled after the server created the file, the queue opens a fresh session to the same server and deletes it; a cancel that lands earlier touches nothing. The upload queue keeps one session open while files are waiting and closes it when the queue runs dry. The Browse window uses `BrowseSession`, which keeps its own connection open while the window is, runs one command at a time (a listing or a change), and reconnects once if the server dropped an idle login. Changes go through `FileOperations`, which are built from the session's plain commands so FTP and SFTP behave the same: they replace a file only when the conflict policy says so and both items are files (see below), delete folders bottom-up, and never follow a symbolic link (a folder is first tried as a file, which removes a link but is refused for a real folder). Copying (`FileOperations.copy`, started from `BrowseSession.copy`) has to go through this Mac, because neither FTP nor SFTP can copy on the server: each file is downloaded to a scratch folder and uploaded under its new name (`name copy`, `name copy 2`, like Finder), folders are walked first with the same link and depth rules as folder downloads, and, unless the policy is `replace` and a file is copied into another folder, nothing already on the server is replaced. A copy is never started over on a fresh connection once it has changed the server, because that would copy the same items twice; a file whose upload stopped halfway is deleted again over a new connection. Dragging a row out of the Browse window carries two things: text that names the item (for moves inside the window) and a file promise. `DragExport` fulfils the promise only when something is dropped and asks for the file: it downloads into a folder of its own under the temporary folder using a `DownloadQueue` that is separate from the window's, and everything it fetched is removed when the window closes. Downloads go through `DownloadQueue`, which saves each file under a temporary name and moves it into place when complete, numbering names that are already taken, so a cancelled download leaves nothing behind.

**FTP** (`FTPSession`, in `DropUpCore`). The command sequence is plain Swift over a `ByteStream`, so it is unit tested against a scripted fake server. It logs in, asks for UTF-8 and binary mode, then uses EPSV (falling back to PASV) and always connects the data channel to the control connection's host, because servers behind NAT advertise addresses clients can't reach. `STOR` streams the file in 256 KB chunks and treats the `226` reply as success. Existence checks use SIZE then MDTM; folder listings use MLSD then LIST. Commands containing line breaks are refused so a file name can't inject FTP commands. The real byte stream is `NetworkByteStream` (Network.framework) in `DropUpTransport`.

**SFTP** (`DropUpTransport`). Uses [Citadel](https://github.com/orlandos-nl/Citadel), pinned to an exact version, with password authentication. Several 32 KB writes are kept in flight so uploads are fast on high-latency links. Host keys are trusted on first use: the first key a server presents is remembered per `host:port`, and a different key later fails with a message showing the new fingerprint instead of connecting.

**Name conflicts.** `ConflictPolicy.keepBoth` (default) asks the server whether the name is taken and uploads as `name-1.ext`, `name-2.ext`, … `replace` overwrites. The Browse window's moves and pastes follow the same preference, read each time so a change in Settings applies at once. For a move, `keepBoth` adds the same number; `replace` lets a file take a file's place and refuses every other pairing (a folder is never merged or replaced). For a copy, a name that is taken gets `copy` added (Finder style), except that `replace` with a file copied into another folder sends the new copy under a hidden name first. Either way the swap is `FileOperations.replaceFile`: the old file is renamed to a hidden `.name.replaced-xxxx`, the new one is renamed into place (the old one is renamed back if that fails, even when the task was cancelled), and only then is the old one deleted, so it never relies on whether a server refuses or allows a rename onto an existing name (OpenSSH refuses, pyftpdlib silently replaces). If the old file can't be deleted it is reported in `FileOperationResult.leftOver`.

**Undo and redo.** Each change the Browse window makes that can be taken back comes out of `FileOperations` as a `BrowseChange` (`madeFolder`, `renamed`, `moved` with the final paths, `copied` with the files and folders the copy created) in `FileOperationResult.change`. The window keeps two stacks of them, 50 deep, for as long as it is open. `FileOperations.undo` and `redo` (and `BrowseSession.redo`, which repeats a copy with `copy`) never overwrite: an item whose old name was taken in the meantime stays where it is and is reported, a made folder is removed only while it is empty, and undoing a copy deletes exactly the paths the copy recorded. They return the part that was actually done, which is what goes on the other stack. A replacement can't be taken back, so an operation that replaced something empties both stacks. Deleting isn't recorded at all.

**Columns view.** A toggle in the Browse toolbar (stored as `browse.showsParentColumns`) shows the folders above the one on screen as columns to its left. `BrowseModel.parentColumns` holds one column per ancestor from `/` down, each with the name of the folder that leads on. The folder on screen is listed first; the ancestors are then listed one after another from the nearest outwards through the same `BrowseSession`, and remembered until a change or a reload so moving between sibling folders doesn't list the same folders again. A round of ancestor listings that has been overtaken by a newer one is abandoned after its current listing rather than cancelled, because cancelling a listing in flight closes the shared connection. All of this is app-layer code, so it is compiled by the macOS CI job only.

## Testing the transports

- Unit tests use `FakeSession`, `FakeConnector` and a scripted `FakeFTPServer`.
- Integration tests (`DropUpIntegrationTests`) upload real files to a real FTP server (pyftpdlib) and a real SFTP server (asyncssh) started by `scripts/test-servers.py`. CI runs them on macOS, so the Network.framework stream is exercised too. They are skipped when the servers aren't running.
