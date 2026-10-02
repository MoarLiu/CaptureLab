# Changelog

## 0.7.0 - 2026-10-02

- Added precise region capture with the last successful region, fixed size and
  ratio presets, keyboard nudging, crosshair guides, magnifier, pixel-size
  feedback, and frozen-screen selection.
- Added a unified capture launcher and independent global shortcuts for region,
  full-screen, window, delayed, last-region, launcher, direct text, and QR-code
  actions. Conflicts and registration failures remain visible per action.
- Added direct text selection and copy without opening the editor, multi-result
  QR recognition, cancellation, task replacement isolation, and clipboard
  preservation when recognition returns no result.
- Added Vision language settings generated from the languages supported by the
  current macOS installation.

- Fixed custom aspect-ratio locking during width and height edits, preserved
  selected ratios at desktop boundaries, and removed the editor's duplicate
  character-based region shortcut binding.

- Fixed Retina output resolution by reading display-mode backing pixels and
  rejecting captured frames whose dimensions disagree with the display mode.

Validation: 268 tests pass with strict concurrency and warnings as errors.
Both ARM64 and Intel macOS 13 release packages pass local artifact verification.

Artifacts:

- `CaptureLab-0.7.0-macos-arm64.dmg`
- SHA-256: `88be47bf5aec35115586c2fce4c648878ff9b5963c26aafd5b4cde30e45366a0`
- `CaptureLab-0.7.0-macos-arm64.dmg.sha256`
- `CaptureLab-0.7.0-macos-arm64.dmg.sig`
- `CaptureLab-0.7.0-macos-x86_64.dmg`
- SHA-256: `9d00578cbdb67fe76a25c5e3c153f5ddbc465ec8ffbfabf22beaed2ddd32024d`
- `CaptureLab-0.7.0-macos-x86_64.dmg.sha256`
- `CaptureLab-0.7.0-macos-x86_64.dmg.sig`

Known release notes:

- Requires macOS 13 or later. Choose arm64 for Apple Silicon or x86_64 for Intel.
- Uses the existing local self-signed certificate and is not notarized; macOS
  may require manual approval on first launch.
- Real screen-recording permission flows, mixed-scale multiple displays,
  full-screen Spaces, non-US keyboards, and real mixed-language/QR recognition
  still need manual acceptance. Intel hardware and macOS 13 hardware were not
  available for runtime testing.
- Shortcut recording retains limitations for combinations already handled by
  application menus or registered global shortcuts.

## 0.6.0 - 2026-10-02

- Added configurable post-capture actions: editor, quick-access overlay, and copy only.
  Overlay and copy-only capture preserve the active editing session.
- Added immutable quick-access snapshots with copy, save, edit, pin, R2 upload,
  and drag actions; configurable corner, size, timeout, screen following,
  multiple-capture navigation, temporary hiding, and restore-last support.
- Added image paste and drag-in import, with recovery of outgoing edits; added
  rendered PNG file-promise drag-out from the editor, overlay, and history.
- Added click-through pin locking, one-point arrow-key movement (ten with Shift),
  and menu-bar commands to unlock or close all pins.
- Added history count and age limits stored atomically with the index; retention
  previews and reconfirms newly affected items after concurrent captures.
- Added an independent scrolling-capture feasibility probe; scrolling capture
  is not part of the application in this version.

Artifacts:

- `CaptureLab-0.6.0-macos-arm64.dmg`
- SHA-256: `41b2da5c32b49ee7a98a811e58d34608db3acf867bf9fd240ec25856f2d214ab`
- `CaptureLab-0.6.0-macos-arm64.dmg.sha256`
- `CaptureLab-0.6.0-macos-arm64.dmg.sig`
- `CaptureLab-0.6.0-macos-x86_64.dmg`
- SHA-256: `388f62f30bf6142aa9f31bd4e78f6c5328aa9b7aaeee70911b537e3f7a4a57ec`
- `CaptureLab-0.6.0-macos-x86_64.dmg.sha256`
- `CaptureLab-0.6.0-macos-x86_64.dmg.sig`

Known release notes:

- Requires macOS 13 or later. Choose arm64 for Apple Silicon or x86_64 for Intel.
- The app uses a stable local self-signed certificate rather than Apple
  Developer ID and is not notarized. macOS may require manual approval on
  first launch.
- Shortcut recording still has limitations for shortcuts already assigned to
  application menu commands and some shifted or non-US keyboard combinations.
- Cross-app drag-and-drop, mixed-scale multiple displays, Intel hardware,
  macOS 13 hardware, and real-account R2 upload still need manual acceptance.
- Quit older CaptureLab copies before upgrading. Older versions retain their
  fixed 30-item history limit and do not understand the new retention settings.

## 0.5.1 - 2026-10-02

- Kept complete counter numbers inside their circles when resizing, with
  consistent font fitting in the editor preview and exported images.
- Fixed opening, copying, saving, uploading, and pinning a history entry after
  another CaptureLab instance crops it. History actions now read the latest
  image and metadata together; saving also survives deletion while its panel
  is open.

Artifacts:

- `CaptureLab-0.5.1-macos-arm64.dmg`
- SHA-256: `fd52e35e310eab1957c99ef2fa5508f3d2e69b1be1385676915186901a529739`
- `CaptureLab-0.5.1-macos-arm64.dmg.sha256`
- `CaptureLab-0.5.1-macos-arm64.dmg.sig`
- `CaptureLab-0.5.1-macos-x86_64.dmg`
- SHA-256: `20f11d0acb990d46ee5a1b26b5d155156db03a0a234ff6c396d381aeec3bcfc6`
- `CaptureLab-0.5.1-macos-x86_64.dmg.sha256`
- `CaptureLab-0.5.1-macos-x86_64.dmg.sig`

Known release notes:

- Shortcut recording still has limitations for shortcuts already assigned to
  application menu commands and some shifted or non-US keyboard combinations.
- The app uses a stable local self-signed certificate rather than Apple
  Developer ID and is not notarized. macOS may require manual approval on
  first launch.
- Requires macOS 13 or later. Choose arm64 for Apple Silicon or x86_64 for Intel.

## 0.5.0 - 2026-10-01

- Added annotation color, line width, and font size controls for new and selected
  markup, using shared preview and export styling.
- Added source-pixel crop selection with an apply/cancel workflow. Cropping keeps
  rendered redactions; Undo restores the original image and editable annotations.
- Added Redo and unified edit history for annotation changes and crops.
- Added independent, resizable always-on-top screenshot windows with opacity
  controls and Esc/Command-W closing.
- Added a thumbnail history browser for all retained captures, including refresh,
  open, copy, save, upload, pin, and confirmed deletion actions.
- Made crop dimension updates and history deletion safe across concurrent app
  instances and failed writes.
- Preserved active annotation drags across selection-triggered SwiftUI refreshes;
  explicit undo and deletion still cancel the gesture.
- Kept corrected OCR text and pending source recognition during annotation-only
  undo and redo, while crop transitions continue to invalidate stale requests.
- Reclaimed abandoned history image-update files under the history lock after
  interrupted edits, without deleting unrelated files or active writes.
- Selected contrasting counter text colors for light and dark annotation fills
  in both the preview and exported images.

Artifacts:

- `CaptureLab-0.5.0-macos-arm64.dmg`
- SHA-256: `b5cd332c18be007391842491d643730545e6fb099c229d6ed9271da94e8fcf70`
- `CaptureLab-0.5.0-macos-arm64.dmg.sha256`
- `CaptureLab-0.5.0-macos-arm64.dmg.sig`
- `CaptureLab-0.5.0-macos-x86_64.dmg`
- SHA-256: `ddd578c72c3dfeed2634ff0e61e58f63cb19d7d42b0efa13edd86448851ec80a`
- `CaptureLab-0.5.0-macos-x86_64.dmg.sha256`
- `CaptureLab-0.5.0-macos-x86_64.dmg.sig`

Known release notes:

- Shortcut recording still has limitations for shortcuts already assigned to
  application menu commands and some shifted or non-US keyboard combinations.
- The app uses a stable local self-signed certificate rather than Apple
  Developer ID and is not notarized. macOS may require manual approval on
  first launch.
