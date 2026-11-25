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
scripts/omarchy-build-phone.sh initramfs        # runs detached, takes seconds
scripts/omarchy-build-phone.sh status            # wait for INITRAMFS-DONE before the next line: chain needs the finished initramfs
scripts/omarchy-build-phone.sh chain            # about 10 min; log ends in CHAIN-DONE (printed only when the image was packed)
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

## Phase 3d — build the root filesystem (Ubuntu or Arch Linux)

The `rootfs` step asks two things about the system: which one to build, and then whether you want a GUI
(a yes/no question). `OMARCHY_FLAVOR=server|minimal|arch` and `OMARCHY_DESKTOP=none|gnome` skip the questions.

| System | What you get |
|---|---|
| `server` (default) | **Ubuntu Server 24.04**: Ubuntu Base plus the `ubuntu-minimal`, `ubuntu-standard` and `ubuntu-server` package sets, the same seeds a server image is built from |
| `minimal` | Bare Ubuntu 24.04: only what the phone needs to boot, join a network and be reached over SSH; about 350 MB smaller |
| `arch` | **Arch Linux ARM** (rolling release): base system, network, SSH and the usual command-line tools |

| GUI | What you get |
|---|---|
| no (`none`) | Text console on the phone screen (login prompt), serial console and SSH |
| yes (`gnome`) | **GNOME** with the GDM login screen, on-screen keyboard, terminal, browser, file manager and settings. Adds about 1.5 GB on Ubuntu and about 3 GB on Arch |

Two things a stock server install has are left out of `server` on purpose: `snapd` and `cloud-init` (cloud-init would
rewrite the network and SSH setup at first boot). `multipathd` is masked so it leaves the phone's UFS LUNs alone, and
NetworkManager stays in charge of Wi-Fi and USB networking.

About `arch` (added 2026-11-24):

- It starts from Arch Linux ARM's official root tarball, downloaded on the phone during this step (830 MB) and accepted
  only with a valid signature from the Arch Linux ARM build key. `scripts/arch-rootfs.sh` then removes the generic
  kernel and its firmware, upgrades, and sets up the system. Kernel, boot image and install steps are the same as
  for Ubuntu.
- The default `alarm` account of Arch Linux ARM is removed and root is locked. SSH accepts only the project key.

About the `gnome` desktop (on Ubuntu it is added by `scripts/ubuntu-gnome-rootfs.sh`, on Arch by `scripts/arch-rootfs.sh`):

- The password also unlocks the screen, typed on the on-screen keyboard, so a short one or a PIN is practical. For
  that reason SSH accepts only the project key when a desktop is chosen (no password login).
- Graphics are drawn by the CPU (software rendering), so animations are slow. The Adreno 830 does not start on this
  kernel: its `gen80000_zap.mbn` firmware is missing. To try the GPU once that is solved, delete
  `/etc/environment.d/50-oneplus13-software-gl.conf` and the two matching lines in `/etc/environment` on the phone,
  then reboot. SSH over USB keeps working if the screen does not come up.
- What has run on the phone: GNOME on Arch (2026-11-24, installed on the running system after a first build with
  the Phosh phone shell) and GNOME on Ubuntu with the same package set (2026-11-23, also installed on the running
  system). An image built with the desktop from scratch by this step has **not been booted yet**; the build itself
  was run in containers.
- The lock-screen and login keyboard is GNOME's own. If the screen stays on the text console, log in over SSH and
  look at `journalctl -b -u gdm`.

**(you type)** asks, in this order, for the system, GUI yes or no, the device name (hostname; no default, you must
enter one), the Linux user name and the password (twice, no echo) (`OMARCHY_FLAVOR`, `OMARCHY_HOSTNAME`,
`OMARCHY_USER`, `OMARCHY_PASSWORD`, `OMARCHY_DESKTOP` skip the prompts). Run it from Terminal.app, not from inside another tool: without a
terminal it stops with a message. It runs detached, about 20 min for Ubuntu and 30 to 40 min for Arch, longer with the desktop; `status` shows the log.

```bash
scripts/omarchy-build-phone.sh rootfs
scripts/omarchy-build-phone.sh status            # until ROOTFS-DONE
scripts/omarchy-build-phone.sh verify-rootfs     # flavor, services, your user, kernel modules, ath12k firmware set
scripts/omarchy-build-phone.sh mkimage           # minimal ext4 image (about 2 GB for Ubuntu, 5 GB for Arch with GNOME)
scripts/omarchy-build-phone.sh pull-rootfs       # copy to the Mac, compare sha256 with the phone's, write the .sparse.img
```

`verify-rootfs` must show no `MISSING` line; for `server` the `ubuntu-server:` line must say `install ok installed`, with
the `gnome` desktop the `desktop:` line must say `login screen enabled`.

`pull-rootfs` leaves two files in `firmware/images/omarchy-dodge-rootfs-<date>/`: the raw image and a `.sparse.img`.
The sparse file is the one to flash. On 2026-11-24 `fastboot flash userdata` failed on the 2.3 GB raw `server` image
before sending anything (the 1.9 GB `minimal` images of earlier runs went through raw); `scripts/img2simg.py` writes the
sparse file and accepts it only when it expands to exactly the raw image. The Arch sparse file is about 3.4 GB, larger
than any flashed so far: if fastboot refuses it, the error is printed and nothing is written.

---

## Phase 3e — install to slot b (three writes, each confirmed with the serial)

Android stays on slot a but loses its data (userdata becomes the Linux root). The script's preflight checks the GPT
backup, the stock set, the key, and that fastboot sees the phone; every write stops unless fastboot reports OKAY.

**(you type)** each line asks for the phone's serial:

```bash
scripts/omarchy-install-slot-b.sh preflight
scripts/omarchy-install-slot-b.sh userdata firmware/images/omarchy-dodge-rootfs-*/rootfs-*.sparse.img
scripts/omarchy-install-slot-b.sh boot_b   firmware/images/omarchy-dodge-chain-dbg-*/boot-chain-install-dbg-avb.img
scripts/omarchy-install-slot-b.sh activate
```

The `userdata` step must print `Sending sparse 'userdata'` / `Writing 'userdata' OKAY` lines and end with
"userdata written". If it does not, stop: with boot_b and `activate` done but no root filesystem, the phone only
reaches the rescue initramfs (root over SSH, `cannot mount /dev/sda15` in dmesg). Recover by holding Volume Down
while it restarts to get fastboot, flash userdata, then `tools/platform-tools/fastboot reboot`.

The text login appears on the phone screen within about a minute (your user name and password). With the `gnome`
desktop the GNOME login screen appears instead: tap your name and enter the password. From the Mac (the serial console and SSH work
the same for every flavor):

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

2. **Wi-Fi** (NetworkManager, saved with autoconnect; `sudo` is required because the minimal image has no polkit).
   Under GNOME the Wi-Fi page of Settings does the same from the screen:

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

4. **Device name.** The `rootfs` step asks for it (since 2026-11-24; images built before that are named
   `oneplus13`). The phone answers to `<name>.local` on USB and Wi-Fi. To change it on an installed
   system (takes effect at once; log in again to see it in the prompt):

   ```bash
   sudo hostnamectl set-hostname NEW-NAME
   sudo sed -i "s/^127\.0\.0\.1 .*/127.0.0.1 localhost NEW-NAME/" /etc/hosts
   ```

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
