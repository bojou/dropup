# DropUp

A tiny macOS menubar app. Drop a file on the DropUp icon and it uploads straight to your FTP or SFTP server.

It is a pared-down take on the upload action in Dropzone 4: one destination, no shelf, no extras.

## Status

Early skeleton. The UI is being designed as a mockup first, so the app target is not in the repo yet. What exists today:

- `DropUpCore`, a Swift package with all the logic: server config and validation, settings store, Keychain credential store, the upload queue with progress events, and an FTP reply/passive-mode parser.
- Unit tests for the core package.

Not done yet: the actual FTP and SFTP transfers. Both uploaders currently throw `notImplemented`. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the plan.

## v1 scope

- Plain FTP and SFTP
- Upload progress in the menubar icon
- Onboarding to set server, credentials and upload folder, editable later in Settings
- Passwords stored in the macOS Keychain

Out of scope for v1: copying the uploaded file's URL, FTPS, multiple destinations, key-based SFTP auth.

## Requirements

- macOS 14 or later
- Xcode 16 or later

## Tests

The core package tests run without Xcode's UI or a server:

```sh
swift test --package-path DropUpCore
```

CI runs them on every pull request.

## Layout

```
DropUpCore/          Swift package: models, stores, upload queue, protocol uploaders
  Tests/             Unit tests with fake uploader and in-memory stores
docs/ARCHITECTURE.md How the pieces fit and why
```
