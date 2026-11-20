# OnePlus 13 (PJZ110) — back to stock Android, bootloader locked: copy-paste runbook

This undoes everything in `docs/ONEPLUS13-step-by-step.md`: native Ubuntu on slot b, Magisk on init_boot_a, and
the unlocked bootloader. It was run, in this order, on 2026-11-19 and again on 2026-11-20 on a OnePlus 13 PJZ110
(ColorOS 16.0.5.703 CN01, build C.88) from an Apple-Silicon Mac. Commands marked **(you type)** need a real Terminal
window because they ask for the phone's serial number or a confirmation. Everything else can be pasted as is.

Time: about 30 min, most of it the two data wipes and the Android setup wizard.

The whole thing wipes the phone twice (stock recovery formats data, then the lock wipes again). Nothing on the phone
survives: the Ubuntu root filesystem on userdata is gone after step 3.

---

## 0. Before you start

- A **USB 2.0** connection to the Mac (OnePlus charging cable through a USB 2 hub). The bootloader is invisible over USB 3.
- Never press **Volume Up + Volume Down** together on a powered OnePlus 13: that is EDL mode. Fastboot from off is Power + Volume Down.
- Only a phone whose other partitions were never written can be locked again. This project wrote exactly three things:
  `init_boot_a` (Magisk), `boot_b` (Linux chain image) and `userdata` (ext4 root). If anything else was ever flashed,
  stop at step 3 and do not lock.
- You need the phone's **own** stock images, dumped after rooting (Phase 2 of the install runbook). The CDN OTA images
  are a different compile and fail the vbmeta check. The dump lives in `firmware/images/Original-*-device-stock/` and
  `profiles/device-profile.env` points to it as `STOCK_DIR`.

Check that the inputs are in place. Every line must print `OK` or `ok`:

```bash
cd ~/Projects/Root-Android          # or wherever you cloned it
ST=$(awk -F= '$1=="STOCK_DIR"{print $2}' profiles/device-profile.env); echo "stock set: $ST"
(cd "$ST" && shasum -a 256 -c SHA256SUMS | grep -E 'Original-(boot|init_boot|vbmeta)\.img')
python3 -I scripts/avb-verify.py "$ST/Original-vbmeta.img" "$ST/Original-boot.img" "$ST/Original-init_boot.img"
ls firmware/images/Original-*/gpt/sde-head.bin      # the GPT backup the install script insists on
```

`avb-verify.py` proves that `Original-init_boot.img` matches the hash descriptor in the phone's vbmeta and that
`Original-boot.img` carries a footer signed with the key vbmeta chains to. A locked bootloader accepts exactly those
bytes and nothing else. If either line fails, do not continue.

---

## 1. Put the phone in fastboot

**If Ubuntu is running on slot b** (SSH over Wi-Fi, or over USB with `ssh -6 YOUR_USER@'fe80::…%en13'`), reboot it into
the bootloader. `systemctl reboot bootloader` is rejected by this systemd, so set the reboot parameter directly:

```bash
ssh -i keys/omarchy-dodge_ed25519 YOUR_USER@PHONE-IP 'sudo sh -c "echo bootloader > /run/systemd/reboot-param" && sudo systemctl reboot'
```

**If Android is running** (slot a, rooted or not): `tools/platform-tools/adb reboot bootloader`.

**If nothing boots**: power off, then hold Power + Volume Down.

Then confirm the Mac sees it over the USB 2.0 hub:

```bash
FB=tools/platform-tools/fastboot
$FB devices                                   # one line: <serial>  fastboot
for v in current-slot unlocked slot-successful:a slot-successful:b; do $FB getvar $v 2>&1 | head -1; done
```

Expected after a slot-b Linux install: `current-slot: b`, `unlocked: yes`, `slot-successful:a: yes`.

---

## 2. Flash the stock images and switch to slot a

**(you type)** The script re-runs the checks from step 0, then asks for the serial four times: stock `boot_b`, stock
`init_boot_a`, `set_active a`, reboot. Each fastboot write must print `Writing '<partition>' OKAY` or the script stops.

