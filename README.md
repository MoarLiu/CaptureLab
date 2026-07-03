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
