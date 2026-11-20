# Linux on the OnePlus 13 (PJZ110 / dodge) — status as of 2026-11-18

Phone: OnePlus 13 CN, Snapdragon 8 Elite (SM8750), Adreno 830, ColorOS 16 C.88, bootloader unlocked, Magisk 31.1 on slot a.

## Options, honestly ranked

| Option | What it is | State for this phone | Verdict |
|---|---|---|---|
| **Ubuntu Touch (UBports)** | Ubuntu-based phone OS on a Halium (Android-kernel) base | No port. Newest OnePlus devices are 6/6T and Nord N10/N100/Nord 2. Halium does not target android15-6.6 kernels. | Not available; porting is a multi-month project. |
| **Omarchy Mobile** | Arch Linux ARM + Hyprland + Omarchy on a *mainline* kernel; Android apps via Waydroid planned | Device port `dodge` merged 2026-10-31. Testing: boot, display, GPU, touch, Wi-Fi, BT, speakers, sensors, LTE data. Missing: cameras, charging control, haptics, GNSS, NFC, fingerprint; suspend WIP. Installs to the **inactive slot b**, Android stays on slot a. Dedicated installer for dodge not yet published ("install record, not a procedure"); bring-up was done on OxygenOS, needs the owner's own firmware/EFS. | The most advanced native-Linux path. Experimental, developer-only today. |
| **postmarketOS / Nura** | Alpine-based mobile Linux, mainline kernel | Wiki page `OnePlus_13_(oneplus-dodge)` exists: boots, screen/touch/USB-net/storage work, battery reports 0%, everything else untested. Not packaged, no official images. Maintainer index986. | Early bring-up; nothing to install yet. |
| **Ubuntu userspace on Android (proot/chroot)** | Full Ubuntu rootfs running under Android's kernel, with a desktop over VNC or Termux:X11 | Works today on any rooted or even unrooted phone. Not a native install; Android keeps running. | Available now, zero flashing risk. |

## Recommended Phase 3 path

1. **Now:** Ubuntu userspace via Termux + `proot-distro install ubuntu` (or a chroot with root). Gives apt, Python, dev tools, local AI inference on the 8 Elite. Document as "Linux userspace inside Android", not native Linux.
2. **Watch:** Omarchy Mobile `device/dodge` — wait for the guarded inactive-slot installer PR and a signed release bundle. Reuse its firmware A→B copy approach; it keeps vbmeta/EFS/NV untouched and respects ARB.
3. **Before any native attempt:** back up `persist`, `modem_a/b`, `efs`, `efs_backup`, `modem_userdata` with root (`backup` can be extended); confirm the port handles ColorOS CN firmware, not only OxygenOS.

## Hard constraints

- C.88 anti-rollback: never flash older firmware images.
- Early boot stays locked to OnePlus's signed bootloader chain; mainline Linux is chainloaded from `boot_b`, so the stock bootloader and firmware partitions remain.
- fastboot only over USB 2.0 on this Mac.

Sources: UBports device list devices.ubuntu-touch.io; Nura/postmarketOS wiki page for oneplus-dodge; github.com/derekross/omarchy-mobile PR #111 and linux-omarchy-mobile PR #115; linux-msm mainline status for SM8750.

## postmarketOS natively — what it would actually take (assessed 2026-11-18)

Nothing to install exists: `pmaports` has no `device-oneplus-dodge` package and no merge request; the wiki page is a
bring-up record by one developer. The building blocks do exist:

- Kernel: `github.com/sm8750-mainline/linux`, branch v6.16, has `sm8750-oneplus-dodge.dts` (model "OnePlus 13").
  Enabled there: display (DSI0), UFS storage, USB, PCIe0, I2C/SPI buses, remoteprocs for ADSP/CDSP/modem, power key.
  Absent/untested: Wi-Fi/BT, GPU, audio, cameras, GNSS, NFC, fingerprint, battery gauge. Last push 2025-09.
- Bootloader: `Project-Silicium/Mu-Silicium` (UEFI for ARM64 phones) has a `dodgePkg`; that is how the wiki boots
  mainline (stock ABL → UEFI image on `boot_b` → Linux). Active project, pushed 2026-11-17.
- Rootfs: pmbootstrap with a hand-written device package pointing at the kernel above.

Scope: a porting project, not an install. Phases: build Mu-Silicium for dodge; build the sm8750-mainline kernel with
the dodge DTS; write `device-oneplus-dodge` + `linux-postmarketos-sm8750` APKBUILDs; install to **slot b only**
(`boot_b` + a userdata/rootfs partition), keep Android on slot a; iterate on hardware. Expect a phone that shows a
desktop over USB networking with screen and touch, and no Wi-Fi, sound, camera, calls or battery readout at first.

Prerequisites before any native attempt (all reversible so far):
1. Root dump of the modem/persist partitions (`persist`, `modem_a/b`, `efs*`, `modem_userdata`) — extend `backup`.
2. A Linux build host (pmbootstrap and the UEFI build do not run on macOS natively; use Docker or a VM).
3. The slot-b write path through fastboot over the USB 2.0 cable; never touch vbmeta, ARB-relevant firmware, or slot a.

## Decision record 2026-11-18: user wants native Linux, phone features optional

Facts gathered (all read-only):
- All 41 A/B firmware pairs on this phone already match (only `init_boot` = Magisk and `splash` differ), so the
  firmware A→B copy the Omarchy developer needed does not apply.
- Full off-phone backup of every partition except `super`/`userdata` plus GPT head/tail of each LUN:
  `firmware/images/Original-PJZ110_16.0.5.703CN01-allfw-<ts>/` (SHA256SUMS). Includes modem, modemst, fsg, persist,
  oplus NV, abl/xbl/tz, all vbmeta.
- Mu-Silicium UEFI `dodgePkg` (state: Inactive): display, UFS, buttons, USB device mode, Linux boot ✅; USB host ❌.
  Linux under it (index986 sm8750-mainline): CPU, display, touch, UFS, USB device ✅; WLAN, BT, USB host, GPU, audio,
  battery ❌. No prebuilt dodge images; must be built (Linux, ~5 GB source).
