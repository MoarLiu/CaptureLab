# CaptureLab

CaptureLab is a small native macOS screenshot and annotation lab app.

Current features:

- per-action global shortcuts with conflict reporting and physical key recording
- region, full screen, window, delayed, last-region, and frozen-screen capture modes
- unified capture launcher; precise region size, aspect ratio, keyboard adjustment,
  guides, magnifier, and logical-point/output-pixel dimensions
- configurable history retention (30, 100, or 300 captures and optional 1/7/30-day limits)
- full thumbnail browser for all retained captures, with refresh, open, copy,
  save as, Cloudflare R2 upload, pin, and confirmed deletion actions
- image preview with Fit, 50%, 100%, and 200% zoom
- arrow, line, rectangle, counter, brush, text, text highlight, and mosaic markup
- annotation color, line width, and font size controls for new and selected markup
- crop selection with source-pixel dimensions, Enter to apply, and Esc to cancel
- undo and redo for annotation edits and crops
- floating pinned screenshots with resize, opacity, click-through locking, and arrow-key movement
- optional quick-access overlay with per-capture copy, save, edit, pin, upload, and drag actions
- image paste and drag-in import, plus PNG file-promise drag-out from editor, history, and overlay
- copy/save rendered PNG output
- optional Cloudflare R2 upload for rendered screenshots
- optional local Vision OCR tool with editable OCR text and copy support
- direct text selection and copy, multiple QR-code results, and recognition
  languages selected from those supported by the current macOS version

Cropping merges the current annotations into the cropped pixels, including
mosaic redactions. Undo restores the original image and editable annotations;
redo reapplies the crop. Crop dimensions and exported PNGs use the source pixels,
including when the preview is scaled or the image is captured on a Retina screen.
Pinned screenshots keep a snapshot of the edited image and close independently
with Esc or Command-W. CaptureLab temporarily hides its windows, including pins,
while taking a new screenshot.

Screenshot Settings (Command-comma or the menu bar) controls the post-capture
behavior, overlay corner/size/timeout/display, and history retention. The default
continues to copy and open the editor. Overlay and copy-only modes preserve the
current edit. Overlays keep immutable capture pixels, so switching documents or
deleting history cannot change the image attached to their actions. Auto-close
pauses during hovering, dragging, and capture; the menu bar can hide overlays or
restore the most recently closed one.

Paste Image and drag-in open independent images. Before replacement, edited or
imported content is preserved as a rendered history image; a failed save keeps
the current editor intact. Drag the hand icon to deliver the rendered PNG to a
receiving app. Text fields retain their normal Command-V behavior. Unlock All
Pins and Close All Pins stay available in the menu bar while pins are locked;
arrow keys move an unlocked pin by one point, or ten with Shift.

Retention changes preview the affected capture count before deletion and require
a new confirmation if concurrent captures would expand that deletion set. Time
limits are enforced on startup, capture, and history refresh. Existing exported
files are independent of history cleanup.

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
