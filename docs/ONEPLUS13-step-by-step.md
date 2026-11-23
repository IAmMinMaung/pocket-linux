# OnePlus 13 (PJZ110) — unlock, root, and install native Ubuntu: copy-paste runbook

Every command below was run, in this order, on 2026-11-19/20 on a OnePlus 13 PJZ110 (ColorOS 16.0.5.703 CN01,
build C.88) from an Apple-Silicon Mac. Commands marked **(you type)** need a real Terminal window because they ask
for a confirmation, the phone's serial number, or a password. Everything else can be pasted as is.

Time: Phase 1 about 15 min, Phase 2 about 20 min, Phase 3 about 2 h (most of it waiting for builds).

---

## 0. Before you start

Hardware and rules for this phone:

- A **USB 2.0** connection to the Mac (OnePlus charging cable through a USB 2 hub). The bootloader is invisible over USB 3.
- Never press **Volume Up + Volume Down** together on a powered OnePlus 13: that is EDL mode. Fastboot from off is Power + Volume Down. A hard reset is Power + both volume keys for 10 s.
- Build C.88 has anti-rollback. Never flash boot-chain images from an older build.
- Unlocking wipes the phone, installing Linux wipes it again. Back up anything you care about first.

On the phone: Settings → About device → Version → tap **Build number** 7 times. Then Settings → Additional settings → Developer options → turn on **USB debugging** and **OEM unlocking**. Accept the Mac when the "Allow USB debugging" prompt appears.

On the Mac, from the project folder:

```bash
cd ~/Projects/Root-Android          # or wherever you cloned it
scripts/android-tool.sh env         # downloads Google Platform-Tools into tools/, checks payload-dumper-go
scripts/android-tool.sh discover    # writes profiles/device-profile.{env,md}; expect model PJZ110, codename OP5D0DL1
```

`discover` must show `RO_BOOT_FLASH_LOCKED=1` for a stock phone and `HAS_INIT_BOOT=yes`. If `payload-dumper-go` is missing: `brew install payload-dumper-go`.

Get the stock OTA zip (8.4 GB) and the other inputs. The OTA must land at `firmware/images/PJZ110_16.0.5.703_CN01_C88.zip`
with MD5 `2cc8031b2589dd4e80bd3c93326c7c7e`; if you already have it in Downloads, hard-link it instead of copying:

```bash
scripts/fetch-inputs.sh             # Ubuntu Base 24.04.5, Termux, Magisk v31.1 (sha256-checked, see DOWNLOADS.md)
ln ~/Downloads/PJZ110_16.0.5.703_CN01_C88.zip firmware/images/ 2>/dev/null || scripts/fetch-inputs.sh ota
md5 -q firmware/images/PJZ110_16.0.5.703_CN01_C88.zip      # must print 2cc8031b2589dd4e80bd3c93326c7c7e
```

---

## Phase 1 — unlock the bootloader

**(you type)** The script checks Developer options and USB debugging over adb, asks you to confirm the OEM-unlocking
toggle, the USB 2.0 cable and your backup, reboots to fastboot, refuses if `get_unlock_ability` is 0, then asks for the
phone's serial before `fastboot flashing unlock`. Confirm on the phone with the volume keys and Power.

```bash
scripts/android-tool.sh unlock
```

The phone wipes and reboots into the setup wizard. Finish the wizard (skip accounts), re-enable Developer options and
USB debugging as in step 0, accept the Mac again. Then:

```bash
scripts/android-tool.sh discover
grep -E 'FLASH_LOCKED|VERIFIEDBOOT' profiles/device-profile.env   # expect RO_BOOT_FLASH_LOCKED=0, orange
```

While the phone shows as a device but every `adb shell` says `error: closed`, USB debugging is not yet re-enabled.

---

## Phase 2 — root with Magisk (init_boot)

Extract the stock images from the verified OTA (this also records them as the required pre-flash backup):

