# Pocket Linux

OnePlus 13 (PJZ110): unlock, root, native Linux, and back to locked stock.

Scripts, build recipes and notes for taking a OnePlus 13 (codename dodge, SM8750, ColorOS 16 C.88) from locked stock
Android to root (Magisk) and on to a self-booting mainline Linux (Omarchy Mobile kernel chain, Ubuntu 24.04 rootfs on
userdata, slot b), and back to locked stock. Everything that writes to the phone asks for the phone's serial first.
Read `CLAUDE.md` for the full state of the project and the safety rules; `docs/` has the per-phase write-ups.

**Want to reproduce it?** `docs/ONEPLUS13-step-by-step.md` is the copy-paste runbook: every command from a locked stock OnePlus 13 to native Ubuntu booting from slot b, in the order that worked on 2026-11-19/20. `docs/ONEPLUS13-revert-to-stock.md` is the matching undo: back to stock Android with the bootloader locked.

## What you need

- macOS on Apple Silicon (scripts are bash 3.2 / zsh friendly; GNU-only options are avoided), Docker Desktop for the
  stage-1 kernel build, Homebrew packages: `brew install payload-dumper-go zstd lz4`
- A USB 2.0 path to the phone for fastboot (this bootloader is invisible over USB 3): e.g. the OnePlus cable through a
  dock's USB 2 hub.
- The phone's own stock firmware. The tool dumps it once rooted; `scripts/download-stock-ota.sh` fetches the full OTA.

Nothing proprietary is in this repository: firmware, dumps, build outputs, the Platform-Tools and the SSH private key
are gitignored and recreated by the scripts.


## Claude

Prompt Claude " I want to root my OnePlus13 Follow the instructions in ONEPLUS13-step-by-step.md"

## Quick start

```bash
scripts/android-tool.sh env          # vendors Google Platform-Tools into tools/, checks payload-dumper-go
scripts/android-tool.sh discover     # writes profiles/device-profile.{env,md} for the connected phone (gitignored)
scripts/fetch-inputs.sh [all|ota]    # Ubuntu Base tarball + Termux apk, optionally the stock OTA; see DOWNLOADS.md
```

Phase 1, unlock: Developer options > OEM unlocking, then `scripts/android-tool.sh unlock` (wipes the phone).
Phase 2, root: `scripts/android-tool.sh extract-boot <full-ota.zip>` (or `backup` on an already-rooted phone), then
`scripts/android-tool.sh root`; rollback with `restore init_boot`. Procedure: `docs/rooting.md`.
Phase 3, Linux: `scripts/ubuntu-chroot-setup.sh` (Ubuntu chroot on the phone, used as the build box),
`scripts/omarchy-build-phone.sh sources|stage2|initramfs|chain|rootfs|pull-rootfs|pull` (kernel + images, built on the phone;
the root filesystem is Ubuntu Server, bare Ubuntu or Arch Linux ARM, each with an optional GNOME desktop),
`kernel/stage1/fetch-sources.sh` + `kernel/stage1/build.sh` (stage-1 chainloader in Docker),
`kernel/stage1/add-avb-footer.sh` (a flashed boot image needs an AVB footer), `scripts/omarchy-first-light.sh`
(RAM-only test), `scripts/omarchy-install-slot-b.sh userdata|boot_b|activate` (the install), `revert-stock` + `lock`
(back to locked stock). Details and everything learned: `docs/linux-compatibility.md`.

## Safety

- Never flash xbl/abl/tz, modem, persist or vbmeta. Never flash images from an older build (anti-rollback).
- Never relock with a non-stock partition present: `scripts/avb-verify.py` proves a stock set against vbmeta.
- On this phone never hold Volume Up + Volume Down (EDL mode). Fastboot is Power + Volume Down from off.
