# DropUp

A tiny macOS menubar app. Drop a file on the DropUp icon and it uploads straight to your FTP or SFTP server.

It is a pared-down take on the upload action in Dropzone 4: one destination, no shelf, no extras.

## Install

1. Download `DropUp-<version>.dmg` from the [Releases page](../../releases).
2. Open the DMG and drag **DropUp** into **Applications**.
3. Start DropUp from Applications. It lives in the menubar and walks you through setting up your server the first time. While its setup or Settings window is open it also shows in the Dock; closing the window removes the Dock icon and DropUp stays in the menubar.

Releases are signed with a Developer ID and notarized by Apple, so macOS opens them without a warning. A release marked
*pre-release* was built without the signing secrets: right-click DropUp and choose **Open** the first time. How releases
are built, and the secrets the maintainer adds to make them notarized, is in [docs/RELEASING.md](docs/RELEASING.md).

To have DropUp start when you log in, turn on **Open at login** in Settings → General.

## Using it

- Drag a file toward the menubar icon. A drop panel opens under it; drop the file there (or straight on the icon).
- The icon shows progress while uploading, a brief check when done, and a red dot if something failed.
- Click the icon for the list of uploads: progress, speed, cancel, retry and recent uploads.
- Server, credentials and upload folder are set in onboarding and editable in Settings → Connection. Passwords live in the macOS Keychain.

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
docs/ARCHITECTURE.md How the pieces fit and why
docs/RELEASING.md    Building signed, notarized releases
```
