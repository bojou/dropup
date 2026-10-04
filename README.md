# DropUp

A tiny macOS menubar app. Drop a file on the DropUp icon and it uploads straight to your FTP or SFTP server.

It is a pared-down take on the upload action in Dropzone 4: one destination, no shelf, no extras.

## Install

1. Download `DropUp-<version>.dmg` from the [Releases page](../../releases).
2. Open the DMG and drag **DropUp** into **Applications**. You can eject the disk image and delete the download yourself afterwards.
3. DropUp lives in the menubar and walks you through setting up your server the first time. While its setup or Settings window is open it also shows in the Dock; closing the window removes the Dock icon and DropUp stays in the menubar.

Releases are signed with a Developer ID and notarized by Apple, so macOS opens them without a warning. A release marked
*pre-release* was built without the signing secrets: right-click DropUp and choose **Open** the first time. How releases
are built, and the secrets the maintainer adds to make them notarized, is in [docs/RELEASING.md](docs/RELEASING.md).

To have DropUp start when you log in, turn on **Open at login** in Settings → General.

DropUp updates itself: once a day it looks for a newer release. When it finds one, the menubar icon gets a small purple dot and the popover shows an **Update available** row. Nothing pops up by itself; **Update…** opens a window with what changed and the choice to install, skip or wait. **Settings → General → Updates** has **Check Now**, which opens that window straight away, and a switch to stop the daily check. An update waits for running uploads and downloads to finish before DropUp restarts. Setting this up for releases is described in [docs/RELEASING.md](docs/RELEASING.md).

## Using it

- Drag a file or a whole folder toward the menubar icon. A drop panel opens under it; drop it there (or straight on the icon). A folder goes up with everything inside it and shows as one item in the list. Links and `.DS_Store` files inside it are left out.
- The icon shows progress while uploading and a brief check when it is done. If something in the latest uploads failed, it shows a cross with a red dot until you open the popover or start the next upload, which is judged on its own.
- Click the icon for the list of uploads: progress, speed, cancel, retry and recent uploads. Hover a finished upload (or right-click it) to remove just that one, or use Clear for all of them. The pause button on a waiting or running upload stops it and keeps what was sent; the row shows *Paused* and the pause icon becomes a play icon (Resume) in the same place, the next upload in line starts, and a paused upload survives quitting DropUp (pausing needs recent uploads to be on, because the paused row lives in that list). A folder pauses as a whole. Cancelling a running or paused upload (its cross, or Cancel All for the running ones) is the one thing that deletes the half-sent file from the server. Anything else that stops an upload leaves it there so the upload can carry on. If the connection drops, DropUp waits and tries again by itself for about two minutes (the row says *Waiting for connection…*) and goes on from what the server already has. When that runs out the upload shows as failed, with the usual cross and sound, and a **Resume** button. If DropUp quits or crashes mid-upload, the row comes back after the next launch as *Interrupted*, with **Resume**. Resume goes on with the same file under the same name (never a numbered copy); if the file on your Mac changed, the server lost its part or it can't carry on, that file starts over and the row says why. A folder resumes too and skips the files already sent. Interrupted and paused uploads stay in the list until you resume or remove them (their cross cancels the upload and deletes the half-sent file, and if the server can't be reached the row stays and says so); Clear, the count and the clearing time leave them alone, and with recent uploads set to none nothing is kept to resume. In Settings > General you choose how many recent uploads are kept (or none, which includes failed ones: the menubar cross, the sound and the notification still tell you), when they clear themselves (when DropUp quits, never, after an hour, a day, a week or a custom time) and whether file names are hidden. Hidden names also cover folder names and paths in error messages. Settings that depend on another setting stay visible and are greyed out while that setting is off.
- To send files to another folder on the same server, click the icon and choose **Change Folder** at the bottom of the popover. It opens the same view as Browse (back and forward, the path bar, list or columns), but nothing in it can be changed, and files are shown faintly so you can see what is in a folder. Open the folder you want and press **Use This Folder**; it applies from the next upload.
- To look around the whole server, click the icon and choose **Browse**. The window lists every folder and file with size and date. Use the back and forward arrows (or the path bar) to move around like in Finder, and click a column heading to sort. Drop files onto it, or onto one of its folders, to upload them. Select one or more files or folders and right-click (or two-finger tap) for **Download** and **Download To…**; double-clicking a file downloads it too, and dragging a file or folder out of the window onto the Finder or the desktop downloads it there (only the item you drag, not a whole selection), and a folder arrives as a folder (links inside it are left out; if the download fails or is cancelled, the half-made folder is removed).
- In the same window you can make a **New Folder**, **Rename** (Return), **Delete** (with a confirmation; folders go with everything inside them), and move things: drag them onto a folder or onto a step of the path bar, or choose **Cut**, open the destination and **Paste**, or use **Move To…**. **Copy** (⌘C) then **Paste** (⌘V) copies, and **Duplicate** (⌘D) makes “name copy” next to the original. A copy goes down to your Mac and back up, because FTP and SFTP can't copy on the server, so big files take as long as a download plus an upload; links are not copied.
- The two buttons at the right of the toolbar (or ⌘2 and ⌘3) switch Browse between a plain **list** and **columns**: the folders above the one you are in are shown beside it, with the one you came through highlighted, like Finder's column view. Click a folder in any column to open it, or drag items onto one to move them there.
- **Undo** (⌘Z) and **Redo** (⇧⌘Z) take back and repeat new folders, renames, moves and copies, as long as the window is open. Undoing a copy removes only what the copy made, and a folder that has since got files of its own is left in place. Deleting can't be undone, because a server has no trash.
- A move or paste onto a name that is already taken follows the **When a file already exists** setting (Settings > General), the one that decides what an upload does: with **Keep both**, a number is added (`a-1.txt`); with **Replace**, a file takes the place of a file with the same name (the old file is set aside under a hidden name until the new one is in place, so a failure never leaves the name empty). A replaced file can't be brought back, so DropUp says so and starts the Undo list afresh. A folder is never merged into or replaced by another item, and Rename never takes a name that is already used. Copying a file into its own folder always makes “name copy”.
- Server, credentials and upload folder are set in onboarding and editable in Settings → Connection. Passwords live in the macOS Keychain. An optional display name there (like "My website") is shown in the popover in place of the host.

