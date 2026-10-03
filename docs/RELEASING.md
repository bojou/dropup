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

## Automatic updates

Installed copies of DropUp check for new versions with [Sparkle](https://sparkle-project.org) (Settings → General →
Updates). The Release workflow publishes what they read: next to the DMG, each release has an `appcast.xml`, and the app
looks at `https://github.com/bojou/dropup/releases/latest/download/appcast.xml`, so the newest release is always the one
offered. Sparkle installs an update only if the DMG carries a signature that matches the public key built into the app.
The signing key is separate from the Developer ID certificate, and it is made once.

| Where | What it is |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` (repository secret) | The private half of the update signing key |
| `SUPublicEDKey` (in `info.properties` in `project.yml`) | The public half. It is public, so it is committed |

Without the secret the workflow still works. It prints a warning and publishes the release without an `appcast.xml`, and
installed copies are not offered that release. A release made with the secret but without the public key in the app fails,
so the two can't drift apart unnoticed.

### Making the key

1. In Terminal (use the Sparkle version in `project.yml`, so the tool and the framework in the app match):

   ```sh
   cd /tmp && curl -fsSL -o sparkle.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
   mkdir -p sparkle && tar -xf sparkle.tar.xz -C sparkle && sparkle/bin/generate_keys
   sparkle/bin/generate_keys -x key.txt && pbcopy < key.txt && rm key.txt
   ```

   `generate_keys` stores the key in your login Keychain and prints the public key (it looks like `KU6D…=`).
   `generate_keys -p` prints it again later.
2. Paste the clipboard into a new repository secret named `SPARKLE_PRIVATE_KEY`, then clear the clipboard with
   `pbcopy < /dev/null`. Never paste the private key anywhere else.
3. Put the public key in `info.properties` in `project.yml` as `SUPublicEDKey`.

Keep the key in your Keychain backed up. If it is lost, installed copies can't verify anything new, and everyone has to
install a build with a new public key by hand.

### How an update reaches a Mac

The workflow signs and notarizes the DMG first, then signs that final DMG for Sparkle (the private key only passes
through that one step, and the signature is checked against the public key inside the app before it is published) and
writes `appcast.xml` with the version, the download link, the signature and the commit titles since the previous
release. Installed copies look once a day. A version found that way is announced by a blue dot on the menubar icon and an
**Update available** row in the popover, and Sparkle's window (notes, install, skip or later) opens only from that row,
because DropUp has no Dock icon for a window to come from. **Check Now** opens the window straight away. Nothing installs
without a click, and an update that is ready waits for running uploads and downloads to finish before DropUp restarts.

The first release that contains Sparkle has to be installed by hand like any other DMG. The release after it is the
first one an installed copy can pick up: install the first one, wait for the next release, then choose
**Check Now** in Settings → General.

## Installing a release

Download `DropUp-<version>.dmg` from the Releases page, open it, and drag **DropUp** into **Applications**. Ejecting the
disk image and deleting the download is left to the person installing. DropUp lives in the menubar, and shows in the Dock
only while its setup or Settings window is open.