```bash
EXPECTED_OTA_MD5=2cc8031b2589dd4e80bd3c93326c7c7e scripts/android-tool.sh extract-boot firmware/images/PJZ110_16.0.5.703_CN01_C88.zip
```

Install the Magisk app (the APK was fetched and checksum-verified in step 0):

```bash
tools/platform-tools/adb install -r tools/apk/Magisk-v31.1.apk
```

**(you type)** The root command pushes `init_boot.img` to the phone, then pauses. On the phone open **Magisk → Install →
Select and Patch a File**, choose `Download/init_boot.img`, tap **Let's go**, wait for "All done!". Only then press Enter
in the Terminal. The script pulls the patched image, reboots to fastboot and asks for the serial before flashing init_boot.

```bash
scripts/android-tool.sh root
```

After the reboot, open the Magisk app once (it should read "Installed 31.1"). If it asks to finish additional setup,
accept and let it reboot.

**Allow root for adb (the "Shell" step).** Magisk on this phone denies the first `su` request from adb instantly,
without showing a prompt, so the grant has to be switched on by hand:

1. Ask for root once so that Magisk records the request (it prints `Permission denied`; that is expected):

   ```bash
   tools/platform-tools/adb shell su -c id
   ```

2. On the phone open **Magisk → Superuser** (the shield tab in the bottom bar).
3. Find the entry **Shell** (`com.android.shell`) and turn its switch **on**.

   If there is no Shell entry, repeat step 1 with the phone unlocked and the Magisk app open, then look again.

4. Test root again:

   ```bash
   tools/platform-tools/adb shell su -c id          # expect uid=0(root) ... context=u:r:magisk:s0
   ```

Every later step (`backup`, the chroot, the builds) runs `su` through adb and fails with `Permission denied` until
this switch is on. Unlocking or a factory reset clears the grant, so redo this step after either.

Finally, back up the phone's own partitions (both slots plus the GPT of every LUN) and refresh the profile:

```bash
scripts/android-tool.sh backup
scripts/android-tool.sh discover                 # now shows ROOTED=yes
```

Make the untouched slot-b images the lock-safe stock set (this is the only set that passes the phone's own vbmeta; the
CDN OTA is a different compile):

```bash
D=$(ls -td firmware/images/Original-PJZ110*-2026* | head -1); S=firmware/images/Original-PJZ110_16.0.5.703CN01-device-stock; mkdir -p $S
for p in boot init_boot vendor_boot dtbo recovery vbmeta vbmeta_system vbmeta_vendor; do cp $D/Original-${p}_b.img $S/Original-$p.img; done
(cd $S && shasum -a 256 Original-*.img > SHA256SUMS)
sed -i '' "s#^STOCK_DIR=.*#STOCK_DIR=$S#" profiles/device-profile.env
python3 -I scripts/avb-verify.py $S/Original-vbmeta.img $S/Original-init_boot.img $S/Original-boot.img    # every line must say ok
```

Rollback at any time: `scripts/android-tool.sh restore init_boot`.

---

## Phase 3a — Ubuntu userspace in a chroot (the build host for everything else)

**(you type)** asks for the user name inside the chroot (Enter accepts your Mac login name). Needs the phone on Wi-Fi.

```bash
scripts/ubuntu-chroot-setup.sh
tools/platform-tools/adb shell -t su -c /data/local/ubuntu/start.sh   # root shell in Ubuntu 24.04; exit to leave. Without -t there is no prompt and it looks hung
```

---

## Phase 3b — build the mainline kernel chain (on the phone) and the stage-1 image (in Docker)

Stage inputs into the chroot. This generates the project SSH key `keys/omarchy-dodge_ed25519` on first run (gitignored,
it is the only way into the built images) and pushes the Ubuntu Base tarball:

```bash
scripts/omarchy-build-phone.sh sources
scripts/omarchy-build-phone.sh vendor-fw        # this phone's Wi-Fi/BT/GPU firmware from Android + TME-Lite files from modem_a
```

