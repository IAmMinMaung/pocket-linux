# CLAUDE.md — Pocket Linux (Android unlock, root & Linux porting)

## Project Overview

This project focuses on unlocking, rooting, modifying, and eventually installing a custom Linux operating system on Android hardware.

Claude acts as a senior Android systems engineer, Linux kernel developer, and embedded device specialist.

The project is divided into three major phases:

1. **Bootloader Unlocking** — Identify the device, investigate manufacturer restrictions, unlock the bootloader, and establish recovery procedures.
2. **Android Rooting** — Obtain root access, configure debugging tools, and validate privileged access.
3. **Custom Linux Installation** — Investigate, build, port, and flash a Linux-based operating system that can run natively on the device.

The long-term objective is to use Android hardware as a general-purpose Linux computing platform, potentially supporting local AI inference, development tools, networking, and other Linux applications.

## Current Repository State

What actually exists today (keep this section current; the layout further down is the target, not the present):

> **ROOTFS FLAVOR IS A CHOICE, default Ubuntu Server (user's requests 2026-11-23).** `omarchy-build-phone.sh rootfs` asks `server` or `minimal` (`OMARCHY_FLAVOR`, default `server`, stored in `/root/out/linux-flavor` in the chroot); for `server` it also installs `ubuntu-minimal ubuntu-standard ubuntu-server` with `--no-install-recommends` (so no snapd, no cloud-init), masks `multipathd` and `lxd-installer.socket`, keeps NetworkManager; `verify-rootfs` prints an `ubuntu-server:` line. The package set was trial-installed in an arm64 `ubuntu:24.04` container (exit 0, +240 packages, about 630 MB total); it has NOT been built into an image or booted on the phone yet.
>
> **CLEAN SLATE 2026-11-23 evening (user's request: "we will redownload all installs, as well as images, as well as rebuild linux").** The phone was reverted first: `omarchy-install-slot-b.sh revert-stock` wrote stock `boot_b` and `init_boot_a` (both OKAY, stock set AVB-verified), slot a active, stock recovery formatted data, Android booted; then `… lock` was issued (log: "lock issued"). The locked state was NOT read back: adb showed the device with `error: closed` (USB debugging not yet re-enabled after the wipe). Run `scripts/android-tool.sh discover` to confirm `RO_BOOT_FLASH_LOCKED=1` before assuming it. Then everything gitignored was deleted: all of `firmware/` (both device dumps incl. GPT backups, device-stock, OTA extract, every `omarchy-dodge-*` build, the patched init_boot, the repo's hard link to the OTA), `rootfs/`, `tools/`, `kernel/src/`, the SSH key, `logs/`, `profiles/device-profile.*`, plus Docker volume `omarchy-build` and image `root-android-stage1`. The repo is tracked files only (~900 KB); the OTA zip is still in `~/Downloads` (untouched, outside the project). Nothing on the phone is custom, so the notes below describe history. Rebuild path: `docs/ONEPLUS13-step-by-step.md` from step 0; the kernel, chain image and rootfs must be REBUILT this time (Phases 3b-3d), nothing is left to reuse. The optional-desktop work (GNOME works, Lomiri crashes; `scripts/phone-desktop.sh`, `scripts/omarchy-desktop.sh`, runbook Phase 3g) is on branch `Desktop` (commit b03df22), not on main.
>
> **DEVICE STATE 2026-11-23 17:05 (history, no longer on the phone): native Ubuntu 24.04.5 boots from slot b (kernel 7.3.0-rc6-omamobile, root on userdata, user `m-3`, key SSH over USB IPv6 link-local, passwordless sudo, power key already ignored).** Installed by reusing the 2026-11-20 images (`omarchy-dodge-rootfs-20261120-2003`, `omarchy-dodge-chain-dbg-20261120-194408/…-avb.img`), verified first (sha256, AVB footer, key present in rootfs and initramfs); no rebuild. GPT bit 54 on boot_b set by the user at ~17:10 (attributes 0x0077, slot b successful). Wi-Fi profile saved by the user and reconnects by itself after a reboot (checked 17:59: `ssh -i keys/omarchy-dodge_ed25519 m-3@10.1.1.153`, DHCP address, may change). Nothing left to do from the runbook. The `rootfs` step now also asks for the device name (`OMARCHY_HOSTNAME`, default `oneplus13`; third field of `/root/out/linux-user`), added 2026-11-23 and not yet exercised by a real build. Android on slot a is rooted but its data is wiped. Lessons added to the runbook this day: `adb shell -t` for the chroot shell, `start.sh` uses `setsid -c` for job control, the first-light image needs `reboot -f`, the first-light password prompt is macOS sudo. Earlier the same day (16:20): stock C.88, bootloader UNLOCKED, ROOTED (Magisk 31.1 on init_boot_a), following `docs/ONEPLUS13-step-by-step.md`; Phases 1 and 2 done.** `adb shell su -c id` → uid 0 after the Shell entry was switched on in Magisk's Superuser tab (now a numbered step in the runbook). Live dump: `firmware/images/Original-PJZ110_16.0.5.703CN01-20261123-161715/`; its slot-b images are byte-identical to the existing `…-device-stock/` set (`STOCK_DIR`), which passes `scripts/avb-verify.py`. The repo was NOT a clean slate on this date: the 2026-11-20 afternoon artifacts (`omarchy-dodge-*`, rootfs, chain-dbg, key, tools) are present. Rollback: `scripts/android-tool.sh restore init_boot`.
>
> Earlier state 2026-11-20 13:xx: back to stock C.88, bootloader LOCKED (user ran `omarchy-install-slot-b.sh revert-stock` then `lock` after the full redo reached native Ubuntu on slot b). Nothing custom is on the phone; all artifacts and both runbooks remain in the repo.** Earlier state 2026-11-19 18:15: stock C.88, bootloader UNLOCKED, ROOTED (Magisk 31.1 on init_boot_a). Phases 1 and 2 of the redo are done. `adb shell su -c id` → uid 0 (Shell allowed in Magisk's Superuser tab; the first requests were denied instantly until the user flipped the Shell entry on). Live dump of both slots: `firmware/images/Original-PJZ110_16.0.5.703CN01-20261119-181020/`; slot b copied to `firmware/images/Original-PJZ110_16.0.5.703CN01-device-stock/` = `STOCK_DIR` (lock-safe: passes `scripts/avb-verify.py` against the phone's vbmeta; the CDN OTA init_boot does NOT, different compile). Patched image: `firmware/patched/Original-V.559d893-32cee1f-32dd63c-from-OTA-init_boot-magisk.img`. The OTA zip lives in `~/Downloads`, hard-linked into `firmware/images/`. Input checksums moved to tracked `checksums/inputs.sha256`. Next: Phase 3 (Ubuntu chroot via `scripts/ubuntu-chroot-setup.sh`, then the Omarchy kernel chain); `tools/avb/` is re-fetched by `kernel/stage1/fetch-avb.sh` (done 2026-11-19 21:50, checksums verified against Omarchy's lock). Phase 3 redo 2026-11-19/20: chroot up, first light repeated (RAM), rootfs (user `m-3`) and footered install chain image built and verified, GPT backup taken, install preflight ok at 00:10 on 2026-11-20 with the phone in fastboot. Artifacts: `firmware/images/omarchy-dodge-rootfs-20261120-0603/`, `omarchy-dodge-chain-dbg-20261120-054628/boot-chain-install-dbg-avb.img`. New build steps: `toolchain`, `vendor-fw`; `sources` pushes Ubuntu Base; `backup` dumps GPT too. **2026-11-20 00:25: the three writes are DONE; the phone boots native Ubuntu 24.04 from slot b** (user `m-3`, SSH over USB via IPv6 link-local, serial getty on ttyGS0). Android remains on slot a (needs a factory reset if ever reactivated, userdata now holds the ext4 root). Still to do: GPT bit 54 on boot_b, Wi-Fi profile.
>
> Earlier the same day: **reverted to stock, LOCKED.** The user asked for a full redo. `scripts/omarchy-install-slot-b.sh revert-stock` flashed the phone's own stock boot_b and init_boot_a (hash-verified against vbmeta), set slot a active, stock recovery formatted data, then `… lock` relocked the bootloader. adb now reports `ro.boot.flash.locked=1`, `verifiedbootstate=green`, slot `_a`, build C.88, no Magisk. Phases 1-3 below describe what WAS achieved and the artifacts still in the repo; none of it is on the phone now. The redo starts at Phase 1 (`android-tool.sh unlock`, plain OEM-unlocking + `fastboot flashing unlock` route; no Deep Testing app was ever involved on this unit). Everything learned (AVB footer, Wi-Fi firmware set, kmscon, llama.cpp) is in `docs/linux-compatibility.md` and reusable as-is.

- `scripts/android-tool.sh` — the main tool. A bash 3.2 script wrapping `adb`/`fastboot` for every phase: `env`, `discover`, `unlock`, `extract-boot`, `root`, `recovery`, `rom`, `restore`, `backup`, `reboot`. See "Working With android-tool.sh" below.
- `scripts/omarchy-build-phone.sh` — Phase 3 driver (the `rootfs` step prompts for the Linux user name and password, env `OMARCHY_USER`/`OMARCHY_PASSWORD` for unattended runs; never hard-code credentials in any script): builds the Omarchy Mobile mainline kernel chain for dodge inside the phone's Ubuntu chroot (stage2 kernel, Alpine initramfs, dodge-chain boot image) and pulls outputs to `firmware/images/omarchy-dodge-<ts>/`. Read the build log section of `docs/linux-compatibility.md` first. **First light achieved 2026-11-18**: the chain image booted mainline Linux 7.3.0-rc6 on the phone from RAM (USB NCM + serial console); nothing flashed yet. `keys/omarchy-dodge_ed25519` is the SSH key for the initramfs/rootfs over USB; never commit it.
- `scripts/omarchy-install-slot-b.sh` — the three serial-gated writes of the native-Linux install (userdata rootfs, boot_b chain image, set_active b) plus `back-to-android`. `scripts/omarchy-first-light.sh` runs the RAM-only boot test. Never run the install writes without the user confirming each one.
- `kernel/stage1/` — Docker build (arm64 on the Mac) of a debug stage-1 chainloader: `fetch-sources.sh` clones linux/omarchy-mobile/mkbootimg into `kernel/src/` (gitignored), `build.sh` → `in-container.sh` clones them into the `omarchy-build` volume, builds `fbtext.c`, packs with a patched `tools/dodge-chain` around the stage-2 artifacts in `firmware/images/omarchy-dodge-stage2-*/`, output `firmware/images/omarchy-dodge-chain-dbg-<id>/boot-chain-install-dbg.img`. **State 2026-11-18 evening: native Linux installed and self-booting.** userdata holds the Ubuntu rootfs, boot_b the footered chain image `firmware/images/omarchy-dodge-chain-dbg-20261118-211811/boot-chain-install-dbg-avb.img`, slot b active + successful (GPT 0x007F), an unattended reboot lands in Ubuntu in ~60 s (serial console `/dev/cu.usbmodemomamobile3`, user `min`). Root cause of the earlier flashed-boot failure: `vbmeta_b` chains `boot`, so a flashed boot image needs an AVB footer (`kernel/stage1/add-avb-footer.sh`, avbtool + AOSP test key in `tools/avb/`); `fastboot boot` skips AVB, which is why RAM boots always worked. The install script refuses an unfootered boot_b image. **Built-in Wi-Fi works** (ath12k, firmware set from the phone's own Android: amss20.bin as amss.bin, bdwlan.elf as board.bin, tmel/phy_ucode/aux_ucode from vendor-raw + modem_a.img); SSH over Wi-Fi `ssh min@10.1.1.51`, over USB `ssh -6 min@'fe80::…%en13'`. USB Wi-Fi dongle modules are installed too (`kernel/stage2-modules/`). Ollama tarball is at /root on the phone, not installed. See the last sections of `docs/linux-compatibility.md`. Never hold Volume Up + Volume Down on this phone (EDL mode); fastboot is Power + Volume Down from off.
- `scripts/download-stock-ota.sh` — fetches the official ~8.4 GB C.88 full OTA from OPPO's CDN as 128 MiB byte-range chunks into `firmware/images/.chunks/`, assembles it as `firmware/images/PJZ110_16.0.5.703_CN01_C88.zip`, and accepts it only if the MD5 is `2cc8031b2589dd4e80bd3c93326c7c7e`. Rerun to resume. The CDN resets long connections, which is why it is chunked. (The earlier root-level `download-stock-firmware.sh` was deleted by the user.)
- `firmware/stock/<build>/`, `firmware/patched/`, `firmware/backup/` — created by the tool. A leftover `firmware/*.zip.part` is an unverified download. If it is tiny JSON containing `"responseCode":2306`, the signed vendor link has expired: get a fresh URL and MD5 from the device's OTA check and update both in the download script together.
- `profiles/device-profile.env` and `profiles/device-profile.md` (moved from `docs/` on 2026-11-19, gitignored, see `profiles/README.md`) — written by `discover`. The `.env` file is what the tool reads back (codename, lock state, init_boot presence, stock build); the `.md` is for humans. As of 2026-11-13 the connected device is a **OnePlus 13 (PJZ110, codename OP5D0DL1, serial 7359ee91)**: bootloader already unlocked, Developer options and USB debugging on, Magisk app installed, `init_boot` present, not yet rooted. Phase 1 is complete. On 2026-11-18 the official C.88 OTA was downloaded, MD5/fingerprint-verified, and the `Original-*.img` set extracted (see `docs/bootloader.md`); `scripts/android-tool.sh root` flashed the Magisk 31.1 patched init_boot on 2026-11-18 (fastboot 'Writing init_boot OKAY'); phone booted, `magisk -v` reports 31.1 running. **Phase 2 is complete**: `adb shell su -c id` → uid 0 (Shell granted in Magisk's Superuser tab). A live dump of both slots was taken afterwards with `backup`; slot-b images are copied to `firmware/images/Original-PJZ110_16.0.5.703CN01-device-stock/` and `STOCK_DIR` points there, so `restore` uses the phone's own images. The CDN OTA images are a different compile (2026-03-03 vs the phone's 2026-03-06) of the same version: functionally identical, not byte-identical. Rollback: `scripts/android-tool.sh restore init_boot`.
- `docs/ONEPLUS13-step-by-step.md` — the copy-paste runbook of the whole project (unlock → root → chroot → builds → first light → slot-b install → post-boot steps), written 2026-11-20 from the redo; keep it in sync when a script's interface changes. `docs/ONEPLUS13-revert-to-stock.md` — the matching undo runbook (revert-stock, Format data, lock), written 2026-11-20. `docs/bootloader.md` — recorded unlock state and recovery path. `docs/rooting.md` — the step-by-step root procedure for this device; follow it rather than improvising. `docs/firmware-sources.md` — vetted places to get stock/ROM images for PJZ110 and which to trust. `docs/linux-compatibility.md` — Phase 3 status (2026-11-18): no Ubuntu Touch port; Omarchy Mobile (Arch, mainline) has an experimental slot-b port; postmarketOS boots only; recommended first step is Ubuntu userspace, which is now DONE: `docs/ubuntu-userspace.md` — Ubuntu 24.04.5 arm64 chroot at `/data/local/ubuntu` on the phone, launcher `start.sh`, user `min`, set up by `scripts/ubuntu-chroot-setup.sh`; Termux installed from `tools/apk/`.
- `firmware/images/` — downloaded and extracted images, one subfolder per source/build with `SHA256SUMS` and a README. `extract-boot` writes the stock set to `images/Original-<build>-from-OTA/Original-<partition>.img`. The older spike0en 16.0.1 set and the CDN `from-OTA` extract were deleted on 2026-11-19; `extract-boot` on the kept OTA zip recreates the latter.
- **Original images before flash is mandatory.** `root` refuses until `LAST_BACKUP` is recorded, which `extract-boot` sets. Dumping live partitions by temp-booting a recovery was tried on 2026-11-17 and does not work on this phone (bootloader needs USB 2.0, rejects kernel-less images, and the LineageOS kernel falls back to stock boot without its own dtbo/vendor_boot); the user then chose the mirror full-OTA route. Do not re-propose temp-boot.
- Fastboot on this phone is only visible over **USB 2.0**: use the OnePlus charging cable through the dock's USB 2 hub, never the USB-C data cable.
- Build C.88 carries **anti-rollback**. Never flash boot-chain images from an older build.
- `logs/` — one log per tool run plus raw `getprop` and partition dumps.
- `tools/platform-tools/` — Google's official macOS Platform-Tools (adb, fastboot), downloaded by `android-tool.sh` from `dl.google.com/android/repository/platform-tools-latest-darwin.zip` on first run and put first on `PATH` for every command. Delete the folder to force a fresh download. Do not install platform tools via Homebrew; the script ignores system copies. This folder is a large binary download and must be gitignored.
- **Clean slate 2026-11-20** (user's request after the relock, "I will redownload as needed"): everything gitignored was deleted: all of `firmware/` (both device dumps, device-stock, the OTA extract, every `omarchy-dodge-*` build, `patched/`, and the repo's hard link to the OTA zip; the zip itself is still in `~/Downloads`), `rootfs/` (Ubuntu Base tarball), `tools/` (platform-tools, apk, avb), `kernel/src/`, `kernel/stage2-modules` outputs, the SSH key pair, `logs/`, `profiles/device-profile.*`, plus the Docker volume `omarchy-build` and image `root-android-stage1`. The repo is now only tracked files (~600 KB). Rebuild path: `docs/ONEPLUS13-step-by-step.md` from step 0 (`env`, `discover`, `fetch-inputs.sh`, `ln ~/Downloads/<ota>.zip firmware/images/`).
- **Clean slate 2026-11-19**: at the user's request every device dump (`Original-*`, incl. the allfw and device-stock sets), every Omarchy build artifact (`omarchy-dodge-*`) and the SSH key pair were deleted. Only `firmware/images/PJZ110_16.0.5.703_CN01_C88.zip` (official OTA, MD5-verified) remains; everything else is regenerated by the scripts (`extract-boot`, `backup`, `omarchy-build-phone.sh`, `kernel/stage1/build.sh`; the key is generated by `omarchy-build-phone.sh` on first run). The lock-safe stock set is the phone's OWN dump taken after rooting, not the CDN OTA compile.
- **Portable since 2026-11-19** (user's request: anyone cloning from GitHub can run it). No machine paths: sources via `kernel/stage1/fetch-sources.sh` and `omarchy-build-phone.sh sources`, inputs via `scripts/fetch-inputs.sh` (checksums committed), the SSH key pair is generated on first use, the device serial and stock-image dir come from `profiles/device-profile.env` (gitignored, regenerated by `discover`; paths stored project-relative), `scripts/avb-verify.py` (stdlib, no avbtool) replaces hard-coded hashes. `README.md` is the GitHub landing page, `DOWNLOADS.md` lists every fetched input with link and checksum (`scripts/fetch-inputs.sh [all|ota]` fetches them); `.gitignore` covers firmware, dumps, inputs, platform-tools, the key, logs, the profile. Git repository initialised 2026-11-19 (no commits yet unless the user made them).
`rootfs/ubuntu-base-24.04.5-arm64/` holds the verified Ubuntu Base tarball for the chroot route. `.gitignore` exists (firmware, patched, logs, platform-tools, the SSH key); `README.md` and a Git repository exist since 2026-11-19.
- **Cleanup 2026-11-19** (user's request): deleted the superseded debug boot images, failed module builds, the old spike0en 16.0.1 set, the CDN `from-OTA` extract and stale `firmware/patched` Magisk image, `tools/ollama`, the raw 1.9 GB rootfs image (its `.zst` stays, sha verified) and the Docker volume `omarchy-build` (kernel source + build tree). Kept: the OTA zip, both device dumps, device-stock, stage2/chain-dbg-211811/modules-223011, the first-light chain dir, Docker image `root-android-stage1`. A stage-1 rebuild starts with `kernel/stage1/fetch-sources.sh`.

## Working With android-tool.sh

```bash
scripts/android-tool.sh env                        # ensure tools/platform-tools, check payload-dumper-go
scripts/android-tool.sh discover                   # write profiles/device-profile.* (adb or fastboot mode)
scripts/android-tool.sh unlock                     # get_unlock_ability, then flashing unlock / oem unlock
scripts/android-tool.sh extract-boot firmware/X.zip  # images -> firmware/stock/<build>/ (payload.bin aware)
EXPECTED_OTA_MD5=<md5> scripts/android-tool.sh extract-boot firmware/images/<ota>.zip   # REQUIRED first: Original-*.img
scripts/android-tool.sh root                       # push image, Magisk patch on device, pull, boot/flash
scripts/android-tool.sh recovery boot twrp.img     # temp-boot a custom recovery (or: recovery flash)
scripts/android-tool.sh rom lineage.zip            # sideload via recovery after codename check
scripts/android-tool.sh restore init_boot          # flash the stock image back
scripts/android-tool.sh --dry-run <cmd>            # print commands, skip prompts, write nothing to the device
```

How it enforces the command rules in this file:

- **Read-only** (`env`, `discover`, getvar/metadata reads) run without prompts.
- **State-changing** (any reboot, `fastboot boot`) ask for `y/N` with an explanation.
- **High-risk** (`flashing unlock`, `oem unlock`, `fastboot flash`, `adb sideload`) print a banner and require typing the device serial. There is no flag to skip this; do not add one.
- `unlock` runs a pre-flight before rebooting: over adb it requires Developer options and USB debugging to read back as 1, reads `sys.oem_unlock_allowed` (this OnePlus does not expose it, so the user must confirm the OEM-unlocking toggle, the USB 2.0 cable and a backup at a y/N checklist), then in fastboot it refuses to continue when `get_unlock_ability` is 0. Rerun the pre-flight whenever the phone has been relocked or reset; do not skip it.
- `extract-boot` and `rom` compare the zip's `pre-device` with the profiled codename and refuse on mismatch unless `ALLOW_DEVICE_MISMATCH=1`. `root` warns when the installed build differs from the extracted stock build.
- `root` patches `init_boot.img` when the device has that partition, otherwise `boot.img`. Only `boot` images can be temp-booted with `fastboot boot`; `init_boot` must be flashed, so the stock copy in `firmware/stock/` is the rollback and `restore init_boot` flashes it back.
- Stock OTAs from OPPO/OnePlus ship `payload.bin`; `extract-boot` needs `payload-dumper-go` on `PATH` for those.

When extending the script: keep it bash 3.2 compatible (no associative arrays, `mapfile`, or `${var,,}`), route every device write through `confirm_high_risk` + `run`, keep `--dry-run` honest (prompts skipped, commands printed, nothing executed), and update the usage block at the top of the file so `help` stays accurate. Device-specific steps belong behind a vendor check in `vendor_unlock_hint` or a profile value, never as unconditional commands.

## Development Environment

Primary development machine:

- Operating system: macOS
- Architecture: Apple Silicon (ARM64)
- Terminal: zsh
- Android tools: Google Platform-Tools, vendored in `tools/platform-tools/` by the script (not Homebrew)
- Programming languages: Bash, Python, C, C++, and Rust when appropriate
- Build systems: Make, CMake, Ninja, and Android/Linux build tooling
- Version control: Git

Prefer macOS-compatible commands and utilities.

Do not assume GNU-specific command options work with the macOS versions of standard utilities.

Use Homebrew when appropriate.

## Device Discovery

Before recommending any unlocking, rooting, or flashing operations, identify the connected device.

Collect:

- Manufacturer
- Model name and model number
- Hardware codename
- SoC/chipset
- CPU architecture
- Android version
- Security patch level
- Bootloader status
- Bootloader unlock support
- A/B partition configuration
- Dynamic partition configuration
- Recovery environment
- Kernel version
- USB vendor/product IDs
- Available firmware images
- Partition layout

Useful commands include:

```bash
adb devices -l
adb shell getprop
adb shell uname -a
adb shell cat /proc/cpuinfo
adb reboot bootloader
fastboot devices
fastboot getvar all
```

Only run commands appropriate to the device's current state.

Do not assume every Android device supports standard Fastboot commands.

Maintain discovered device information in `profiles/device-profile.md` (generated, gitignored).

## Phase 1 — Bootloader Unlocking

### Objectives

- Determine whether the bootloader is locked.
- Identify official manufacturer unlocking methods.
- Investigate device-specific restrictions.
- Determine whether unlocking causes a factory reset.
- Identify anti-rollback and verified boot restrictions.
- Preserve stock firmware and recovery options.
- Unlock the bootloader when technically supported.

### Preferred Approach

Prioritize manufacturer-supported unlocking methods.

Investigate device-specific methods only when official unlocking is unavailable.

Do not assume a bootloader unlock procedure for one model works on another.

Never execute bootloader unlocking commands without explicit user approval.

Example commands that may be appropriate for supported devices:

```bash
fastboot flashing get_unlock_ability
fastboot flashing unlock
```

These commands are examples, not universal instructions.

### Safety Requirements

Before unlocking:

1. Verify the exact device model.
2. Confirm that unlocking is supported.
3. Explain potential data loss.
4. Identify firmware recovery options.
5. Confirm backup completion.
6. Obtain explicit authorization.

## Phase 2 — Rooting Android

### Objectives

- Obtain root access.
- Preserve the ability to restore stock firmware.
- Enable privileged debugging.
- Understand Android Verified Boot.
- Investigate boot and init_boot partitions.
- Establish a reproducible rooting process.

### Preferred Rooting Methods

Evaluate device compatibility with:

- Magisk
- KernelSU
- APatch
- Device-specific root solutions

Prefer supported, maintained, and reproducible solutions.

Avoid obsolete one-click rooting applications and unverified binaries.

### Rooting Workflow

1. Identify the exact installed firmware build.
2. Obtain matching stock firmware images.
3. Determine whether the device uses `boot.img` or `init_boot.img` for the selected rooting method.
4. Prepare and patch the correct image.
5. Validate image compatibility.
6. Flash or temporarily boot the image using a supported procedure.
7. Verify root access.
8. Document rollback procedures.

Never flash an image from an incompatible firmware build.

## Phase 3 — Custom Linux Operating System

### Long-Term Goal

Replace Android with a native Linux operating system where supported by the hardware and available drivers.

Possible target distributions include:

- Ubuntu
- Debian
- postmarketOS
- Mobian
- Alpine Linux
- Arch Linux ARM
- Custom Buildroot-based Linux
- Custom Yocto-based Linux

Evaluate distribution compatibility before choosing one.

### Linux Porting Research

Investigate:

- ARM64 processor support
- Mainline Linux kernel compatibility
- Vendor kernel sources
- Device Tree and DTB/DTBO files
- U-Boot or alternative boot chains
- Boot image formats
- GPU drivers
- Wi-Fi and Bluetooth drivers
- Cellular modem support
- USB functionality
- Touchscreen and display drivers
- Battery management
- Power management and thermal control
- Storage and partition requirements
- SELinux and Android-specific dependencies

Distinguish between:

1. Running Linux userspace inside Android.
2. Running Linux through a container or chroot.
3. Dual-booting Android and Linux.
4. Booting a native Linux kernel.
5. Completely replacing Android.

Do not describe a Linux userspace environment as a complete native Linux installation.

### Preferred Development Strategy

When technically supported:

1. Build and test a Linux userspace.
2. Investigate kernel compatibility.
3. Compile a compatible kernel.
4. Prepare an initramfs and root filesystem.
5. Test temporary boot methods where available.
6. Validate hardware functionality.
7. Develop a persistent installation process.
8. Preserve a documented recovery path.

Prefer reversible boot tests over permanent flashing whenever possible.

## Claude Operating Instructions

### Technical Behavior

Claude should:

- Act as an experienced embedded Linux and Android engineer.
- Provide technically accurate, device-specific guidance.
- Research official documentation and reputable community projects when available.
- Explain relevant commands before executing them.
- Favor repeatable scripts over undocumented manual procedures.
- Clearly distinguish verified facts from assumptions.
- Identify dependencies and compatibility issues.
- Troubleshoot errors using actual terminal output.
- Keep instructions compatible with macOS.
- Avoid inventing firmware URLs, partition names, or device capabilities.

### Interaction Style

Work interactively, one stage at a time.

When troubleshooting:

1. Explain the immediate objective.
2. Provide the next command or small group of commands.
3. Ask for command output.
4. Analyze the results.
5. Continue based on the observed device state.

Do not provide dozens of speculative commands when device information is missing.

Avoid repeating completed steps.

### Command Execution Rules

Commands are divided into three categories.

**Read-only commands**

Examples: device discovery, version checks, partition inspection.

May be executed without additional confirmation when the user has authorized device inspection.

**State-changing commands**

Examples: rebooting, changing Android settings, installing packages.

Explain expected effects before execution.

**High-risk commands**

Examples:

- `fastboot flashing unlock`
- `fastboot flash`
- `fastboot erase`
- `fastboot format`
- `dd` writes to block devices
- Partition table modifications
- Bootloader or firmware replacement

Require explicit approval immediately before execution.

Never automatically execute destructive commands.

Never assume a command succeeded without checking its result.

## Firmware and Recovery

Before making permanent changes, establish a recovery strategy.

Maintain records of:

- Original firmware version
- Official firmware download sources
- Firmware checksums
- Original boot images
- Partition information
- Flashing utilities
- Recovery procedures
- Known working configurations

Do not assume that all partitions can be backed up on a locked device.

Do not modify critical partitions such as modem, EFS, persist, or bootloader firmware without a validated device-specific procedure.

## Project Directory Structure

Target layout. See "Current Repository State" for what exists now.

```text
android-linux-project/
├── CLAUDE.md
├── README.md
├── docs/
│   └── ...
├── profiles/            # generated device-profile.{env,md}, gitignored
│   ├── bootloader.md
│   ├── rooting.md
│   ├── partition-layout.md
│   ├── linux-compatibility.md
│   ├── recovery.md
│   └── troubleshooting.md
├── scripts/
│   ├── discover-device.sh
│   ├── check-bootloader.sh
│   ├── collect-device-info.sh
│   └── verify-environment.sh
├── firmware/
│   ├── stock/
│   └── patched/
├── kernel/
├── rootfs/
├── builds/
└── logs/
```

Do not commit proprietary firmware, personal device data, credentials, or large binary images to Git.

Use `.gitignore` for firmware, build artifacts, and logs containing sensitive device information.

## Documentation Requirements

For each significant operation, document:

- Date and time
- Device model
- Firmware version
- Commands executed
- Expected result
- Actual result
- Errors encountered
- Recovery or rollback procedure

Keep project documentation current as the device configuration changes.

## Success Criteria

### Phase 1

- Device identified.
- Bootloader status established.
- Bootloader successfully unlocked if supported.
- Recovery procedure documented.

### Phase 2

- Root access obtained.
- Root verified.
- Android remains functional.
- Stock restoration procedure available.

### Phase 3

- Compatible Linux boot strategy identified.
- Linux kernel boots successfully.
- Root filesystem mounts.
- Shell access works.
- Essential hardware functions operate.
- Persistent installation is validated when feasible.

## Initial Task

Begin by inspecting the macOS development environment with `scripts/android-tool.sh env`. It downloads Platform-Tools into `tools/` if they are missing.

Next, identify the connected Android device with `scripts/android-tool.sh discover`, which creates its device profile.

Do not attempt to unlock, root, or flash the device until the exact hardware model and firmware have been identified.

Proceed incrementally and request terminal output when necessary.