- Omarchy Mobile (derekross) kernel for dodge: display, GPU, touch, Wi-Fi (ath12k), BT, speakers, sensors, LTE data,
  USB networking in testing; cameras/GNSS/NFC/fingerprint/charging ❌. Boots via a two-stage `qcom-abl` chain on
  `boot_b` because this ABL refuses header-v2 images under `fastboot boot`. Rootfs on `userdata`. Installer for dodge
  not published; GPT bit 54 set by hand after first clean boot; `set_active` may undo it.
- Docker Desktop works on the Mac (14 cores, arm64 containers OK; raise its memory above 8 GB for kernel builds).

Options:
A. **postmarketOS via Mu-Silicium UEFI + index986 kernel** — the wiki route. Pure pmOS, but no Wi-Fi, no USB host,
   network only via USB to the Mac. Everything must be built; no device package exists.
B. **Omarchy Mobile as-is (Arch Linux)** — the only proven usable Linux on this phone (Wi-Fi works). Hand install
   following BRINGUP-M1, including the GPT bit-54 edit. Not postmarketOS.
C. **Hybrid: Mu-Silicium UEFI on boot_b + Omarchy kernel + rootfs of choice (pmOS/Debian/Ubuntu/Arch)** — cleanest
   architecture (standard EFI boot, no chain hack), Wi-Fi from the Omarchy kernel, but an untested combination.

Common to all: slot b boot image, Android stays on slot a, `userdata` reformatted for Linux (Android data wiped;
Android boots again after `fastboot --set-active=a` + factory reset). Never touch vbmeta, xbl/abl/tz, modem/EFS.

### Chosen 2026-11-18: route B/C — Omarchy Mobile kernel on slot b; data wipe accepted; builds on the phone

Omarchy facts for dodge (from device/dodge/BRINGUP-M1.md and NOTES.md):
- Kernel: fork `mrlund/linux-omarchy-mobile` tag `dodge-v3-20261101` (6cc4b65df980) on the `omamobile` base
  (mainline 7.3-rc lineage). DTB `qcom/sm8750-oneplus-dodge.dtb`. PR #115 was closed unmerged; the tag is the source of truth.
- This ABL refuses header-v2 under `fastboot boot`, boots header-v4 but keeps stock DTB from `vendor_boot` and ignores
  the uploaded ramdisk. Their answer: a kernel-only v4 image whose built-in `/omamobile/init` (CMDLINE_FORCE
  `rdinit=/omamobile/init`) kexecs stage 2 (real Image + dodge DTB + initramfs). `tools/dodge-chain` packs it.
- device.conf: `BOOT_METHOD=qcom-abl`, `OMAMOBILE_SLOT=b`, `UFS_RW="boot_b userdata"`, panel 1440x3168,
  cmdline `clk_ignore_unused pd_ignore_unused panic=10 console=tty0`. `boot_b`=sde48, `userdata`=sda15, 4096-byte sectors.
- Their flash/push/fastboot tools refuse dodge; install was by hand. GPT bit 54 (slot successful) set by hand on boot_b.
- Alternative for stage 1 (untested here): Mu-Silicium UEFI `dodgePkg` as the thing on `boot_b`, booting the Omarchy
  kernel as an EFI stub, which removes the chainload hack.

Our phone differs favourably: all A/B firmware pairs already match (no A→B copy needed).
Full firmware backup folder: `firmware/images/Original-PJZ110_16.0.5.703CN01-allfw-20261118-005146/`
(note: the first pass included raw LUN pseudo-partitions `sda..sdf` and the phone rebooted mid-dump; re-dumped
without them and with GPT head/tail per LUN).

Build host: the phone's Ubuntu chroot (user's choice) — artifacts must be copied to the Mac before userdata is wiped.

### Build log 2026-11-18 (Phase 3, Omarchy kernel chain, built on the phone)

Inputs staged in the Ubuntu chroot (`/root/src`, `/root/dl`): kernel `mrlund/linux-omarchy-mobile` tag
`dodge-v3-20261101` (7.3.0-rc6, pushed from the Mac; GitHub is very slow from the phone), `derekross/omarchy-mobile`,
AOSP `mkbootimg`, Alpine 3.24.2 minirootfs + apks (busybox-static, kexec-tools, dropbear, e2fsprogs), the live FDT
dumped from Android (`/sys/firmware/fdt`), and the project SSH public key.

Driver: `scripts/omarchy-build-phone.sh stage2 | initramfs | chain | pull | status`. Steps run detached inside the
chroot, logs in `/root/build-*.log`.
- stage2 kernel config = `defconfig` + `kernel/configs/omamobile.config` + `arch/arm64/configs/sm8750.config`
  (the dodge fragment lives in the kernel tree, not in device/dodge/). Verified in .config: PINCTRL_SM8750,
  SCSI_UFS_QCOM, DRM_SIMPLEDRM, USB_CONFIGFS_NCM/ACM, SM_GPUCC_8750 =y; LOCALVERSION -omamobile-push1.
- stage2 initramfs (6.6 MB, `initramfs.cpio.lz4`): Alpine base + dropbear/kexec/e2fsprogs + Omarchy shared `init`
  + `/etc/omamobile-ufs-rw` "boot_b userdata", `/etc/omamobile-ufs-rw-slot` "running", `/etc/omamobile-usb-product`
  "OnePlus 13", `/root/.ssh/authorized_keys` = `keys/omarchy-dodge_ed25519.pub`.
- chain: `tools/dodge-chain pack` with STAGE2_CMDLINE including `omamobile.initramfs` (stay in the initramfs; no
  root handoff) and `omamobile.ufs-probe`; `SLOT_SUFFIX=_b`. Output `chain/images/boot-chain.img` (header v4,
  kernel-only).

First-light test (RAM only, nothing flashed): phone on the USB 2.0 cable → `adb reboot bootloader` →
`fastboot boot boot-chain.img`. Expected: stage 1 kexecs stage 2 within seconds; screen shows the simpledrm console
with `omamobile:` status lines; the Mac sees a new CDC-NCM Ethernet interface plus an ACM serial port
(`/dev/cu.usbmodem*`, getty on ttyGS0). Give the Mac interface 172.16.42.2/24, then
`ssh -i keys/omarchy-dodge_ed25519 root@172.16.42.1`. Failure modes: stays in fastboot (ABL refused the image),
black screen and reboot to Android (stage 2 crashed), or Android logo (chain fell through). None of these write
anything. Hold Power 10 s to recover if the phone hangs.

