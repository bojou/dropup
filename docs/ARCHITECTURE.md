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

A dropped folder is one job, named with a trailing `/`. `LocalTree.scan` lists everything inside it (links and special files are skipped and counted, never followed; depth and item counts are capped). The scan starts when the folder is dropped, on its own task and not on the queue actor, so a folder with hundreds of thousands of files never holds up a cancel or the files behind it; the row appears at once with size 0 and the size follows as a `progress` event. A cancel stops the scan too. The queue makes the folder on the server with the same numbering rule as files (`photos`, `photos-1`) and sends the files one by one, making each subfolder just before the first file that goes into it (so sending starts at once and a cancel is looked for before every command), and the folders with no files last. It reports one progress bar for the whole folder. If it fails or is cancelled, the files already sent stay on the server. Downloading a folder mirrors this: `RemoteTree.walk` lists the server side with `listEntriesWithLinks` (FTP asks `LIST` as well as `MLSD`, because `MLSD` on some servers reports a link to a folder as a folder), skips links and names that could reach outside the folder, and builds a new local folder that is removed again if anything fails.

## Resuming uploads

Only the user's own cancel deletes the half-sent file; every other way an upload stops (a lost connection that doesn't come back, quitting, a crash, a shutdown) leaves it on the server, and the row stays in Recent so it can be resumed.

**What is remembered.** While an upload runs the queue reports `.resumable(id, ResumePoint)`: right after `.queued` (the source, the folder it goes to), once the name on the server is settled, once the server holds the file (`created`), and for a folder after every file (`finishedFiles`, `currentFile`, a `fingerprint` of the names and sizes in it). A point is a plain `Codable` value: source path, the server's `ServerConfig` (the password stays in the Keychain), the path it went to, the source's size and modified date. It is stored with the row (`StoredUpload.resume`) by `AppModel`, which saves the Recent list half a second after the last change, so a big folder is not written once per file, and again as DropUp quits. No byte count is stored: the server is the truth about how much arrived.

**Resuming.** `UploadQueue.resume(id, from:)` queues the upload again under the same id, so the row is replaced in place. For a file the queue checks that the source is unchanged (size and modified date to the millisecond), asks the server for the partial's size (`ServerSession.fileSize`: FTP `SIZE`, SFTP attributes) and sends from there: FTP `REST n` before `STOR`, SFTP a write at that offset (starting up to 512 KB early, because in-flight writes can leave a hole just before the size the server reports). It is always the same destination file, whatever the same-name setting says, and only a file that is the upload's own (`created`) is ever appended to. If the source changed, the partial is gone, the server can't say its size or won't `REST`, or the file afterwards has the wrong size, the file is sent again from the start over the same name and the row gets a `.restarted(reason)` notice. A folder skips `finishedFiles` files (after checking the fingerprint, and looking at the sizes on the server for the few files that may have finished after the last save) and carries on with `currentFile`, without making the folders again.

**Retries.** A lost connection (`connectionFailed`, `timedOut`, a 421, 425 or 426 reply) is tried again by the queue itself while DropUp runs: `ReconnectPolicy.standard` waits 5, 15, 30 and 60 seconds, each try resuming from the server's partial, and gives up two minutes after the last sign of life, counted on `systemUptime` so a sleeping Mac gets its time back. There is one timer per upload and nothing polls. A transfer on a connection that went quiet without an error is caught by a watchdog that sleeps until the moment a stall could matter: after 15 seconds without bytes the row says *Waiting for connection…*, after the window the transfer is cancelled and, if it doesn't let go within a grace period, its session is closed under it. An upload that never got a connection fails at once as before, because that is most likely a mistake in the settings. When the tries are used up the upload is `.failed(.connectionLost)`: the usual cross, sound and notification, and a Resume button. After a crash or a quit nothing is retried by itself.

**Recent.** Rows that have a partial on the server (`Item.isResumable`) are exempt from Clear automatically, the count and the Clear button. They are stored apart from the finished rows (`storedInterrupted`), come back after a launch as `.interrupted` (no sound, no red dot) and are kept only while the list is on (`recentLimit > 0`). Removing one is a cancel: `UploadQueue.discard(point)` deletes the half-sent file (for a folder only the file it was in the middle of) over a connection of its own, and if that fails the row stays with the reason and a *Remove from List Anyway* choice, so a partial is never left behind unnoticed.

**Pausing.** `UploadQueue.pause(id)` is a stop like cancel, with the opposite outcome: a waiting upload leaves the line, a running one is cancelled like a cancel (`stopActive(id, .pause)`, with the same force-close of a stuck session), and the queue reports `.resumable` with where it got to and then `.paused`. Nothing is deleted from the server, no failure cue is made and no retry timer runs. A cancel that arrives after a pause still wins (`stops[id]` keeps the stronger one), and an upload that finished before the pause was noticed is simply `.succeeded`. A paused row is `.paused` in `UploadActivity`: finished, out of the batch (so the ring, the count and the sound go on without it), and exempt in the same way as an interrupted one. Resume is `resume(id, from:)` with the stored point, so a paused upload goes through exactly the path of an interrupted one; it waits in the line like any other. `AppModel.canPause` is `recentLimit > 0`: with the list off a paused row would be removed at once and its half-sent file left with nothing to resume from, so the button is greyed instead.

