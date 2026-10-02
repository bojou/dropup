# Releasing DropUp

A release is a DMG on the repository's Releases page. The **Release** workflow builds it on GitHub, so nothing
has to be built on your Mac.

## Making a release

Either push a tag:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

or open **Actions → Release → Run workflow** and type a version like `0.1.0`. The workflow tags the current commit,
builds the app, signs it, creates the DMG, and publishes it as a release. The finished DMG is on the release page a few
minutes later (notarization is the slow part).

## Signing and notarization secrets

Without any secrets the workflow still works, but it produces an **unsigned prerelease**: macOS shows a warning on first
launch and you have to right-click → Open. With the secrets below the DMG is signed with your Developer ID and
notarized by Apple, so it opens with no warning at all.

Add these under **Settings → Secrets and variables → Actions → New repository secret** in the GitHub repository.
Never paste them anywhere else (not in chat, not in a file in the repo).

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE` | Your *Developer ID Application* certificate and private key, exported as a `.p12` file and base64-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | The password you chose when exporting that `.p12` |
| `NOTARY_APPLE_ID` | The Apple ID email you use for your developer account |
| `NOTARY_TEAM_ID` | Your 10-character Team ID |
| `NOTARY_PASSWORD` | An app-specific password for that Apple ID (not your normal Apple ID password) |

### 1. The certificate (`MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`)

1. Open **Xcode → Settings → Accounts**, pick your team, click **Manage Certificates…**, click **+** and choose
   **Developer ID Application**. (Only the team's Account Holder can create this type. If the option is greyed out, the
   Account Holder has to do this step, or create it at developer.apple.com → Certificates.)
2. Open **Keychain Access**, choose the **login** keychain and the **My Certificates** tab, and find
   *Developer ID Application: Your Name (TEAMID)*. Expand it to check there is a private key underneath.
3. Right-click the certificate → **Export…**, choose the `.p12` format, and set a password. That password is
   `MACOS_CERTIFICATE_PASSWORD`.
4. In Terminal, copy the encoded file to the clipboard and paste it into the secret:

   ```sh
   base64 -i ~/Downloads/Certificates.p12 | pbcopy
   ```

5. Delete the `.p12` from Downloads once the secret is saved.

### 2. Notarization (`NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`)

1. `NOTARY_APPLE_ID` is your Apple ID email.
2. `NOTARY_TEAM_ID` is shown at developer.apple.com → **Account → Membership details → Team ID**.
3. For `NOTARY_PASSWORD`, go to appleid.apple.com → **Sign-In and Security → App-Specific Passwords**, create one named
   "DropUp notarization", and paste the generated `xxxx-xxxx-xxxx-xxxx` value.

### Checking it worked

In the workflow run, the *Notarize and staple the DMG* step ends with `accepted` and `spctl` prints
`source=Notarized Developer ID`. The release is then not marked as a prerelease.

If notarization is rejected, run `xcrun notarytool log <submission-id> --apple-id … --team-id … --password …` on your
Mac to see why; the submission id is in the workflow log.

## Installing a release

Download `DropUp-<version>.dmg` from the Releases page, open it, and double-click **DropUp**. It offers to install
itself into **Applications**, opens from there, and asks whether to eject the disk image and trash the download.
(Dragging **DropUp** into **Applications** also works; the same question comes the first time you start it.) It
lives in the menubar, and shows in the Dock only while its setup or Settings window is open.

The **Installer flow** workflow (Actions tab, run by hand) checks both ways of installing on macOS 15 and 26 with a
release-style DMG. Run it after changing `SelfInstall.swift` or `InstallerCleanup.swift`.