Results 2026-11-18: stage-2 kernel built on the phone in ~70 min of CPU time (two interruptions: 13 case-collided
netfilter files lost by cloning on the Mac's case-insensitive filesystem, restored with `git checkout`; and a chroot
mount-table explosion, see `docs/ubuntu-userspace.md`). Release `7.3.0-rc6-omamobile-push1-g6cc4b65df980`, Image
43,395,584 bytes, dodge DTB 127,645 bytes, initramfs 6,575,913 bytes; copies with SHA256SUMS in
`firmware/images/omarchy-dodge-stage2-<ts>/`. Chain pack started (stage-2 DTB with live memory map, stage-1 kernel).
Lesson: never clone the Linux tree on macOS; clone on a case-sensitive filesystem or on the phone, or restore with git.

### FIRST LIGHT — 2026-11-18 02:51 (RAM only, nothing flashed)

`fastboot boot firmware/images/omarchy-dodge-chain-20261118-025010/boot-chain.img` (sha256 ca5d76b3…6eaca):
"Booting OKAY" in 1.8 s; 28 s later the phone enumerated on the Mac as USB "Omarchy Mobile / OnePlus 13 / omamobile"
with CDC-NCM (AppleUSBNCMControl) + ACM (`/dev/cu.usbmodemomamobile3`). Over the serial console:
`Linux omamobile 7.3.0-rc6-omamobile-push1-g6cc4b65df980 … aarch64`, model "OnePlus 13", cmdline carried
`androidboot.slot_suffix=_b omamobile.slot_src=packed` (stage 1 forwarded it), `usb0` 172.16.42.1/24, UDC
`a600000.usb` configured, ufs-probe saw 6 disks / 139 partitions and the storage guard set every partition read-only
(userdata on sda15 writable only by allowlist). Mainline Linux runs natively on this phone.
Log: `logs/first-light-20261118-025049.log`. Serial console: `screen /dev/cu.usbmodemomamobile3 115200` (root shell, no login).
Mac-side network: assign 172.16.42.2/24 to the NCM interface (`sudo ifconfig <en> 172.16.42.2 netmask 255.255.255.0 up`),
then `ssh -i keys/omarchy-dodge_ed25519 root@172.16.42.1`.

### Install phase plan (decided 2026-11-18: Ubuntu 24.04 root, step-by-step, confirm each write)

Artifacts: `firmware/images/omarchy-dodge-chain-*/boot-chain-install.img` (sha256 8de58471…56dad; stage-2 cmdline
`rdinit=/init clk_ignore_unused pd_ignore_unused panic=10 console=tty0`, i.e. hands over to the root on userdata);
rootfs image `/root/out/rootfs-ubuntu-noble-dodge.img` built by `scripts/omarchy-build-phone.sh rootfs` (Ubuntu Base +
systemd, NetworkManager, wpasupplicant, openssh, sudo, gdisk, linux-firmware, kernel modules
7.3.0-rc6-omamobile-push1-g6cc4b65df980, user `min`/`oneplus13` with NOPASSWD sudo (that build hard-coded the account; since 2026-11-19 `rootfs` asks for user name and password, see below), SSH key = project key, ext4 label
`omamobile-root` so the Omarchy init grows it to the full 957 GB partition on first boot).