## Global shortcuts

Three actions (Quick Upload, Upload from Clipboard, Upload Latest Screenshot) can each be given a key that works system wide. The deciding is in `DropUpCore/Shortcuts` and tested there; the App target only asks the Mac and hands over the answer.

**Settings.** `Preferences.shortcuts` is a `ShortcutSettings`: a switch and a `KeyCombo` (virtual key code, `KeyModifiers`, the label the recording keyboard gave the key) per `ShortcutAction`, stored by action name so an older or newer file still loads. Everything starts off, with ⌃⌥⌘ and U, V or S as the key. `ShortcutRules.check` is what the recorder asks about a key: at least two modifiers with ⌃ or ⌘ among them (macOS 15 stopped delivering global keys made of ⌥ or ⌥⇧ alone, so they would register and never fire), no key another action holds, and a warning, not a refusal, for the keys macOS itself uses.

**Keys.** `ShortcutCoordinator` keeps a `HotKeyRegistrar` in step with the settings by diffing: an action that is on has its key, one that is off has none, a changed key moves. The App's `CarbonHotKeys` registers with Carbon's `RegisterEventHotKey` (no Accessibility permission, no dependency; the system calls in when a key is pressed, so nothing runs in the background). A combination that is taken (`eventHotKeyExistsErr`) is reported as `takenByAnotherApp` and shown on the row. While the recorder listens the coordinator is paused, so pressing a registered key records it instead of running it. The recorder watches key events with a local monitor and swallows them, so a combination such as ⌘Q is recorded and doesn't quit.

**What a key press does.** `ShortcutController` (App) reads the Mac and calls a planner, which returns a `ShortcutOutcome`: upload these URLs, stage this data as a file and upload that, or show this notice. With no server set up the notice replaces the upload. Notices go through `Notifier`, with the lower sound if sounds are on.
- `QuickUploadPlanner` needs Finder in front (so an old selection is never sent by mistake) and reads the selection with an AppleScript run by `NSAppleScript` (4 second timeout). Error −1743 is the refused Automation permission. The app carries `NSAppleEventsUsageDescription` and, for the hardened runtime, the `com.apple.security.automation.apple-events` entitlement (`project.yml` generates the file; the release workflow signs with it and checks it is there).
- `ClipboardPlanner` takes file URLs first, then an image (PNG, or TIFF converted), then non-blank text; the image and text are read only when asked for. The name is `Clipboard yyyy-MM-dd HH.mm.ss.<ext>` in the local clock (dots, because a Mac file name can't hold a colon).
- `ScreenshotPicker` takes the newest image created in the last 10 minutes from the folder in the `com.apple.screencapture` defaults (the Desktop by default). A file is a screenshot if macOS marked it (`kMDItemIsScreenCapture` extended attribute), which also covers other languages' names; where there is no mark, a name starting with "Screenshot" counts. Only files in the window have their mark read.

**Staged clipboard files.** `ClipboardStaging` writes each into a folder of its own under Caches, so two with one name never meet. `AppModel.sweepStaging` deletes every staged file that no row needs: a file is needed while its row is waiting, uploading, failed, interrupted or paused (it can still run or be sent again), and from the moment it is handed to the queue until its row has appeared. It runs whenever the list changes (no timer), and once at launch against the saved rows, which clears what a quit or crash left behind.

**Permissions.** They are asked for when the switch goes on, with a short explanation first, and not at the first key press. Quick Upload uses `AEDeterminePermissionToAutomateTarget` (away from the main thread when it asks); a refusal shows on the row, with a link to Privacy & Security → Automation, and is looked up again when the app comes back to the front. The screenshot folder is listed once after switching on when it is the Desktop, Documents or Downloads, which brings up macOS's Files & Folders prompt there.

## Credentials

Only the password is secret. It is stored in the Keychain as a generic password, keyed by `ServerConfig.credentialKey` (`protocol://user@host:port`). Everything else is JSON in `UserDefaults`. When the server identity changes in Settings, the old Keychain item is removed.

## Testing

- `InMemorySettingsStore` and `InMemoryCredentialStore` ship in the package (also handy for SwiftUI previews).
- Tests use a `FakeUploader` that records requests and plays back scripted progress or errors.
- `UploadQueue.waitUntilIdle()` and `finish()` let a test enqueue files, wait, and then read the complete event list deterministically.
- Resuming has its own unit tests (`ResumeTests`, `InterruptedUploadTests`) and real-server tests (`ResumeIntegrationTests`), which cut a real upload off part of the way and then carry it on, so the server really holds a half-sent file; pausing is tested there too, with a test connection that holds a real transfer still once the server has some bytes, so the pause is not a race with the end of the upload.
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
