# CaptureLab

CaptureLab is a small native macOS screenshot and annotation lab app.

The current MVP keeps the scope narrow:

- interactive region capture through the system capture picker
- image preview
- simple arrow, rectangle, brush, text, and mosaic markup
- copy/save rendered PNG output
- optional local Vision OCR tool
- editable OCR text with copy support when OCR is run manually

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
