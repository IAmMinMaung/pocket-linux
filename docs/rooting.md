# Rooting the OnePlus 13 (PJZ110) — Step by Step

Device state when written (2026-11-13, regenerate with `scripts/android-tool.sh discover`, output `profiles/device-profile.md`):
Developer options ON, USB debugging ON, bootloader UNLOCKED, Android 16 /
ColorOS 16.0.5.703(CN01), `init_boot` partition present, not rooted.

Steps 1–2 are already complete on this phone. They are kept here so the
procedure is whole if the device is ever factory reset.

All commands run from the project root on the Mac. The tool downloads
adb/fastboot into `tools/` by itself.

---

## Step 1 — Enable Developer options and USB debugging  (done)

On the phone (ColorOS 16, English UI; Chinese UI in brackets):

1. Settings › About device › Version  (设置 › 关于本机 › 版本信息)
2. Tap **Build number** (版本号) seven times. Enter the lock-screen PIN when asked. "You are now a developer" appears.
3. Settings › Additional settings › Developer options  (设置 › 其他设置 › 开发者选项)
4. Turn on **USB debugging** (USB 调试).
5. Connect to the Mac with a data cable. On the phone tap **Allow** on the "Allow USB debugging?" prompt, tick *Always allow from this computer*.
6. Confirm on the Mac:

   ```bash
   scripts/android-tool.sh env
   ```

   The last line must read `Device state: device`. `unauthorized` means step 5 was not accepted.

## Step 2 — OEM unlocking and bootloader unlock  (done)

The phone already reports `ro.boot.flash.locked=0` and verified-boot state
`orange`. Nothing to do. For the record, on a locked Chinese OnePlus:

1. Developer options › **OEM unlocking** (OEM 解锁) › turn on.
2. Install the OnePlus **Deep Testing** (深度测试) app, apply for unlock, wait for approval. `fastboot flashing get_unlock_ability` returns 0 until approved.
3. Back up everything. Unlocking wipes the phone.
4. `scripts/android-tool.sh unlock` — it reboots to fastboot, checks unlock ability, then asks for the serial before running `fastboot flashing unlock`. Confirm on the phone with the volume keys.
5. First boot after unlock shows an orange-state warning for a few seconds. That is permanent and expected.

## Step 3 — Confirm the device profile

```bash
scripts/android-tool.sh discover
```

Check the printed lines:

- `RO_BUILD_DISPLAY_ID=PJZ110_16.0.5.703(CN01)` — must equal the firmware you will extract in step 4.
- `RO_BOOT_FLASH_LOCKED=0`
- `HAS_INIT_BOOT=yes` — Magisk must patch **init_boot.img**, never boot.img, on this device.
- `RO_BOOT_SLOT_SUFFIX=_a` — the active slot. `fastboot flash init_boot` writes to the active slot.

## Step 4 — Get the original images  (required before any flash)

