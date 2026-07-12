# CaptureLab

CaptureLab is a small native macOS screenshot and annotation lab app.

Current features:

- global screenshot shortcut from the menu bar app
- region, full screen, window, and delayed region capture modes
- recent capture history with open, copy, save as, and Cloudflare R2 upload actions
- image preview with Fit, 50%, 100%, and 200% zoom
- arrow, line, rectangle, counter, brush, text, text highlight, and mosaic markup
- copy/save rendered PNG output
- optional Cloudflare R2 upload for rendered screenshots
- optional local Vision OCR tool with editable OCR text and copy support

Build and run:

```bash
./script/build_and_run.sh
```

Package a release DMG:

```bash
./script/package_dmg.sh
```

Package a specific architecture:

```bash
CAPTURELAB_ARCH=arm64 ./script/package_dmg.sh
CAPTURELAB_ARCH=x86_64 ./script/package_dmg.sh
```

## Application code signing

Release bundles are signed with CaptureLab's stable local self-signed identity,
whose SHA-1 certificate fingerprint is
`636F51D5E5F9240F862327A82C3863C2F5EE7DFF`. The resulting designated
requirement binds the app's bundle identifier to that certificate root. Keeping
this identity stable lets a later CaptureLab build read the R2 secret that an
earlier build stored in Keychain without weakening the item's application ACL.
The update swap helper is signed with a distinct identifier so it cannot satisfy
the app's Keychain access requirement.

`script/package_dmg.sh` fails closed when this exact identity is unavailable;
it never falls back to ad-hoc signing or a different certificate. For local
development only, `script/build_and_run.sh` emits an explicit warning and falls
back to ad-hoc signing when the identity is missing. Such a fallback build does
not provide cross-build Keychain continuity and must not be released.

This identity is not a Developer ID certificate, and releases are not
notarized. A structurally valid signature therefore does not make the app pass
Gatekeeper assessment. Export the certificate together with its private key,
protect the export with a strong password, and keep at least one encrypted
offline backup. Losing that private key breaks the stable signing identity;
generating an unrelated replacement is not recovery. A future move to
Developer ID signing must include an explicit Keychain-access transition before
retiring this identity.

## Update signing

CaptureLab update packages are authenticated with a separate Ed25519 release
key. `script/package_dmg.sh` creates three matching assets for each build:

- `CaptureLab-<version>-macos-<arch>.dmg`
- `CaptureLab-<version>-macos-<arch>.dmg.sha256`
- `CaptureLab-<version>-macos-<arch>.dmg.sig`

The private key is not stored in this repository. This checkout already embeds
and locks CaptureLab's update-signing public key. By default the packaging
script expects the matching private key at:

```text
~/Library/Application Support/CaptureLab/Release/update-signing-private-key
```

If that file is missing, restore the matching private key from its encrypted
backup. Do not generate a new key as a recovery step: it will not match the
embedded public key, and existing installations will reject the resulting
updates. Keep at least one encrypted offline backup. Set
`CAPTURELAB_UPDATE_SIGNING_KEY` to use a different secure location containing
the same matching key.

### Establishing a new update-signing identity

The `generate` helper remains available only for establishing a brand-new
signing identity before its public key is embedded in an app or shipped to any
users:

```bash
swift script/update_signing.swift generate \
  "/secure/path/to/new-update-signing-private-key"
```

The helper writes the key with `0600` permissions and prints its public key.
Before the first release for that identity, embed the printed public key in
both `UpdateSigningIdentity` and `script/package_dmg.sh`, verify that they
match, and make an encrypted backup of the private key. Packaging deliberately
refuses any private key that differs from the embedded public key.

Key rotation is not recovery. Existing apps trust the previously embedded key,
so a rotation must be designed and shipped as a transition while the old
private key is still available. Simply generating a replacement and changing
the embedded public key will strand existing installations.

## Cloudflare R2 credentials

CaptureLab stores the R2 secret access key in the macOS Keychain. The local
`cloudflare-r2-settings.json` file contains only non-secret settings and is kept
at `0600`. Existing schema-v1 files with a plaintext secret are migrated only
after the secret is successfully written to Keychain; the original file is
left intact if migration fails. R2 endpoint and public URL settings must use
HTTPS.
