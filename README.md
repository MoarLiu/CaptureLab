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
- arrow, curved arrow, line, rectangle, ellipse, filled rectangle, spotlight,
  adjustable blur, counter, smoothed brush, text, text highlight, and mosaic markup
- arrow/shape styles, text font/weight/alignment/background/border, reusable styles,
  favorite colors, and optional local OCR alignment for highlights
- independent image layers with move/resize/rotate, stacking, multi-selection,
  group movement, duplication, alignment, equal spacing, and horizontal/vertical arrangement
- annotation color, line width, and font size controls for new and selected markup
- editable `.capturelab` projects with open/save, history restoration, and recovery before closing or replacing the document
- non-destructive crops with aspect-ratio presets, exact canvas-pixel dimensions, selection moving/resizing, and edge snapping
- output resizing by dimensions or percentage, aspect-ratio locking, 90-degree rotation, and horizontal/vertical flips
- undo and redo for annotations, image layers, background/layout, crops, rotations,
  flips, and output dimensions
- transparent/solid/gradient/built-in/custom backgrounds, padding, rounded corners,
  shadows, output ratios, automatic margin balancing, and personal presets
- vertical and horizontal manual scrolling capture with thumbnail preview,
  fixed edge bands, uncertain-seam correction, undo-last-segment, and resource limits
- floating pinned screenshots with resize, opacity, click-through locking, and arrow-key movement
- optional quick-access overlay with per-capture copy, save, edit, pin, upload, and drag actions
- image paste and drag-in import, plus PNG file-promise drag-out from editor, history, and overlay
- copy rendered PNG output; export PNG or JPEG with size, quality, explicit JPEG
  background color, asynchronous file-size preview, and recent export settings
- optional Cloudflare R2 upload for rendered screenshots
- optional local Vision OCR tool with editable OCR text and copy support
- direct text selection and copy, multiple QR-code results, and recognition
  languages selected from those supported by the current macOS version

Save Editable Project (Command-Shift-S, or the Project menu) stores the original
image, independent image layers, annotations, background/layout, crop, and transforms
in one `.capturelab` file. Format 2 reads existing format-1 projects; older clients
must be updated to open format-2 projects. Open Project
(Command-Shift-O), Open Image, Finder, and file drag-in can reopen it. Projects
include the original pixels under redactions; use Save Edited Image, Copy,
PNG/JPEG export, PNG drag-out, or R2 upload to share only the composited result.
Blur is a visual effect; use mosaic for redaction.

Editor OCR reads the final composition, including redactions, image layers,
crop/transforms, and background. A rendering failure does not fall back to the
original. Changing annotations cancels pending recognition; changing blur or
mosaic also clears existing OCR text. Arrow keys move annotations and selected
objects by one displayed point, or ten with Shift, at every zoom level.

New edited history retains editable objects. Older PNG history opens as a single
background image. Undo history is not stored in project files; new edits after
reopening still support undo and redo. Before replacement, editor close, or quit,
the current project and preview are saved together. A failed write keeps the
editor open for retry. Concurrent editors preserve separate versions on conflict.

The image-adjustment menu beside Undo controls output dimensions, rotation, and
flips. Crop dimensions refer to canvas pixels before output scaling. Cropping
preserves original objects, including clipped portions; ordinary output shows
only the crop and keeps redactions. Image transformations and output resizing
share the same composition for preview, copy, save, pin, drag-out, and upload.

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

Paste Image and drag-in add independent layers to the current canvas; when empty,
the first image becomes the base image. Add Images accepts multiple files.
Open Image still replaces the document. Before replacement, edited or
imported content is preserved as an editable project and preview; a failed save keeps
the current editor intact. Drag the hand icon to deliver the rendered PNG to a
receiving app. Text fields retain their normal Command-V behavior. Unlock All
Pins and Close All Pins stay available in the menu bar while pins are locked;
arrow keys move an unlocked pin by one point, or ten with Shift.

The editor's bottom selector switches between annotation editing, image/object
editing, and the final output preview. The second toolbar row opens advanced
styles, the layer panel, and background/templates. Images stay below annotations,
so redactions cover the composed image; use the layer panel to reorder images.
Annotations retain their own drawing order. The background surrounds the finished
crop and does not change object coordinates. Copy, pin, drag-out, history, and R2
use the same composition; R2 continues to upload PNG.

Start Vertical/Horizontal Scrolling Capture from the Capture menu or menu bar.
Select content inside one window on one display, exclude scrollbars, configure
fixed edge bands if needed, then resume and scroll down/right in small steps with
pauses. Low-confidence matches pause for correction. Finish keeps accepted
segments; Cancel discards the session. See [scrolling compatibility and limits](docs/scrolling-capture-compatibility.md).
The [0.9.0 development record](docs/0.9.0-development-plan.md) covers the merged
0.9/0.10/0.11 scope and the remaining hardware/application validation limits.
The [0.10.0 review remediation record](docs/0.10.0-review-remediation.md) evaluates
the two third-party reports and records the subsequent fixes and validation.

Retention changes preview the affected capture count before deletion and require
a new confirmation if concurrent captures would expand that deletion set. Time
limits are enforced on startup, capture, and history refresh; edited entries use
their last edit time. Preview and project resources are cleaned up together. Existing exported
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