- Requires macOS 13 or later. Choose arm64 for Apple Silicon or x86_64 for Intel.

## 0.4.3 - 2026-09-06

- Done now saves the rendered image back to recent captures, including all
  annotations and mosaics. Copying, uploading, and reopening that history entry
  use the edited result. Failed history saves preserve the editor for retry.
- Added visible operation status and error dialogs for capture, image loading,
  saving, OCR, and history failures, including captures started in the background.
  Cancelling a capture does not show an error dialog.
- Enforced update size limits while receiving response headers and image data,
  with cancellation and cleanup of incomplete downloads.
- Corrected update version ordering for prereleases, final releases, and build
  metadata, and aligned the checker with the installer.
- Removed local build-path metadata from release executables.

Artifacts:

- `CaptureLab-0.4.3-macos-arm64.dmg`
- SHA-256: `e3fc825e44a49c6d48db1103dffed1d72367a9983394915ce79adbc891a67067`
- `CaptureLab-0.4.3-macos-arm64.dmg.sha256`
- `CaptureLab-0.4.3-macos-arm64.dmg.sig`
- `CaptureLab-0.4.3-macos-x86_64.dmg`
- SHA-256: `38d5a40aefbe7a4e3cde123476f824a894a017ffb855268c7980e0c7ba10e709`
- `CaptureLab-0.4.3-macos-x86_64.dmg.sha256`
- `CaptureLab-0.4.3-macos-x86_64.dmg.sig`

Known release notes:

- Shortcut recording still has limitations for shortcuts already assigned to
  application menu commands and some shifted or non-US keyboard combinations.
- The app uses a stable local self-signed certificate rather than Apple
  Developer ID and is not notarized. macOS may require manual approval on
  first launch.

## 0.4.2 - 2026-07-12

- Fixed Mosaic rendering for indexed, CMYK, and transparent images, with an
  opaque fail-closed fallback and bounded preview caching.
- Preserved source pixel dimensions and consistent annotation styling across
  preview zoom levels and exported images.
- Committed active text edits before copy, save, upload, Done, Undo, Clear,
  zoom rebuild, and editor teardown; Save As now freezes one rendered PNG
  before its modal panel opens.
- Prevented stale OCR and upload completions from mutating a replacement or
  finished document.
- Hid CaptureLab windows during capture, tightened screenshot error
  classification, and isolated temporary captures per process with safe stale
  workspace recovery and child-process termination on exit.
- Made history writes and global shortcut replacement failure-safe across
  concurrent app instances, and reclaimed orphaned or overflow history images.
- Moved R2 secrets to Keychain, require HTTPS endpoints, and made settings plus
  secret updates a cross-process rollback-safe transaction.
- Added signed update assets, streaming download/hash verification, package
  identity checks, strict code-signature checks, serialized installs, and
  atomic install/rollback.
- Hardened local build and packaging verification, including stable cross-build
  local signing, fail-closed release asset publication, architecture checks,
  and expanded regression tests.

Artifacts:

- `CaptureLab-0.4.2-macos-arm64.dmg`
- SHA-256: `a481bf6dfd29a667c6752cd54c925a3668f052b36e9e495c149c486a927e4dab`
- `CaptureLab-0.4.2-macos-arm64.dmg.sha256`
- `CaptureLab-0.4.2-macos-arm64.dmg.sig`
- `CaptureLab-0.4.2-macos-x86_64.dmg`
- SHA-256: `6a90d306471bbb504052fc2200a03a1a52c5e555fb9521d2f3e3e16238f8742d`
- `CaptureLab-0.4.2-macos-x86_64.dmg.sha256`
- `CaptureLab-0.4.2-macos-x86_64.dmg.sig`

Known release note:

- The app uses a stable local self-signed certificate rather than Apple
  Developer ID and is not notarized, so macOS may require manual approval on
  first launch.

## 0.4.1 - 2026-07-04

- Fixed Done so finishing an edit copies the rendered image, clears the active document, and prevents the previous image from reopening from the Dock.
- Replaced update-check release-page handoff with direct DMG download, sha256 verification, in-place install, and relaunch.