Kernel, initramfs and chain image. `stage2` installs its toolchain first and runs detached (about 25 min on 8 cores);
poll with `status` until the log ends in `STAGE2-BUILD-DONE`, then continue:

```bash
scripts/omarchy-build-phone.sh stage2
scripts/omarchy-build-phone.sh status            # repeat until STAGE2-BUILD-DONE
scripts/omarchy-build-phone.sh initramfs        # seconds; log ends in INITRAMFS-DONE
scripts/omarchy-build-phone.sh chain            # about 10 min; log ends in CHAIN-DONE
scripts/omarchy-build-phone.sh pull             # copies to firmware/images/omarchy-dodge-<ts>/ and omarchy-dodge-stage2-<ts>/
```

Stage-1 install image on the Mac (Docker Desktop running; about 20 min; needs the `live.dtb` that `pull` copied):

```bash
kernel/stage1/fetch-sources.sh                  # clones linux, omarchy-mobile, mkbootimg into kernel/src/
kernel/stage1/fetch-avb.sh                      # avbtool 1.4.0 + AOSP test key into tools/avb/, checksums verified
kernel/stage1/build.sh                          # output firmware/images/omarchy-dodge-chain-dbg-<id>/boot-chain-install-dbg.img
kernel/stage1/add-avb-footer.sh firmware/images/omarchy-dodge-chain-dbg-*/boot-chain-install-dbg.img   # -> *-avb.img (96 MiB)
```

A flashed boot_b image **must** have that footer; `fastboot boot` does not check AVB, a flashed boot does.

---

## Phase 3c — first light (RAM only, nothing is written)

**(you type)** asks for your **Mac login password** (it is `sudo` on the Mac, not a Linux password; Ctrl-C at that
prompt is fine, the IPv6 login below works without the address) to give the USB network interface an address, reboots the phone to fastboot
and runs `fastboot boot` with the test chain image.

```bash
scripts/omarchy-first-light.sh firmware/images/omarchy-dodge-*/chain_images_boot-chain.img
```

Within about 20 s the phone shows a text console. From the Mac, with no sudo needed, find the phone's link-local
address and log in (the test image is a tiny Alpine initramfs, root, key only; Ubuntu comes in the next step):

```bash
ndp -an | grep en13 | grep -v permanent          # the phone's fe80:: address on the USB interface
ssh -6 -i keys/omarchy-dodge_ed25519 root@fe80::REPLACE_ME%en13
```

The serial console `screen /dev/cu.usbmodemomamobile3 115200` is silent in the test image until you start a shell on
it over SSH: `nohup setsid sh -c 'while :; do /bin/sh -l </dev/ttyGS0 >/dev/ttyGS0 2>&1; sleep 1; done' &`.
Type `reboot -f` there (or over SSH) to return to Android; plain `reboot` does nothing in the test image because its
PID 1 is a shell script. The SSH session hangs when the phone goes away: close it with Enter, `~`, `.`. Nothing was written.

---

## Phase 3d — build the Ubuntu root filesystem

**(you type)** asks for the Linux user name, the device name (hostname, Enter keeps `oneplus13`) and the password
(twice, no echo; `OMARCHY_USER`, `OMARCHY_HOSTNAME`, `OMARCHY_PASSWORD` skip the prompts). Run it from Terminal.app, not from inside
another tool: without a terminal it stops with a message. It runs detached for about 20 min; `status` shows the log.

```bash
scripts/omarchy-build-phone.sh rootfs
scripts/omarchy-build-phone.sh status            # until ROOTFS-DONE
scripts/omarchy-build-phone.sh verify-rootfs     # systemd/sshd/NetworkManager ok, your user, 1789 modules, ath12k firmware set
scripts/omarchy-build-phone.sh mkimage           # minimal ext4 image (~2 GB). fastboot on macOS cannot read raw images >= 4 GiB
```

Bring the image to the Mac (zstd on both sides keeps the transfer small) and check it:

```bash
A=tools/platform-tools/adb; D=firmware/images/omarchy-dodge-rootfs-$(date +%Y%m%d-%H%M); mkdir -p $D
$A shell "su -c '/data/local/ubuntu/start.sh /bin/bash -c \"cd /root/out && zstd -T8 -3 -q -f rootfs-ubuntu-noble-dodge.img && sha256sum rootfs-ubuntu-noble-dodge.img > rootfs-ubuntu-noble-dodge.img.sha256\"'"
$A shell "su -c 'cp /data/local/ubuntu/root/out/rootfs-ubuntu-noble-dodge.img.zst /data/local/tmp/rootfs.img.zst && chmod 644 /data/local/tmp/rootfs.img.zst && cat /data/local/ubuntu/root/out/rootfs-ubuntu-noble-dodge.img.sha256'" > $D/rootfs-ubuntu-noble-dodge.img.sha256
$A pull /data/local/tmp/rootfs.img.zst $D/rootfs-ubuntu-noble-dodge.img.zst
(cd $D && zstd -d -q rootfs-ubuntu-noble-dodge.img.zst && rm rootfs-ubuntu-noble-dodge.img.zst && shasum -a 256 rootfs-ubuntu-noble-dodge.img | cut -c1-64 && cut -c1-64 rootfs-ubuntu-noble-dodge.img.sha256)   # the two hashes must match
```

---

## Phase 3e — install to slot b (three writes, each confirmed with the serial)

Android stays on slot a but loses its data (userdata becomes the Linux root). The script's preflight checks the GPT
backup, the stock set, the key, and that fastboot sees the phone; every write stops unless fastboot reports OKAY.

**(you type)** each line asks for the phone's serial:

```bash
scripts/omarchy-install-slot-b.sh preflight
scripts/omarchy-install-slot-b.sh userdata firmware/images/omarchy-dodge-rootfs-*/rootfs-ubuntu-noble-dodge.img
scripts/omarchy-install-slot-b.sh boot_b   firmware/images/omarchy-dodge-chain-dbg-*/boot-chain-install-dbg-avb.img
scripts/omarchy-install-slot-b.sh activate
```

Ubuntu appears on the phone screen within about a minute (login: your user name and password). From the Mac:

```bash
screen /dev/cu.usbmodemomamobile3 115200          # serial login; Ctrl-A K to leave
ndp -an | grep en13 | grep -v permanent          # phone's USB link-local address (changes every boot)
ssh -6 -i keys/omarchy-dodge_ed25519 YOUR_USER@fe80::REPLACE_ME%en13
```

---

## Phase 3f — right after the first boot (do these in order)

1. **Mark slot b successful.** The bootloader gives a new slot 7 boots; each boot of an unmarked slot burns one, and at 0
   it falls back to Android. Check, then set bit 54 on boot_b (partition 48 of /dev/sde on this phone). Run on the phone:

   ```bash
   sudo sgdisk -i 48 /dev/sde | grep -E 'name|Attribute'            # must say boot_b
   sudo blockdev --setrw /dev/sde && sudo sgdisk -A 48:set:54 /dev/sde && sudo blockdev --setro /dev/sde
   sudo sgdisk -i 48 /dev/sde | grep Attribute                        # bit 54 set: the first byte becomes 0x7x, e.g. 007F...
   ```

2. **Wi-Fi** (NetworkManager, saved with autoconnect; `sudo` is required because the minimal image has no polkit):

   ```bash
   sudo nmcli dev wifi list
   sudo nmcli dev wifi connect "YOUR-SSID" password "YOUR-PASSWORD"
   ip -brief addr show wlp1s0 && ping -c 3 1.1.1.1
   ```

   Then from the Mac: `ssh -i keys/omarchy-dodge_ed25519 YOUR_USER@<that address>`.

3. **Power button.** Images built after 2026-11-20 already ignore it. On an older image a short press powers the phone
   off (and it reboots at once on USB power):

   ```bash
   sudo mkdir -p /etc/systemd/logind.conf.d
   printf '[Login]\nHandlePowerKey=ignore\nHandlePowerKeyLongPress=ignore\n' | sudo tee /etc/systemd/logind.conf.d/10-powerkey.conf
   sudo systemctl restart systemd-logind
   ```