```bash
scripts/omarchy-install-slot-b.sh revert-stock
```

What it changes on the phone:

| Write | From | Effect |
|---|---|---|
| `boot_b` ← `Original-boot.img` | the phone's own dump | the Linux chain image is gone |
| `init_boot_a` ← `Original-init_boot.img` | the phone's own dump | Magisk is gone |
| `set_active a` | | stock Android slot boots next |

---

## 3. Let stock recovery format data, set Android up

The phone reboots into slot a, finds an ext4 filesystem on userdata and stops in stock recovery. Choose **Format data /
wipe** and confirm. Android boots into the setup wizard; finish it (skip accounts).

Then on the phone: Settings → About device → Version → tap **Build number** 7 times. Settings → Additional settings →
Developer options → turn on **USB debugging** and **OEM unlocking**. Accept the Mac when prompted.

OEM unlocking must be ON before you lock, or the phone cannot be unlocked again later.

Verify stock Android before locking. While `adb shell` says `error: closed`, USB debugging is not on yet.

```bash
ADB=tools/platform-tools/adb
$ADB shell 'getprop ro.boot.slot_suffix; getprop ro.build.tags; getprop ro.build.display.id; getprop ro.boot.verifiedbootstate; which su magisk; echo end'
```

Expected: `_a`, `release-keys`, build `PJZ110_16.0.5.703(CN01)`, `orange` (still unlocked), no path printed by `which`.

---

## 4. Lock the bootloader

**(you type)** The script reboots the phone to fastboot, re-runs the checks, asks for the serial, then `fastboot flashing lock`.
Confirm on the phone with the volume keys and Power. Data is wiped again.

```bash
scripts/omarchy-install-slot-b.sh lock
```

The phone reboots into the setup wizard once more. Finish it, re-enable Developer options and USB debugging, then:

```bash
scripts/android-tool.sh discover
grep -E 'FLASH_LOCKED|VERIFIEDBOOT|SLOT' profiles/device-profile.env
```

Expected: `RO_BOOT_FLASH_LOCKED=1`, `green`, slot `_a`. The phone is stock C.88, locked, unrooted.

---

## Partial undos (no relock)

- **Back to Android but keep Linux on slot b**: `scripts/omarchy-install-slot-b.sh back-to-android` (`set_active a` +
  reboot; Android still needs the Format-data step because userdata is ext4). Return with `fastboot set_active b` later.
- **Remove root only, stay unlocked**: `scripts/android-tool.sh restore init_boot` (flashes the stock init_boot).
- **Unlock again after this runbook**: OEM unlocking ON, then `scripts/android-tool.sh unlock` (Phase 1 of the install runbook).

## If something goes wrong

- `fastboot never saw <serial>`: the phone is on a USB 3 port. Move to the USB 2.0 hub.
- `stock images fail the AVB check`: the stock set is not this phone's own dump. Do not flash it, do not lock. Dump the
  inactive slot from a rooted Android (`scripts/android-tool.sh backup`) and point `STOCK_DIR` at it.
- `fastboot flash <part> FAILED`: nothing was written for that partition. Fix the cause (cable, image path) and rerun
  `revert-stock`; the writes are idempotent.
- Phone loops into recovery after step 2: choose Format data; the loop is the ext4 userdata, not a bad image.
- Locked and does not boot: the phone has a non-stock partition. Unlock is impossible when it does not reach Android
  with OEM unlocking on; recovery then needs OPPO's MSM/EDL tool. This is why step 0 insists on the AVB check.

## Where things are

| What | Where |
|---|---|
| Log of every write | `logs/install-slot-b.log` |
| Device profile (serial, lock state, stock dir) | `profiles/device-profile.env` |
| The phone's own stock images | `firmware/images/Original-*-device-stock/` (gitignored) |
| Recorded revert/relock history | `docs/bootloader.md` |
| The install runbook this undoes | `docs/ONEPLUS13-step-by-step.md` |
