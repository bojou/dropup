# DropUp

A tiny macOS menubar app. Drop a file on the DropUp icon and it uploads straight to your FTP or SFTP server.

It is a pared-down take on the upload action in Dropzone 4: one destination, no shelf, no extras.

## Status

Early skeleton. The UI is being designed as a mockup first, so the app target is not in the repo yet. What exists today:

- `DropUpCore`, a Swift package with all the logic: server config and validation, settings store, Keychain credential store, the upload queue with progress events, and an FTP reply/passive-mode parser.
- Unit tests for the core package.

FTP (passive mode, EPSV with PASV fallback) and SFTP (password auth, trust-on-first-use host keys) transfers work and are tested against real servers. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

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
scripts/test-servers.py  Throwaway FTP and SFTP servers for the integration tests
docs/ARCHITECTURE.md How the pieces fit and why
```