Artifact:

- `CaptureLab-0.4.1-macos-arm64.dmg`
- SHA-256: `f802d0ae55b4f08a25cd8cc2a10862907e68b023b6ae8e71c0f0ff7c6caf793d`
- `CaptureLab-0.4.1-macos-arm64.dmg.sha256`
- `CaptureLab-0.4.1-macos-x86_64.dmg`
- SHA-256: `547c79d232271f01863e1e57f942ee5981834cc18f0947faf87267ebefc6137a`
- `CaptureLab-0.4.1-macos-x86_64.dmg.sha256`

## 0.4.0 - 2026-07-04

- Added a global screenshot shortcut that works while CaptureLab is in the background.
- Added full screen, window, and delayed region capture modes.
- Added recent capture history with open, copy, save as, and upload actions.
- Implemented real Fit, 50%, 100%, and 200% editor zoom controls with scrollable fixed-zoom canvas access.
- Hardened mosaic sampling with shared pixelation logic and top-region regression coverage.
- Removed unused inspector UI code and replaced the fake zoom menu.
- Stabilized launch behavior so the editor window only appears when explicitly opened or after a successful capture.
- Improved capture status messages and history metadata recovery.

Artifact:

- `CaptureLab-0.4.0-macos-arm64.dmg`
- SHA-256: `bf3a6e5931f2263660054b2633bb3e14f4c0f9019ade0b92ff8345792c8f2bd1`
- `CaptureLab-0.4.0-macos-x86_64.dmg`
- SHA-256: `c6176214aa14d76e79a18a6993ef0f819dc436478ce063130a65f0142decf4a6`

Known release note:

- The app is ad-hoc signed and not notarized in this release.

## 0.3.0 - 2026-07-03

- Added Line annotation tool with editable endpoints.
- Added Counter annotation tool with auto-incrementing numbered markers.
- Added Text Highlight annotation tool with translucent yellow highlight blocks.
- New annotations render in the editor and exported PNG output.

Artifact:

- `CaptureLab-0.3.0-macos-arm64.dmg`
- SHA-256: `c0ecc7a07ec9cc06aad54d7aaca8e7697805310f1b0362bb268dde785aca2355`
- `CaptureLab-0.3.0-macos-x86_64.dmg`
- SHA-256: `b4d46e904c4886fd67e58e0ab2a55ce6c579d922964684197d40723710c43d92`

## 0.2.0 - 2026-07-03

- Added Cloudflare R2 settings from the menu bar.
- Added screenshot editor upload for the current rendered PNG.
- Upload returns the public file URL to the clipboard.
- Added Esc and Command-W window closing for app windows and alerts.
- Launching CaptureLab no longer opens the main editor window automatically.

Artifact:

- `CaptureLab-0.2.0-macos-arm64.dmg`
- SHA-256: `10ff51cba85321b51cb19e133c4b2907f428eec537268dc03e9ef73cfc2b3cfe`
- `CaptureLab-0.2.0-macos-x86_64.dmg`
- SHA-256: `811e66184ed82375ecc0dccf25338de1119ac394da4f21983fb746988864468f`

## 0.1.0 - 2026-07-03

Initial CaptureLab release.

- Native macOS region screenshot flow.
- Screenshot editor with arrow, rectangle, brush, text, and mosaic tools.
- Copy, save as PNG, and Done-to-copy-and-close workflow.
- Manual OCR tool inside the editor.
- Configurable screenshot shortcut.
- Chinese and English UI text.
- Separate Apple Silicon and Intel Mac release artifacts.
- GitHub Release update check bound to `https://github.com/MoarLiu/CaptureLab`.

Artifact:

- `CaptureLab-0.1.0-macos-arm64.dmg`
- SHA-256: `72a7759339c91fdbe0e1cebec6b1caea3328a1e87ce895d711cca6dacc57d015`
- `CaptureLab-0.1.0-macos-x86_64.dmg`
- SHA-256: `b0ebdc9de1fdef545c1f1afdfe48e49c6a710450e8b316bd84039bb821a6491f`

Known release note:

- The app is ad-hoc signed and not notarized in this release.
