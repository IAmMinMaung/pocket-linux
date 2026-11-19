# Bootloader Status

Recorded 2026-11-13 from `scripts/android-tool.sh discover` (regenerate with `scripts/android-tool.sh discover`, output `profiles/device-profile.md`).

| Item | Value |
|------|-------|
| Device | OnePlus 13 (一加 13), model PJZ110, codename OP5D0DL1, platform `sun` (Qualcomm) |
| Build | PJZ110_16.0.5.703(CN01), OTA PJZ110_11.C.88_1880_202604101200, Android 16, patch 2026-03-01 |
| `ro.boot.flash.locked` | 0 (unlocked) |
| `ro.boot.verifiedbootstate` | orange (unlocked, unsigned boot allowed) |
| `ro.boot.vbmeta.device_state` | unlocked |
| Active slot | `_a` (A/B, dynamic partitions) |
| Partitions of interest | boot_a/b, init_boot_a/b, recovery_a/b, vbmeta_a/b, vbmeta_system_a/b, vbmeta_vendor_a/b |
| Developer options | enabled |
| USB debugging | enabled, this Mac authorized |
| Root | Magisk 31.1, flashed 2026-11-18 to init_boot (slot a) from `firmware/patched/Original-V.559d893-32cee1f-32dd63c-from-OTA-init_boot-magisk.img`; daemon confirmed via `magisk -v` |

The bootloader was already unlocked when this project started. The user unlocked it themselves beforehand (guided by ChatGPT) with the plain route: OEM unlocking toggle in Developer options, then `fastboot flashing unlock` (wipes the device). No Deep Testing (深度测试) app or OnePlus approval was involved on this PJZ110/C.88 unit, so a relocked phone can be unlocked again the same way as long as OEM unlocking is turned on first. (An earlier version of this note assumed Deep Testing; that was wrong.) If the device is ever relocked (`fastboot flashing lock`), only stock, unmodified partitions must be present or it will not boot.

## Recovery path

**Primary rollback:** `firmware/images/Original-PJZ110_16.0.5.703CN01-device-stock/Original-init_boot.img`
(the phone's own stock image, from the slot-b dump; `scripts/android-tool.sh restore init_boot` uses it).

Finding 2026-11-18: the phone's installed images (build date 2026-03-06 16:01 CST, bootimage
timestamp 1772784089631) are a later compile than the CDN full OTA of the same version string
(2026-03-03 22:45 CST, 1772549126267). Same content and sizes, different embedded timestamps, so
the OTA-derived images are functionally interchangeable but not byte-identical. Slot a and slot b
were byte-identical for every boot-chain partition except init_boot_a (now Magisk).

- Live dump of both slots taken 2026-11-18 after rooting: `firmware/images/Original-PJZ110_16.0.5.703CN01-20261118-002544/` (SHA256SUMS). The active slot's init_boot in that dump is the Magisk-patched image, not stock.

- Stock OTA: `firmware/images/PJZ110_16.0.5.703_CN01_C88.zip`, MD5 `2cc8031b2589dd4e80bd3c93326c7c7e`, fetched by `scripts/download-stock-ota.sh`.
- Stock images extracted 2026-11-18 to `firmware/images/Original-V.559d893-32cee1f-32dd63c-from-OTA/` (Original-init_boot/boot/vendor_boot/dtbo/recovery/vbmeta*.img, SHA256SUMS verified; OTA MD5 and post-build fingerprint matched the phone).
- Roll back a bad root: `scripts/android-tool.sh restore init_boot`.

## 2026-11-19: relocked

Revert sequence (all serial-gated, `scripts/omarchy-install-slot-b.sh`): `revert-stock` flashed `Original-boot.img` -> boot_b and `Original-init_boot.img` -> init_boot_a from `firmware/images/Original-PJZ110_16.0.5.703CN01-device-stock/` (sha256 26710a8e… / 80e373ee…; init_boot matches the hash descriptor in vbmeta, boot's footer is signed with the key vbmeta chains to), `set_active a`, reboot; stock recovery "Format data"; Android booted stock (fingerprint release-keys, no Magisk). Then `lock`: `fastboot flashing lock` OKAY, confirmed on the phone, data wiped again. Result over adb: `ro.boot.flash.locked=1`, `ro.boot.verifiedbootstate=green`, `ro.boot.vbmeta.device_state=locked`, slot `_a`, build PJZ110_16.0.5.703(CN01). Before the writes every boot-chain partition on both slots was hashed from Ubuntu: only init_boot_a and boot_b differed from stock.

To unlock again: Developer options > OEM unlocking ON, then `scripts/android-tool.sh unlock`.

## Pre-unlock check (added 2026-11-19)

`scripts/android-tool.sh unlock` now runs a pre-flight before it reboots the phone:

1. Over adb: `settings get global development_settings_enabled` and `adb_enabled` must both be 1.
2. `getprop sys.oem_unlock_allowed`: 1 passes, 0 aborts. On this PJZ110 the property is empty (OnePlus keeps the toggle in the persistent data block), so the tool cannot read it and asks for a y/N confirmation of a three-item checklist: OEM unlocking ON, USB 2.0 cable/hub connected, phone backed up.
3. In fastboot: `fastboot getvar unlocked` (stops if already yes), then `fastboot flashing get_unlock_ability`. A value of 0 aborts with instructions to reboot to Android and enable the toggle; only 1 continues to the serial-gated `fastboot flashing unlock`.

Verified on 2026-11-19 with the phone in Android (`--dry-run`): developer options 1, USB debugging 1, OEM property not exposed, checklist shown. Real unlock still pending.