## Status

Working end to end, still young. The core (FTP and SFTP transfers, upload queue, settings) is tested against real servers
on Linux and macOS CI. The app itself (menubar icon, drop panel, popover, onboarding, Settings) is compiled by CI on every
pull request but has had little hands-on use on a real Mac yet, so expect rough edges. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it is put together.

## v1 scope

- Plain FTP and SFTP
- Upload progress in the menubar icon
- Onboarding to set server, credentials and upload folder, editable later in Settings
- Passwords stored in the macOS Keychain

Out of scope for v1: copying the uploaded file's URL, FTPS, multiple destinations, key-based SFTP auth.

## Requirements

- macOS 14 or later
- To build from source: Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen && xcodegen generate`, then open `DropUp.xcodeproj`)

## Tests

The unit tests need no server:

```sh
swift test --package-path DropUpCore --filter DropUpCoreTests
```

The integration tests upload to real FTP and SFTP servers. They are skipped unless the servers are running:

```sh
pip install pyftpdlib asyncssh
python3 scripts/test-servers.py > /tmp/dropup-servers.log &
sleep 2 && source <(grep '^export' /tmp/dropup-servers.log)
swift test --package-path DropUpCore
```

CI runs them on every pull request.

## Layout

```
DropUpCore/          Swift package
  Sources/DropUpCore       models, stores, upload queue, FTP protocol (no dependencies)
  Sources/DropUpTransport  Network.framework FTP sockets and the Citadel SFTP client
  Tests/                   Unit tests (fakes) and integration tests (real servers)
App/DropUp/          The menubar app (SwiftUI + AppKit glue; project.yml generates the Xcode project)
scripts/test-servers.py  Throwaway FTP and SFTP servers for the integration tests
scripts/sparkle-sign.sh, make-appcast.py  Sign a release for updates and write its appcast
docs/ARCHITECTURE.md How the pieces fit and why
docs/RELEASING.md    Building signed, notarized releases
```