Vendor firmware found on the running Android and staged into the rootfs under /lib/firmware (raw copies in
`vendor-raw/`): Wi-Fi WCN7860 "peach" from `/vendor/firmware_mnt/image/peach/` (amss.bin, amss20.bin, bdwlan.e01-e04,
regdb.bin, Data.msc, aux_ucode.elf, …) → `ath12k/WCN7850/hw2.0/` with `WCN7860/hw2.0` symlinked as Omarchy does;
Bluetooth from `/vendor/bt_firmware/image/` (brhbtfw20.mbn/.tlv, brhbtnv20*.bin — note "brh", not the "gng" names in
Omarchy's script) → `qca/`; GPU Adreno 830 from `/vendor/firmware/gen80000_*` (sqe.fw, aqe.fw, gmu.bin, zap.mbn) → `qcom/`.
Wi-Fi/BT/GPU bring-up is after the first native boot; exact file names the drivers request still to be matched.

Writes, each gated by typing the serial (`scripts/omarchy-install-slot-b.sh`):
1. `fastboot flash userdata rootfs.img` — erases Android data and the chroot. (fastboot re-sparses images above max-download-size 768 MiB.)
2. `fastboot flash boot_b boot-chain-install.img` — boot_a untouched.
3. `fastboot set_active b` + reboot. Then, from Linux, `sgdisk -A <boot_b partnum>:set:54 /dev/sde` (primary+backup) so ABL stops
   burning retries; verify with `fastboot getvar slot-successful:b`. GPT backups: `firmware/images/Original-*-allfw-*/gpt/`.
Way back: `fastboot set_active a`, then factory-reset Android (userdata is gone).

Rootfs built 2026-11-18 (second attempt; first failed on the package name `wpa_supplicant` → `wpasupplicant`):
1.4 GB tree, ext4 image 2,040,528,896 bytes, label omamobile-root, sha256 fbd4a84af225b352a0e9d0546b457fc34b91b95e4090ff66d80d76f9d59749ba,
copy in `firmware/images/omarchy-dodge-chain-20261118-025010/rootfs-ubuntu-noble-dodge.img` (+ .zst). Verified contents:
systemd, sshd, NetworkManager, wpa_supplicant, sgdisk, user min, 1789 modules incl. ath12k, 669 MB firmware
(Ubuntu linux-firmware + vendor blobs), SSH keys for root and min, fstab LABEL=omamobile-root, usb0 172.16.42.1/24,
getty@tty1 + serial-getty@ttyGS0 + ssh + NetworkManager enabled.
Lesson (cost an image): never nest quoting through adb→su→sh→bash; the driver now pushes step files and runs them
(`in_ubuntu_run`/`in_ubuntu_bg`).
GPT facts from the sde backup: boot_a = partition 12 (attr 0x007f…: prio 3, active, retry 7, successful), boot_b =
partition 48 (attr 0x003b…: prio 3, not active, retry 7, NOT successful). Qualcomm layout: bits 48-49 priority,
50 active, 51-53 retry, 54 successful, 55 unbootable. userdata = sda partition 15.

## 2026-11-18 slot-b install: writes done, flashed boot stops in stage 1, RAM boot of the same image runs Ubuntu

Writes (each confirmed by the user typing the serial, `scripts/omarchy-install-slot-b.sh`):

| # | Command | Result |
| --- | --- | --- |
| 1 | `fastboot flash userdata rootfs-ubuntu-noble-dodge.img` | OKAY (fastboot sparse-split it into 2 chunks, 32 s). Android data and the chroot are gone. |
| 2 | `fastboot flash boot_b boot-chain-install.img` | OKAY. Read back from Linux later: sha256 of the first 62,853,120 bytes of `/dev/sde48` = 8de58471… = the image. |
| 3 | `fastboot set_active b` + reboot | slot b tried once (retry 7→6), no USB gadget ever appeared, phone ended in stock recovery ("format data / reboot") with slot a active again. |

What the user saw on the second, timed attempt: OnePlus logo, the yellow "device is unlocked" warning, that screen frozen for a few minutes, logo again, Android recovery. The yellow screen is ABL's last frame before it jumps into the kernel, so stage 1 ran and took one of its holds (230 s then `sysrq b`): memory.reg mismatch, `kexec -l` failure, or `kexec -e` returning. Stage 1 has no console and no display driver, so the reason was invisible. This OPPO ABL then switches the active slot back to a after a single failed boot of a not-yet-successful slot (standard Qualcomm ABL would spend all retries first).

RAM boot of the *same* install image (`fastboot boot boot-chain-install.img`, slot a active) worked end to end: stage 2 in 27 s, root `LABEL=omamobile-root` on `/dev/sda15` grown to 921 GB, systemd `running`, 0 failed units, ssh + NetworkManager active, login as `min` over the USB ACM console (`/dev/cu.usbmodemomamobile3`, hostname `oneplus13`), kernel 7.3.0-rc6-omamobile-push1. `sudo systemctl reboot --reboot-argument=bootloader` from Ubuntu lands in fastboot (works on this ABL).

GPT after the failed attempts (read with sgdisk from Ubuntu): boot_a (sde12) attrs 0x007F… = priority 3, active, retry 7, successful; boot_b (sde48) 0x0032… = priority 2, inactive, retry 6, not successful.

Key difference between the two paths: the stage-2 DTB's `memory` node is copied at pack time from the Android live FDT (16 fragmented ranges that ABL generates per boot); stage 1 refuses when this boot's map differs. A flashed boot may well hand a different map than a `fastboot boot`. Next build (`kernel/stage1/`, Docker on the Mac since the chroot is gone): stage 1 draws its findings on ABL's splash framebuffer through /dev/mem (`fbtext`), rewrites the stage-2 DTB memory reg from the live map with fdtput instead of holding, and holds 120 s with the error on screen if kexec fails. Flash it to boot_b (serial-gated) and read the screen.

Incident: holding Volume Up + Volume Down (as a wrong attempt to reach fastboot) put the phone in EDL (USB `QUSB_BULK_CID:045A_SN:7359EE91`, 05c6:9008, black screen). Harmless; exit: unplug USB, hold Power + Volume Up + Volume Down ~10 s, then Power + Volume Down for fastboot. Never use Volume Up + Volume Down on this phone.

Way back to Android at any time: `scripts/omarchy-install-slot-b.sh back-to-android` (set_active a; stock recovery then needs "Format data" because userdata holds ext4).

## 2026-11-18 evening: flashed slot-b boot FIXED — the chained `boot` partition needs an AVB footer

Root cause of "RAM boot works, flashed boot resets ~10 s after the yellow screen": `vbmeta_b` does not hash
`boot` itself, it **chains** it (chain descriptor, rollback location 4) to a vbmeta inside the boot partition's
own AVB footer. The stock boot_b has one (avbtool 1.3.0, SHA256_RSA4096, rollback 0, props os_version 15,
security_patch 2026-03-01). Our chain image had none. With the bootloader unlocked libavb tolerates a wrong key
and a stale hash (`ERROR_VERIFICATION`), but a chained partition with no footer is `ERROR_INVALID_METADATA`,
which is fatal even when unlocked. `fastboot boot` skips AVB entirely, which is why every RAM boot worked.
Omarchy Mobile's `bin/omamobile` says the same ("ABL ... refuses a chained partition with no footer at all") and
adds footers via `AVB_FOOTERS` per device; its dodge `device.conf` never got that line.

Fix: `kernel/stage1/add-avb-footer.sh <chain.img>` (avbtool 1.4.0 + AOSP test key in `tools/avb/`, gitignored, fetched by `kernel/stage1/fetch-avb.sh`,
same pins as Omarchy's toolchain.lock) pads the image to the 96 MiB partition and signs a hash footer with the
stock parameters. `scripts/omarchy-install-slot-b.sh boot_b` now refuses an image without that footer.

Result: `boot-chain-install-dbg-avb.img` (from `firmware/images/omarchy-dodge-chain-dbg-20261118-211811/`,
sha256 f7cc0d85…) flashed to boot_b + `set_active b` → Ubuntu from userdata in ~60 s. GPT bit 54 set from
Ubuntu (`blockdev --setrw /dev/sde; sgdisk -A 48:set:54 /dev/sde; blockdev --setro /dev/sde`): boot_b attrs
0x007F (prio 3, active, retry 7, successful), boot_a 0x007A (prio 2, inactive, successful). An unattended
`systemctl reboot` came back to Ubuntu (USB gadget 56 s after reboot, systemd `running`). **Native Linux is
installed and self-booting.**

Dead ends worth remembering (all verified today):
- Earlier "stage 1 held for minutes" readings were wrong; USB timelines show every flashed attempt died within
  ~10–15 s, independent of image size (59.4–60.3 MiB) and content.
- Drawing on ABL's splash framebuffer through /dev/mem never shows: the panel is command-mode DSI
  (`..._dsc_cmd`), nothing refreshes without a display driver. Also the initramfs never had /dev/mem until the
  init mounted devtmpfs (the kernel does not mount it for an initramfs).
- ramoops/pstore in the splash reservation (0xfe000000/0xfe400000) works within a boot but never survives a
  reboot through ABL, not even a clean `systemctl reboot --reboot-argument=bootloader`: RAM is cleared.
  read()/write() on /dev/mem fail for no-map memory on arm64 (`valid_phys_addr_range`); mmap works (`memcp`).
- Holding Volume Down across the fallback reset put the phone in EDL every time; the user's reset combo also
  passes through EDL. Harmless, but RAM is lost either way.

Stage 1 as flashed now (debug variant, `kernel/stage1/init`): devtmpfs, memory-reg rewrite with fdtput instead
of holding, outcome encoded as hold times, panic=30, 20/45 s pause before kexec -e, ramoops params (inert).
A lean rebuild without the debug pauses can come later; it would need the footer step again.

Next: Wi-Fi/BT/GPU firmware, macOS NCM, optionally lower slot a's priority or mark it unbootable so ABL can
never fall back to Android (user wants the phone "locked" on Ubuntu). Way back to Android still exists:
`scripts/omarchy-install-slot-b.sh back-to-android` + factory reset.

## 2026-11-18 late: SSH over USB, Ollama copied, USB Wi-Fi dongle drivers

- **SSH from the Mac works over the USB link with zero Mac configuration**: macOS names the phone's NCM link
  (Hardware Port "OnePlus 13", en13 here) and gives it only a link-local IPv4; the phone's usb0 has
  172.16.42.1 and an IPv6 link-local. `ssh -6 -i keys/omarchy-dodge_ed25519 min@'fe80::876:3ff:fe8c:c8b7%en13'`
  (root works too). Find the phone's address with `ping6 -c2 -I en13 ff02::1%en13`. scp did 1.6 GB in 43 s.
- `tools/ollama/ollama-linux-arm64.tar.zst` (v0.40.16, sha256 e45b8e6d…) is at `/root/` on the phone, not
  installed yet (`tar -C /usr --zstd -xf … --exclude='lib/ollama/cuda_*'` + a systemd unit when wanted).
- **USB Wi-Fi dongles**: the Omarchy stage-2 kernel ships 1789 modules but no USB Wi-Fi drivers. Built in
  Docker from the same commit/config (`kernel/stage2-modules/build.sh`, MO= out-of-tree objects, vermagic
  7.3.0-rc6-omamobile-push1-g6cc4b65df980, no MODULE_SIG/MODVERSIONS so they just load) and installed into
  `/lib/modules/<ver>/extra/` on the phone + depmod: rtl8xxxu, rtw88 (8822bu/8821cu/8822cu/8723du/8821au/
  8812au), mt76 (mt7921u; mt7601u/mt76x0u/mt76x2u in the follow-up build), ath9k_htc, rt2800usb (follow-up).
  All modprobe clean. Artifacts: `firmware/images/omarchy-dodge-modules-<id>/`.
- The kernel has no FW_LOADER_COMPRESS, so Ubuntu's `*.bin.zst` firmware is invisible: unpacked 77 files for
  these drivers with `zstd -dk` under /lib/firmware (rtlwifi, rtw88, mediatek, ath9k_htc, rt2870).
- The USB-C port boots in device mode; Type-C role detection (pmic_glink) is not running. Installed
  `/usr/local/sbin/usb-role-auto` + `usb-role-auto.service`: when no USB host has configured the gadget for
  45 s, it writes `host` to `/sys/class/usb_role/a600000.usb-role-switch/role`. So: unplug the Mac, plug a hub
  with the dongle (and a keyboard for the on-screen console), wait ~1 min. Back to device mode = reboot with
  the Mac attached. HDMI on USB-C hubs will not work (no DP alt mode).
- The phone's clock starts at 1970 (no RTC/network time); tar warns about future timestamps. Harmless until
  TLS matters; NTP via Wi-Fi will fix it.
- Pending from the user: Wi-Fi SSID/password for an autoconnect NetworkManager profile
  (`nmcli con add type wifi con-name home ifname '*' ssid … wifi-sec.key-mgmt wpa-psk wifi-sec.psk … connection.autoconnect yes`).

## 2026-11-18 night: built-in Wi-Fi (WCN7860 "peach", ath12k) WORKS

Symptom: ath12k found the chip on PCIe but "Wait for device to enter SBL" timed out (-110) every boot; the
ordered bring-up (Omarchy's `omamobile-wifi-pcie` + `omamobile-wifi-ath12k` units, now installed, with
`/etc/modprobe.d/omamobile-ath12k.conf` blacklisting the udev autoload) did not change that, nor did holding
Bluetooth off; a power-cycle through pci-pwrctrl hung the phone. Root cause was the FIRMWARE SET, not power:
the host pushes the first part of amss.bin before that SBL wait, and we had Android's revision-1 files.
Android's own choices for this chip (hw2.0, board_id 0xff) are the "20" variants and the default board file.
Final `/lib/firmware/ath12k/WCN7850/hw2.0/` (WCN7860/hw2.0 is a symlink to it), all from this phone's stock
Android (`/lib/firmware/vendor-raw/peach/` staged by omarchy-build-phone.sh, plus the `modem_a` partition
image mounted on the phone with `mount -o loop,ro`, FAT16 with 4 KiB sectors that macOS cannot mount):

| file | source | note |
|---|---|---|
| amss.bin | vendor-raw/peach/amss20.bin | v1 kept as amss.bin.v1; v1 never reaches SBL |
| board.bin | vendor-raw/peach/bdwlan.elf | Android's default for board_id 0xff; bdwlan.e01 (kept as board.bin.e01) left the firmware silent, no FW_READY |
| tmel_peach_20.elf (+_10) | modem_a.img:/image/ | TME-Lite patch; firmware answers "result 1 err 83" but boot continues |
| phy_ucode20.elf | vendor-raw/peach | sent as the M3 image by Omarchy's peach-patched driver |
| aux_ucode.bin | vendor-raw/peach/aux_ucode20.elf | driver asks for this name |
| qdss_trace_config_v2.cfg | vendor-raw/peach | optional trace config |
| regdb.bin, m3.bin, board-2.bin | as before | m3.bin unused for peach |

Result: wlp1s0 up at 5.4 s, NetworkManager joins the `home` profile, 10.1.1.51/24 on 5745 MHz, 360 Mbit/s
VHT, 0% loss to 1.1.1.1, NTP synced. SSH over Wi-Fi: `ssh min@10.1.1.51`. Driver debug (`options ath12k
debug_mask=0xffffffff`) was used for one boot and removed. The Omarchy `device/dodge` tree has no AVB_FOOTERS and
no firmware notes for peach; both findings are worth feeding back upstream.

### Memory under Ollama (2026-11-18, native Ubuntu, 24 GB phone)
Usable RAM 22,804 MB (844 MB firmware reservations). Idle with Ollama service + qwen2.5:3b resident: 3.1 GB used,
19.7 GB available, no swap/zram. qwen2.5:3b generation: runner RSS 2.3 GB flat, 13.0 tok/s decode, 131 tok/s
prompt, 8 cores. With gemma4:12b (8 GB Q4 file) also resident: runner RSS 9.6 GB (AnonHugePages 10.4 GB), total
used 12.6 GB, available 10.2 GB, PSI memory stall totals 0.19 s some / 0.12 s full since boot, 0 OOM kills.
`ollama ps` SIZE is unreliable (shows 1.4 GB for the 9.6 GB gemma runner). No Android-side measurement exists
(none was captured while Android ran); comparison is structural only.

## 2026-11-18 late: llama.cpp service, Ollama parked, stable Wi-Fi address, bigger console font

- **Wi-Fi address**: the WCN7860 has no programmed MAC; ath12k invents one per boot (00:03:7f:12:xx:xx), so DHCP
  gave a new lease each reboot. Pinned in the NM profile: `nmcli con modify home 802-11-wireless.cloned-mac-address
  02:4f:50:31:33:01 connection.mdns 2` → lease 10.1.1.198 stays. `ssh min@10.1.1.198`.
- **Ollama**: `systemctl disable --now ollama` (kept installed; `systemctl start ollama` when wanted). Models it
  downloaded are plain GGUF blobs under /usr/share/ollama/.ollama/models/blobs (manifests map name → digest).
- **llama.cpp**: built natively on the phone (`/opt/llama.cpp`, commit 0a76757, GCC 13, `-DGGML_NATIVE=ON`;
  CPU has asimddp/i8mm/bf16), binaries in /usr/local/bin (llama-server, llama-cli, llama-bench, llama-quantize,
  llama-gguf-split). Service `llama-server.service` (user `llama`, port 8080 on all interfaces, settings in
  `/etc/default/llama-server`: MODEL/CTX/THREADS/EXTRA; `$EXTRA` must stay unbraced in ExecStart or an empty
  value becomes an empty argument). Models in /var/lib/llama/models: Qwen2.5-3B-Instruct-Q4_K_M.gguf (HF
  bartowski, 1.93 GB) and gemma4-12b-it-Q4_K_M.gguf + -mmproj + -draft copied from Ollama's blobs.
  API from the Mac: `curl http://10.1.1.198:8080/v1/chat/completions` works (OpenAI-compatible).
- **Speed (8 threads, CPU only)**: Qwen2.5-3B Q4_K_M: Ollama 13.0 tok/s decode (ollama run --verbose) vs llama.cpp 22.1 tok/s in a
  short API call; llama-bench pp512 27.0 tok/s, tg128 17.2 tok/s (the server test ran with the llama-bench idle). gemma4 12B Q4_K_M: pp512 6.9 tok/s, tg128 4.5 tok/s.
- **Console font**: fbcon was 8x16 (180x198 chars on 1440x3168). Now TerminusBold 32x16 (90x99) via
  `/etc/default/console-setup` (FONTFACE=TerminusBold FONTSIZE=16x32) + console-setup.service; 32 px is the
  largest the kernel console takes. Bigger text would need a userspace framebuffer terminal (fbterm/kmscon).

### Bigger on-screen terminal: kmscon (2026-11-19)

The kernel text console (fbcon) caps fonts at 32 px, and TerminusBold 32x16 was already applied (`stty size` on tty1 = 99 rows x 90 cols), so the only way to go larger is a userspace terminal. Installed Ubuntu's `kmscon` 9.0.0 (`apt-get install kmscon`), which draws with Pango/FreeType at any size:

- `/etc/kmscon/kmscon.conf`: `font-name=DejaVu Sans Mono`, `font-size=24`, `font-dpi=192` (64 px glyphs, about 45 columns x 49 rows on the 1440x3168 panel), `drm`, `no-hwaccel`, `no-switchvt`, `palette=solarized-black`. Ctrl+Alt+Plus / Ctrl+Alt+Minus change the size live; edit the file and `systemctl restart kmsconvt@tty1` to change the default.
- `kmsconvt@tty1.service` is enabled (getty.target.wants) and `getty@tty1` disabled: the two conflict and both were wanted at boot. kmscon runs agetty itself, so the login prompt on the panel is unchanged, just larger. kmscon logs "video_fbdev: cannot read monitor refresh rate, forcing 60 Hz": it uses the fbdev path on msmdrmfb, not DRM; harmless.
- Fallbacks if kmscon ever fails: `serial-getty@ttyGS0` (USB serial `/dev/cu.usbmodemomamobile3`) and SSH are untouched; `systemctl enable getty@tty1 && systemctl disable kmsconvt@tty1` restores the plain console.

### 2026-11-19: native Linux removed, phone back to locked stock

The user chose to redo the project from the beginning. `scripts/omarchy-install-slot-b.sh revert-stock` + `lock` (see `docs/bootloader.md`) put stock boot_b/init_boot_a back, wiped userdata (the Ubuntu rootfs, llama.cpp models, kmscon, Wi-Fi firmware set all lived there) and relocked the bootloader. Nothing in this document is on the phone any more; all build artifacts (`firmware/images/omarchy-dodge-*`, `kernel/stage1`, `kernel/stage2-modules`, `tools/avb`) and the recipes above remain valid for the redo.

Cleanup 2026-11-19: artifacts kept are `omarchy-dodge-stage2-20261118-023859` (stage-2 kernel/dtb/initramfs), `omarchy-dodge-chain-20261118-025010` (first-light images, rootfs `.zst` only), `omarchy-dodge-chain-dbg-20261118-211811` (the footered image that was flashed) and `omarchy-dodge-modules-20261118-223011` (33 USB Wi-Fi modules). Intermediate debug builds, the Ollama tarball and the Docker build volume were removed; `kernel/stage1/build.sh` needs fresh source clones under `SRC_MAC` before it can run again.

## 2026-11-19: no hard-coded credentials in the rootfs build

At the user's request `scripts/omarchy-build-phone.sh rootfs` no longer bakes `min`/`oneplus13` into the image. It now
asks on the Mac for the Linux user name (default: the Mac login name) and a password typed twice without echo;
`OMARCHY_USER` / `OMARCHY_PASSWORD` in the environment skip the prompts for unattended rebuilds. Only the SHA-512
crypt hash leaves the Mac (`openssl passwd -6`, or hashed inside the chroot if the Mac's openssl lacks `-6`); it travels
as a root-only file (`/root/out/linux-user` in the build chroot, deleted from the image after `useradd -p`). The chosen
name is kept in `/root/out/linux-user.name` so `verify-rootfs` can report on it; root stays locked (key-only SSH).
`scripts/ubuntu-chroot-setup.sh` likewise prompts for its user name (`UBUNTU_USER` skips it; no password, the chroot is
entered through Magisk su only). The chroot on the phone was created before this change and has user `min`.

## 2026-11-19 night: Phase 3 redo started

Chroot rebuilt (`scripts/ubuntu-chroot-setup.sh`, user `min`), `omarchy-build-phone.sh sources` restaged kernel
`dodge-v3-20261101`, omarchy-mobile `17f9a3c`, mkbootimg `d2bb0af`, Alpine 3.24.2 + apks, live DTB and a freshly
generated `keys/omarchy-dodge_ed25519`. First `stage2` launch died with "make: command not found": the old chroot's
toolchain had been installed by hand. Added a `toolchain` step (clang/lld/llvm, make/bison/flex/bc, libssl/libelf/libdw,
dtc/libfdt, lz4/zstd/cpio/rsync/kmod/dwarves, e2fsprogs/gdisk) that `stage2` runs first; relaunched, load average 12 on
8 cores. Mac side: `kernel/stage1/fetch-sources.sh` cloned the three trees into `kernel/src/`, `kernel/stage1/fetch-avb.sh`
restored `tools/avb/` (avbtool 1.4.0 at Omarchy's pinned commit ba2dec4b035b, checksums match their lock file).

Results 2026-11-19 night: stage2 done 04:12 UTC (launch 03:49 UTC, ~23 min wall on 8 cores), release
`7.3.0-rc6-omamobile-push1-g6cc4b65df980`, Image 43,395,584 B, dodge DTB 127,645 B (same sizes as 2026-11-18), 1789 modules.
initramfs 6,597,348 B after adding Alpine's `e2fsprogs-extra` (resize2fs moved there; the `sources` apk list now includes
it). chain pack done 04:27 UTC: `boot-chain.img` 62,853,120 B, header v4 kernel-only, sha256 0fd431d1…; pulled to
`firmware/images/omarchy-dodge-20261119-225253/` with SHA256SUMS. Next: first light (RAM only) with that image.

### FIRST LIGHT again — 2026-11-19 23:0x (redo, RAM only)

The user ran `fastboot boot` with `omarchy-dodge-20261119-225253/chain_images_boot-chain.img` (the first-light script
was still waiting for fastboot, so en13 never got 172.16.42.2). Result: `uname -a` over SSH =
`Linux omamobile 7.3.0-rc6-omamobile-push1-g6cc4b65df980`, cmdline carries `omamobile.initramfs` and
`androidboot.slot_suffix=_b`, simpledrm console 90x99 on the 1440x3168 panel, gadget functions `acm.GS0` + `ncm.usb0`,
dropbear on port 22, UFS visible as /dev/sda*. Reaching it WITHOUT sudo on the Mac: the phone's IPv6 link-local is in
`ndp -an | grep en13` (the non-permanent row), then
`ssh -6 -i keys/omarchy-dodge_ed25519 root@fe80::<phone>%en13`. The test initramfs runs NO getty on ttyGS0
(`console=tty0` only), so `screen /dev/cu.usbmodemomamobile3 115200` shows nothing until a shell is started on it:
`nohup setsid sh -c 'while :; do /bin/sh -l </dev/ttyGS0 >/dev/ttyGS0 2>&1; sleep 1; done' &` over SSH (done this
session; the Ubuntu rootfs enables serial-getty@ttyGS0 so this is only an initramfs quirk).

### 2026-11-19 23:xx: rootfs build on the redo, three staging gaps closed

The first `rootfs` launch (user `m-3`, prompted) died at once: `/root/dl/ubuntu-base-24.04.5-base-arm64.tar.gz` was not
in the chroot (the old chroot had it from a manual copy). `sources` now pushes the Ubuntu Base tarball from `rootfs/`
(and the step prints a note if it is missing). Second gap: the vendor firmware had been staged by hand in November 18's
chroot. New step `omarchy-build-phone.sh vendor-fw` copies, from inside the chroot via `/proc/1/root`, Android's
`/vendor/firmware_mnt/image/peach/` (72 files), `/vendor/bt_firmware/image/` (214), `/vendor/firmware/gen8*` (5), and
reads `tmel_peach_10/20.elf` out of a `dd` copy of `modem_a` with 7z (Android's kernel refuses to loop-mount the 4 KiB-
sector FAT16 from the chroot). The rootfs step now applies the mapping from the Wi-Fi table above (amss20→amss.bin,
bdwlan.elf→board.bin, phy_ucode20.elf, aux_ucode20.elf→aux_ucode.bin, tmel_peach_*.elf) instead of the e01 guess, so
Wi-Fi firmware is right at first boot. Third: the credential prompt needs a terminal; run `rootfs` from Terminal.app,
not through Claude Code's `!` prefix (the script now says so instead of looping). The rootfs step was relaunched by
re-running `/root/steps/rootfs.sh` with the stored root-only `/root/out/linux-user` (no second prompt).

### 2026-11-20 00:10: install inputs ready (redo), phone in fastboot

- rootfs: `omarchy-build-phone.sh rootfs` (user `m-3`, prompted) + firmware fix-up + re-image → `/root/out/rootfs-ubuntu-noble-dodge.img`
  8 GiB, ext4 label omamobile-root, sha256 64e67593…; verify-rootfs: systemd/sshd/NetworkManager/sgdisk ok, 1789 modules,
  669 MB firmware, ath12k hw2.0 dir has amss.bin(=amss20) board.bin(=bdwlan.elf) phy_ucode20.elf aux_ucode.bin tmel_peach_10/20.elf,
  serial-getty@ttyGS0 + getty@tty1 + ssh enabled. NOTE: the user's rootfs step file predated the firmware-mapping edit, so the
  mapping was applied afterwards to /root/rootfs and the image rebuilt (mkfs -d). Pulled via zstd (831 MB) to
  `firmware/images/omarchy-dodge-rootfs-20261120-0603/rootfs-ubuntu-noble-dodge.img`, sha verified on the Mac.
- stage-1 install image: Docker `kernel/stage1/build.sh` (two fixes in in-container.sh: artifact path prefix, `ls` of a
  non-matching glob under set -e) → `firmware/images/omarchy-dodge-chain-dbg-20261120-054628/boot-chain-install-dbg.img`
  62,328,832 B, no `omamobile.initramfs`; footer added → `boot-chain-install-dbg-avb.img` 96 MiB, sha256 41323c61….
- GPT backup: `android-tool.sh backup` now also dumps head/tail of every LUN (`gpt/`); 6 LUNs in
  `Original-PJZ110_16.0.5.703CN01-20261120-000539/gpt/`. `backup gpt` adds it to an existing dump (dispatch bug fixed: args
  were not passed to cmd_backup).
- preflight ok: slot a, unlocked, max-download 768 MiB, slot-successful a/b yes/no, retries 7/7. Next: the three gated writes.

### 2026-11-20 00:15: first install attempt stopped by fastboot, nothing written

`omarchy-install-slot-b.sh userdata` with the 8 GiB raw image: fastboot 37.0.3 on macOS printed
`fastboot: error: Failed reading from userdata` before any "Sending" line, i.e. it could not read a raw image >= 4 GiB;
nothing reached the phone (slot a, userdata intact, verified by rebooting into unchanged Android). The script still
printed "userdata written" because the pipe into tee hid the exit status: every write now goes through `fb_write`,
which dies unless fastboot exits 0 and prints "Writing '<part>' OKAY", and `userdata` refuses raw images >= 4 GiB.
Fix for the image: `omarchy-build-phone.sh mkimage` (minimal ext4 from /root/rootfs, 2,041,577,472 B, same contents and
firmware; the Omarchy init grows it to the whole partition on first boot) → `firmware/images/omarchy-dodge-rootfs-20261120-0613/`,
sha256 37eec1cf… verified on the Mac. The 8 GiB copy was deleted.

## 2026-11-20 00:25: native Ubuntu installed and booting from slot b (redo complete to the install)

Writes (all `fb_write`-checked, serial-gated, run by the user): `userdata` ← minimal rootfs (two sparse chunks, Writing OKAY),
`boot_b` ← `boot-chain-install-dbg-avb.img` (98304 KB, Writing OKAY), `set_active b`, reboot. Result over SSH as `m-3`
(IPv6 link-local on en13, key `keys/omarchy-dodge_ed25519`): `Linux oneplus13 7.3.0-rc6-omamobile-push1`, Ubuntu 24.04.5,
`systemctl is-system-running` = running, `/` = /dev/sda15 921 GB (grown by the Omarchy init from the 1.9 GB image),
usb0 172.16.42.1/24, wlp1s0 present (ath12k firmware loaded, TME-Lite "result 1 err 83" as before), serial-getty@ttyGS0,
ssh and NetworkManager active. GPT after the first boot: boot_b (sde48) attrs 0x0037… = priority 3, active, retry 6
(one burned), NOT successful; boot_a (sde12) 0x007A… = priority 2, inactive, retry 7, successful. Pending: set bit 54 on
sde48 (`blockdev --setrw /dev/sde; sgdisk -A 48:set:54 /dev/sde; blockdev --setro /dev/sde`), then a NetworkManager Wi-Fi
profile with the user's SSID/password (never stored in the repo).

### 2026-11-20 01:35: Wi-Fi up, two unplanned reboots explained (power button), retries at 4

Wi-Fi: `sudo nmcli dev wifi connect "<SSID>" password "<pw>"` as `m-3` (plain `nmcli` is refused: no polkit in the minimal
image, so NetworkManager only trusts root; `sudo` is NOPASSWD) → MRZ-Blast(AC), channel 149, 270 Mbit/s, 10.1.1.103/24, NTP
synced, SSH over Wi-Fi `ssh -i keys/omarchy-dodge_ed25519 m-3@10.1.1.103`. The usb0 link-local changes every boot.

Journal of boot -1: `systemd-logind: Power key pressed short. Powering off...` at 108 s. logind's default for the PMIC
power key is poweroff; on USB power the phone boots again immediately, and every boot of a not-yet-successful slot burns
an ABL retry: boot_b attrs went 0x0037 (retry 6) → 0x0027 (retry 4) over three boots. Fix applied live
(`/etc/systemd/logind.conf.d/10-powerkey.conf`: HandlePowerKey=ignore, LongPress=ignore; `busctl get-property ... HandlePowerKey`
= "ignore") and baked into the `rootfs` step. The GPT "successful" bit (54) on sde48 is still unset and must be set before
the remaining 4 retries are used up; it is a partition-table write and waits for the user's explicit go.
