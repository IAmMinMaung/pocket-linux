# Firmware and ROM Sources — OnePlus 13 PJZ110 (CN)

Researched 2026-11-14. Device: OnePlus 13, model PJZ110, codename OP5D0DL1,
LineageOS codename `dodge`. Installed: ColorOS PJZ110_16.0.5.703(CN01) C.88.
Official MD5 of that full OTA zip (from the phone's own OTA check):
`2cc8031b2589dd4e80bd3c93326c7c7e`, 8,769,806,346 bytes.

> **Anti-rollback:** the daxiaamu mirror flags C.88 as containing ARB. Do not
> flash boot-chain images from any build older than C.88.

## 1. The phone itself (done 2026-11-18, after rooting)

`scripts/android-tool.sh backup` dumped both slots with root into
`firmware/images/Original-PJZ110_16.0.5.703CN01-20261118-002544/`; the slot-b
set is copied to `Original-PJZ110_16.0.5.703CN01-device-stock/` and is the
primary rollback. Note the phone's compile (2026-03-06) is newer than the CDN
full OTA's (2026-03-03) for the same version string.

## 2. OnePlus/OPPO OTA CDN (official, link expires, unreliable from here)

`scripts/download-stock-ota.sh` holds a signed `component-ota-cn.allawntech.com`
link that redirects to `allawnfs.com`. The server resets connections every
few hundred MB; two attempts failed. Fresh links appear only when the phone
checks for updates. Treat as the authoritative source for the MD5, not as a
practical download path.

## 3. daxiaamu mirror — 欧加真ROM下载站 (community, has C.88)

https://yun.daxiaamu.com/OnePlus_Roms/一加OnePlus%2013/
Lists every PJZ110 ColorOS 15/16/17 full package including
`ColorOS PJZ110_16.0.5.703(CN01) C.88`. Files are on Quark (夸克) and Baidu
netdisks (Baidu code `dxam`), so a netdisk client/account is needed. Six
years old, well known in the OnePlus CN community. **Verify any download
against the official MD5 above before use.**

## 4. spike0en/oneplus_archive (GitHub, extracted images with SHA-256)

https://github.com/spike0en/oneplus_archive/releases
Automated extraction of official OTAs into `boot.7z` (boot, init_boot,
vbmeta, dtbo…), `firmware.7z`, `logical.7z`, each with a `.sha256`. PJZ110
coverage stops at 16.0.1.303(CN01) as of today; no C.88 yet. Useful if the
phone is ever on a build they carry.

## 5. LineageOS (official custom ROM, PJZ110 explicitly supported)

- Wiki: https://wiki.lineageos.org/devices/dodge/ (models: CPH2649, CPH2653, CPH2655, PJZ110)
- Builds + SHA-256: https://download.lineageos.org/devices/dodge/builds
- Current branch 24.0 (Android 16), nightlies. Install method `fastboot_nexus`:
  flash boot, dtbo, init_boot, vbmeta, vendor_boot from the build, then
  recovery, then sideload the zip. Firmware requirement: `firmware_update_oplus_sm8750`.
- The LineageOS recovery was downloaded and tried for a temporary boot on
  2026-11-17; it does not boot on stock firmware (see `docs/rooting.md`,
  step 4) and the folder was deleted at the user's request.

## 6. Others seen, lower trust

- XDA "Repository of OxygenOS & ColorOS FULL OTAs" thread (needs browser; uses an OTA-downloader to mint fresh links).
- DroidWin, firmwarefile.com (QFIL/EDL packages for 16.0.5.701), roms.danielspringer.at (EDL/PJZ110). No checksums verified.

## 7. Saved reference: XDA "[CLOSED] [PJZ110] ColorOS to OxygenOS" (koaaN)

XDA thread by koaaN, "[CLOSED] [PJZ110] ColorOS to OxygenOS" (xdaforums.com; the SourceForge flasher page
sourceforge.net/projects/oneplus13-pjz110/ links it as thread 4707431). A printed PDF copy was kept in docs/ until
2026-11-19 and removed before publishing (third-party content). Conversion flasher for PJZ110 → OxygenOS GLO/EU/IN/NA;
closed 2026-10-28, flashers no longer provided. Not a source of stock ColorOS
images. Useful parts: the root method (patch `init_boot` with Magisk or
KernelSU, `fastboot flash init_boot`), the rooted-OTA procedure (Local
Install → root app "Install to inactive slot" → reboot), and the fastbootd
check (`fastboot reboot fastboot`). Warnings: rooted phones must not relock;
unsigned dtbo + locked bootloader bricks; a linked thread reports permanent
ARB fuse on ColorOS 16.0.3.501 and 16.0.8.x. Do not attempt the OxygenOS
conversion from C.88 without a confirmed report from that exact build.
