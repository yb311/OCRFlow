# Releasing

Pushing a `v*` tag builds, signs, notarises, packages and publishes a release,
then updates the Sparkle feed that shipped copies of the app check. Everything
after the one-time setup below is automatic.

## One-time setup

### 1. Apple Developer Program

Signing and notarisation need a paid account ($99/year). Without them macOS
Gatekeeper refuses to open the app on anyone else's Mac.

1. Enrol at [developer.apple.com](https://developer.apple.com/programs/).
2. In Xcode, **Settings → Accounts → Manage Certificates → + → Developer ID
   Application**. This is the only certificate kind that works for distribution
   outside the App Store.
3. Export it from **Keychain Access → My Certificates**: right-click the
   *Developer ID Application* entry → **Export** → `.p12`, and set a password.
   The export must include the private key, so export the certificate row that
   has a disclosure triangle, not the bare key.
4. Create an app-specific password at
   [appleid.apple.com](https://appleid.apple.com) → **Sign-In and Security →
   App-Specific Passwords**. Notarisation uses this, never your real password.
5. Note your ten-character Team ID from
   [developer.apple.com/account](https://developer.apple.com/account) →
   **Membership**.

### 2. Repository secrets

Add these under **Settings → Secrets and variables → Actions**:

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | The `.p12` from step 3, base64-encoded: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `APPLE_ID` | The Apple ID email on the developer account |
| `APPLE_APP_PASSWORD` | The app-specific password from step 4 |
| `APPLE_TEAM_ID` | The ten-character Team ID from step 5 |
| `SPARKLE_PRIVATE_KEY` | The EdDSA update-signing key (see below) |

The Sparkle keypair already exists: the public half is `SUPublicEDKey` in
`OCRFlow/Info.plist`, and the private half belongs in `SPARKLE_PRIVATE_KEY`. It
signs every update so that a shipped app will only install an archive that came
from this repository — losing it means shipped copies can no longer be updated
without a new key and a new manual download, so keep a copy somewhere safe.

## Cutting a release

```bash
git tag v1.1.0
git push origin v1.1.0
```

The workflow then:

1. builds a universal (Apple Silicon + Intel) Release archive, with
   `CFBundleShortVersionString` from the tag and `CFBundleVersion` from the
   commit count, so no version numbers are edited by hand;
2. signs it with Developer ID and a hardened runtime;
3. notarises the app with Apple and staples the ticket, so it opens offline
   without a Gatekeeper warning;
4. packages `OCRFlow-<version>.dmg` (notarised and stapled in its own right)
   and `OCRFlow-<version>.zip`;
5. publishes a GitHub Release with generated notes and both files;
6. signs the zip with the Sparkle key and uploads `appcast.xml`.

Re-running a tag needs the existing release deleted first, since the workflow
creates rather than replaces it.

## How updates reach users

The app reads `SUFeedURL` from `Info.plist`, which points at
`releases/latest/download/appcast.xml` — a URL GitHub always resolves to the
newest published release, so the feed never needs a server. Sparkle compares
`CFBundleVersion`, verifies the EdDSA signature against `SUPublicEDKey`, and
installs the zip. Users can also check by hand from **OCRFlow → 检查更新…** or
**Settings → 行为 → 软件更新**.

Because updates are delivered as the zip, an update is roughly the same size as
a fresh download; the bundled ONNX models are most of it.

## Maintenance

**Rotating the Sparkle key.** Generate a new pair with Sparkle's own tool
(`generate_keys` from the [Sparkle release
tarball](https://github.com/sparkle-project/Sparkle/releases)), put the printed
public key in `Info.plist` and the exported private key in `SPARKLE_PRIVATE_KEY`.
Anyone still running a build that trusts the old key will not see updates signed
with the new one, so rotate only if the key leaks.

**Bumping Xcode.** Both workflows pin `/Applications/Xcode_26.3.app` to match
local builds. Runner images drop old Xcodes eventually; when that happens the
build fails immediately on the `Select Xcode` step, and the fix is to point both
workflows at a version listed in the [runner image
README](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).

**Bumping Sparkle.** The version is pinned in two places that must agree: the
package requirement in `project.pbxproj` and `SPARKLE_VERSION` in
`.github/workflows/release.yml`.
