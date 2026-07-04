# Changelog

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