4. **Device name.** Images built after 2026-11-23 ask for it during the `rootfs` step. To change it on an installed
   system (takes effect at once; log in again to see it in the prompt):

   ```bash
   sudo hostnamectl set-hostname NEW-NAME
   sudo sed -i "s/^127\.0\.0\.1 .*/127.0.0.1 localhost NEW-NAME/" /etc/hosts
   ```

---

## Phase 3g — optional: a graphical desktop

The install above is a text console. A desktop can be added afterwards from the Mac, over SSH, with the phone on Wi-Fi
(about 5-10 min, 1.5 GB). `USER@HOST` is your Linux user and the phone's Wi-Fi address (`ip -brief addr show wlp1s0`
on the phone), or the quoted USB address `'USER@fe80::…%en13'`:

```bash
scripts/omarchy-desktop.sh gnome USER@HOST      # regular Ubuntu desktop (GNOME, GDM login screen)
ssh -i keys/omarchy-dodge_ed25519 USER@HOST sudo reboot
```

The phone then boots to a login screen; tap your user and type the password on the on-screen keyboard.

| Mode | What it is | State on this phone (2026-11-23) |
|---|---|---|
| `gnome` | Ubuntu's GNOME session with GDM | Login screen and session start; software rendered |
| `lomiri` | Lomiri, the Ubuntu Touch shell, from Ubuntu 24.04's archive | Installs, then crashes at login (qtmir); experimental |
| `phosh` | Phosh, the phone shell | Not tried yet |
| `none` | Back to the text console (packages stay) | Not tried yet |
| `status` | Shows what is configured | Works |

What the script sets up besides the packages (`scripts/phone-desktop.sh`, which is what runs on the phone and is also
left there as `sudo phone-desktop <mode>`):

- **Touch.** The Synaptics panel driver is a module nothing loads by itself; it is added to `/etc/modules-load.d/`.
- **Software rendering.** Ubuntu 24.04's Mesa has no driver for the Adreno 830, and without
  `MESA_LOADER_DRIVER_OVERRIDE=kms_swrast` the login screen crashes in a loop. Everything is drawn by the CPU.
- **Phone defaults.** Scale 3 on the 1440x3168 panel, on-screen keyboard on, no automatic suspend, power key ignored.

Ubuntu Touch itself cannot be installed: its ports sit on each phone's Android kernel and there is none for the
OnePlus 13 (the newest OnePlus on its device list is the Nord 2). SSH and the USB serial console keep working whatever
the desktop does, so a broken desktop is undone with `scripts/omarchy-desktop.sh none USER@HOST` and a reboot.

---

## Going back

- **Android again, keeping Linux installed**: `scripts/omarchy-install-slot-b.sh back-to-android` (Android needs a factory reset because userdata is now ext4).
- **Full return to stock and relock**: step-by-step in `docs/ONEPLUS13-revert-to-stock.md`. In short (user types the serial for each write): `scripts/omarchy-install-slot-b.sh revert-stock`, let stock recovery "Format data", confirm Android boots with `release-keys`, then `scripts/omarchy-install-slot-b.sh lock`. The script verifies the stock set against the phone's own vbmeta first; never relock with any non-stock partition present.
- **Root only, undo**: `scripts/android-tool.sh restore init_boot`.

## Where things are

| What | Where |
|---|---|
| Logs of every tool run | `logs/` |
| Device profile (serial, lock state, stock dir) | `profiles/device-profile.env` |
| Stock images, dumps, built images | `firmware/images/` (gitignored) |
| Detailed history and every lesson learned | `docs/linux-compatibility.md`, `docs/rooting.md`, `docs/bootloader.md` |
| Inputs with links and checksums | `DOWNLOADS.md`, `checksums/inputs.sha256` |