**Tried and failed on this phone (2026-11-17):** temporarily booting a
recovery with `fastboot boot` to dump the partitions. Findings, so nobody
repeats them: the bootloader only shows up over USB 2.0 (use the OnePlus
charging cable or a USB 2 hub); it rejects images with no kernel ("Bad
Buffer Size"); the LineageOS recovery is ramdisk-only; and a LineageOS kernel
plus that ramdisk boots but immediately falls back to stock Android because
it needs LineageOS's own dtbo/vendor_boot. Nothing was written to the phone.

**What works:** the full stock OTA for the exact installed build, from
`docs/firmware-sources.md`. For C.88 it is on the daxiaamu mirror:

- Quark: https://pan.quark.cn/s/d099e0daee7f
- Baidu: https://pan.baidu.com/s/1_H4Ty-M0CNmYWL7bT-3UIw?pwd=dxam  (code `dxam`)

Save the zip anywhere under `firmware/images/`, then:

```bash
EXPECTED_OTA_MD5=2cc8031b2589dd4e80bd3c93326c7c7e scripts/android-tool.sh extract-boot firmware/images/<file>.zip
```

The MD5 is the official one from the phone's own OTA check; a mismatch stops
the run. `extract-boot` also checks `pre-device` and the full `post-build`
fingerprint against the device profile, then writes
`firmware/images/Original-<build>-from-OTA/Original-init_boot.img`, `Original-boot.img`,
`Original-vendor_boot.img`, `Original-dtbo.img`, `Original-recovery.img`,
`Original-vbmeta*.img` with `SHA256SUMS`. These are the same software as what is on the phone, but **not byte-identical**:
the CDN package is a 2026-03-03 compile and the phone carries a 2026-03-06
compile of the same version (see `docs/bootloader.md`). The phone's own
images were dumped after rooting and are the primary rollback.

## Step 4c — (Reference) what extract-boot does

Root needs the stock `init_boot.img` from the *exact* installed build.

```bash
scripts/download-stock-ota.sh            # ~8.4 GB, chunked, resumable, verifies MD5 2cc8031b2589dd4e80bd3c93326c7c7e
scripts/android-tool.sh extract-boot firmware/PJZ110_16.0.5.703_CN01_C88.zip
```

`extract-boot` checks the zip's `pre-device` against the profile, unpacks
`payload.bin` with `payload-dumper-go`, and leaves
`firmware/stock/<build>/init_boot.img`, `boot.img`, `vbmeta*.img`,
`recovery.img`. It prints *"init_boot.img present: patch THIS with Magisk."*

If the download fails with a tiny JSON file containing `responseCode 2306`,
the vendor link expired. Trigger *Settings › About device › Check for
updates* on the phone to get a fresh link and update the URL and MD5 in
`scripts/download-stock-ota.sh` together.

## Step 4d — Verify fastboot and fastbootd before any flash

The XDA PJZ110 guide insists on this and so do we. With the phone on the
**charging cable through the dock** (USB 2.0; the bootloader is invisible over
the USB-C data cable):

```bash
scripts/android-tool.sh reboot bootloader && tools/platform-tools/fastboot devices   # bootloader
scripts/android-tool.sh reboot fastbootd  && tools/platform-tools/fastboot devices   # userspace fastboot, tap English on the phone
scripts/android-tool.sh reboot system
```

Both must list serial `7359ee91`. Do not flash if either fails.

## Step 5 — Install the Magisk app on the phone  (done)

`com.topjohnwu.magisk` is already installed on this phone. Open it once and
check *Installed: N/A* (expected before rooting) and that the app version is
current. To install or update on a fresh device:

1. `scripts/fetch-inputs.sh` downloads `tools/apk/Magisk-v31.1.apk` from the official GitHub release and checks its
   sha256 (recorded in `checksums/inputs.sha256`; see `DOWNLOADS.md`).
2. `tools/platform-tools/adb install tools/apk/Magisk-v31.1.apk`

## Step 6 — Patch and flash with the tool

```bash
scripts/android-tool.sh root
```

The tool walks through the following and stops at each prompt:

1. Pushes `firmware/images/Original-<build>-from-OTA/Original-init_boot.img` to `Download/init_boot.img` on the phone.
2. **On the phone:** Magisk › Install › *Select and Patch a File* › choose `Download/init_boot.img` › *Let's go*. Wait for *All done!*. Press Enter on the Mac.
3. Pulls `magisk_patched-*.img` back to `firmware/patched/<build>-init_boot-magisk.img`.
4. Asks `y/N` to reboot into fastboot.
5. Shows the HIGH RISK banner for `fastboot flash init_boot …`. Type the serial `7359ee91` exactly to proceed. Nothing is written until then. init_boot cannot be temp-booted, so there is no trial run; the stock image from step 4 is the rollback.
6. Asks `y/N` to reboot to Android.

First boot after flashing takes longer than usual. Do not interrupt it.

## Step 7 — Verify root

Done 2026-11-18: `adb shell magisk -v` → `31.1:MAGISK:R`. If `su -c id` from adb says *Permission denied*, open Magisk › Settings › Superuser Access and set *Apps and ADB*, then approve the prompt that appears when the command is rerun.

```bash
tools/platform-tools/adb shell su -c id
```

Approve the Superuser prompt that appears on the phone. Expected output
begins with `uid=0(root)`. Magisk should now show *Installed: <version>*.
Then rerun `scripts/android-tool.sh discover`; it records `ROOTED=yes`.

Optionally back up the now-readable partitions:

```bash
scripts/android-tool.sh backup       # dumps every boot-chain partition on both slots to firmware/images/Original-<build>-<timestamp>/
```

## If it goes wrong

| Symptom | Action |
|---------|--------|
| Phone loops on the OnePlus logo or lands in fastboot | `scripts/android-tool.sh restore init_boot` flashes the phone's own stock `Original-init_boot.img` (from `firmware/images/Original-PJZ110_16.0.5.703CN01-device-stock/`) back, then reboot. |
| Phone boots but Magisk says N/A | The wrong image was patched or the wrong slot was flashed. Re-run step 3 to confirm `HAS_INIT_BOOT` and the active slot, then step 6. |
| `adb shell su` says *not found* | Magisk is not active; same as above. |
| Phone is stuck and will not enter fastboot | Hold Power + Volume Up and Volume Down for 10 s, then Power + Volume Down for fastboot. |

## After rooting

- **Taking an OTA while keeping root** (method from the XDA PJZ110 guide): download the full OTA, Settings › Software Update › three-dot menu › Local Install, let it finish but do **not** tap Restart. Open Magisk (or KernelSU) › Install › *Install to inactive slot*, accept the warning, do not reboot from the app. Go back to the updater and tap Restart. The new system boots already rooted. If this is skipped, the OTA removes root and step 6 must be repeated with the new build's `init_boot`.
- Do not relock the bootloader while any partition is modified.
- Banking and payment apps may refuse to run; Magisk's *Zygisk* + *DenyList* can hide root from selected apps.

## 2026-11-19 redo: Phase 2 done again

Sequence on the freshly re-unlocked phone (see `docs/bootloader.md`): `extract-boot` on the MD5-verified C.88 OTA
(`firmware/images/Original-V.559d893-32cee1f-32dd63c-from-OTA/`, build matches the phone's incremental), Magisk v31.1 APK
fetched by `scripts/fetch-inputs.sh` (sha256 and signer CN=John Wu verified) and installed with `adb install`, then
`scripts/android-tool.sh root` run by the user. First attempt stopped at "No magisk_patched-*.img found" because Enter was
pressed before patching in the app; second run pulled `Download/magisk_patched-31100_LEPx9.img`, rebooted to fastboot
(USB 2.0 hub), `fastboot flash init_boot` → "Writing 'init_boot' OKAY" (the preceding "Fetching super … unknown command"
line is a harmless fastboot pre-check this bootloader lacks), reboot. `magisk -v` → 31.1:MAGISK:R.

`su -c id` was denied instantly (0 s, no prompt) three times; the Superuser tab listed a **Shell** entry switched off.
Turning it on fixed it: `uid=0(root) gid=0(root) context=u:r:magisk:s0`. ColorOS pop-up permissions were not the cause.

`backup` then dumped both slots over su to `firmware/images/Original-PJZ110_16.0.5.703CN01-20261119-181020/`. Checks:
init_boot_a is byte-identical to the Magisk image; every other partition is identical on slots a and b. Slot b was copied to
`firmware/images/Original-PJZ110_16.0.5.703CN01-device-stock/` and `STOCK_DIR` points there, so `restore init_boot` flashes
the phone's own stock. `scripts/avb-verify.py` (new, stdlib replacement for the deleted `tools/avb/check-stock-avb.py`)
confirms that set against the phone's vbmeta: init_boot/vendor_boot hash descriptors match, boot/dtbo/recovery footers match
and carry the chained key. The patched init_boot fails the check (expected) and so does the CDN OTA's init_boot: it is a
different compile, so only the on-device dump is lock-safe.
