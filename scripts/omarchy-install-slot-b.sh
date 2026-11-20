#!/usr/bin/env bash
# Install native Linux on slot b of the OnePlus 13 (dodge). Three writes, each gated by typing the
# phone's serial. Android stays on slot a (its data is erased with userdata; a factory reset brings it back).
#
#   scripts/omarchy-install-slot-b.sh preflight          checks only: images, checksums, backups, fastboot over USB 2.0
#   scripts/omarchy-install-slot-b.sh userdata <img>     WRITE 1: fastboot flash userdata <ext4 rootfs image>   (erases Android data)
#   scripts/omarchy-install-slot-b.sh boot_b <img>       WRITE 2: fastboot flash boot_b <boot-chain-install.img>
#   scripts/omarchy-install-slot-b.sh activate           WRITE 3: fastboot set_active b, then reboot into Linux
#   scripts/omarchy-install-slot-b.sh back-to-android    fastboot set_active a (Android needs a factory reset afterwards)
#   scripts/omarchy-install-slot-b.sh revert-stock       UNDO: flash stock boot_b + init_boot_a (phone's own images, hashes checked), set_active a, reboot;
#                                                        stock recovery then offers "Format data" (userdata holds the ext4 rootfs) -> wipe -> stock Android
#   scripts/omarchy-install-slot-b.sh lock               fastboot flashing lock (wipes data again). Only after revert-stock AND a verified stock Android boot.
#
# After the first clean Linux boot, mark slot b "successful" (GPT attribute bit 54 on boot_b) from inside
# Linux with sgdisk, or ABL burns one of 6 retries per boot and falls back to slot a. GPT head/tail of every
# LUN is backed up in firmware/images/Original-*-allfw-*/gpt/.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
ADB="$HERE/tools/platform-tools/adb"; FB="$HERE/tools/platform-tools/fastboot"
PROFILE="$HERE/profiles/device-profile.env"
SERIAL=$(awk -F= '$1=="SERIAL"{print $2; exit}' "$PROFILE" 2>/dev/null)
[ -n "$SERIAL" ] || { echo "no SERIAL in profiles/device-profile.env: run scripts/android-tool.sh discover first" >&2; exit 1; }
# Stock images of THIS phone: STOCK_DIR from the profile (set by extract-boot / backup), else the newest device dump.
stock_dir() {
    local d; d=$(awk -F= '$1=="STOCK_DIR"{v=$2} END{print v}' "$PROFILE" 2>/dev/null)
    case "$d" in "") ;; /*) ;; *) d="$HERE/$d" ;; esac
    [ -n "$d" ] && [ -f "$d/Original-init_boot.img" ] && { echo "$d"; return; }
    ls -d "$HERE"/firmware/images/Original-*-device-stock 2>/dev/null | tail -1
}
LOG="$HERE/logs/install-slot-b.log"; mkdir -p "$HERE/logs"
say() { printf '\n==> %s\n' "$*" | tee -a "$LOG"; }
die() { printf '\n!!  %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

confirm() { # $1 description
    cat <<MSG
################################################################################
HIGH RISK WRITE: $1
Device serial: $SERIAL
Type the serial exactly to proceed, anything else to abort.
################################################################################
MSG
    printf 'Serial: '; read -r typed </dev/tty || die "no tty"
    [ "$typed" = "$SERIAL" ] || die "Serial did not match. Aborted."
}
# Run one fastboot write, log it, and stop unless fastboot exited 0 AND printed "Writing ... OKAY".
# (fastboot 37.0.3 on macOS fails with "Failed reading from <part>" on raw images >= 4 GiB, before sending anything.)
fb_write() { # $1 partition, $2 image
    local out rc
    out=$($FB flash "$1" "$2" </dev/null 2>&1); rc=$?
    printf '%s\n' "$out" | tee -a "$LOG"
    [ $rc -eq 0 ] && printf '%s\n' "$out" | grep -q "Writing '$1'.*OKAY" || die "fastboot flash $1 FAILED (exit $rc): nothing to trust on the device for this partition; see above"
}

to_fastboot() {
    if $FB devices </dev/null | grep -q "$SERIAL"; then return 0; fi
    if $ADB get-state </dev/null 2>/dev/null | grep -q device; then
        say "adb reboot bootloader"; $ADB reboot bootloader </dev/null
    else
        say "Put the phone in fastboot (it may be booting Linux: run 'reboot bootloader' there, or hold Power+Vol-Down)"
    fi
    for i in $(seq 1 90); do $FB devices </dev/null | grep -q "$SERIAL" && return 0; sleep 2; done
    die "fastboot never saw $SERIAL (USB 2.0 cable through the dock?)"
}
preflight() {
    say "Preflight"
    local gpt; gpt=$(ls -d "$HERE"/firmware/images/Original-*/gpt 2>/dev/null | tail -1)
    [ -n "$gpt" ] && ls "$gpt"/sd?-head.bin "$gpt"/sd?-tail.bin >/dev/null 2>&1 || die "no GPT backup (scripts/android-tool.sh backup gpt, from rooted Android)"
    say "GPT backup: ${gpt#$HERE/} ($(ls "$gpt"/*-head.bin | wc -l | tr -d ' ') LUNs)"
    [ -n "$(stock_dir)" ] || die "no stock images of this phone (scripts/android-tool.sh backup, then copy the active-slot set to firmware/images/Original-<build>-device-stock/)"
    [ -f "$HERE/keys/omarchy-dodge_ed25519" ] || die "no keys/omarchy-dodge_ed25519 (the key baked into the rootfs/initramfs by omarchy-build-phone.sh)"
    to_fastboot
    say "fastboot vars: slot=$($FB getvar current-slot 2>&1 </dev/null | awk -F': ' '/current-slot/{print $2}') unlocked=$($FB getvar unlocked 2>&1 </dev/null | awk -F': ' '/unlocked/{print $2}') max-download=$($FB getvar max-download-size 2>&1 </dev/null | awk -F': ' '/max-download/{print $2}')"
    say "slot-successful a/b: $($FB getvar slot-successful:a 2>&1 </dev/null | awk -F': ' '/slot-successful/{print $2}') / $($FB getvar slot-successful:b 2>&1 </dev/null | awk -F': ' '/slot-successful/{print $2}')  retry a/b: $($FB getvar slot-retry-count:a 2>&1 </dev/null | awk -F': ' '/retry/{print $2}') / $($FB getvar slot-retry-count:b 2>&1 </dev/null | awk -F': ' '/retry/{print $2}')"
    say "preflight ok"
}
case "${1:-}" in
preflight) preflight ;;
userdata)
    img=${2:?rootfs image}; [ -f "$img" ] || die "no $img"
    file "$img" | tee -a "$LOG" | grep -q -E 'ext4|ext2|Android sparse' || die "$img is not an ext4 or sparse image"
    preflight
    confirm "fastboot flash userdata $(basename "$img")  — ERASES all Android data (apps, photos, the Ubuntu chroot)"
    sz=$(stat -f %z "$img"); [ "$sz" -lt 4294967296 ] || die "$img is $sz bytes: fastboot on macOS cannot read raw images >= 4 GiB. Use the minimal image from 'omarchy-build-phone.sh mkimage' (the Omarchy init grows it to the whole partition on first boot)."
    fb_write userdata "$img"
    say "userdata written" ;;
boot_b)
    img=${2:?boot-chain-install.img}; [ -f "$img" ] || die "no $img"
    python3 -I - "$img" <<'PY' || die "image check failed"
import struct,sys
b=open(sys.argv[1],"rb").read(); ks,rs=struct.unpack_from("<II",b,8); hv,=struct.unpack_from("<I",b,40)
assert hv==4 and rs==0 and ks>0 and len(b)<=96*1024*1024, "not a kernel-only v4 image under 96 MiB"
assert b"rdinit=/omamobile/init" in b, "no stage-1 chainloader marker"
assert b"omamobile.initramfs" not in b, "this is the test image (stays in initramfs); use boot-chain-install.img"
# vbmeta_b chains `boot` to a vbmeta in the partition's own AVB footer; ABL (unlocked) accepts any key and a stale
# hash but refuses a chained partition with no footer at all: the flashed boot resets ~10 s after the yellow screen.
# So the image must be padded to the 96 MiB partition with an AVB footer (avbtool add_hash_footer, AOSP test key).
foot=b[-64:]
assert foot[:4]==b"AVBf" and len(b)==96*1024*1024, "no AVB footer / not padded to the 96 MiB boot partition (ABL refuses it when flashed)"
import struct; voff,vsz=struct.unpack_from(">QQ",foot,20); assert b[voff:voff+4]==b"AVB0", "footer points at no vbmeta"
print("boot_b image ok:", len(b), "bytes, kernel", ks, "bytes, AVB footer with vbmeta at", voff)
PY
    preflight
    confirm "fastboot flash boot_b $(basename "$img")  (slot a's boot_a is untouched)"
    fb_write boot_b "$img"
    say "boot_b written" ;;
activate)
    preflight
    confirm "fastboot set_active b  — next boot runs Linux from slot b (6 retries before ABL falls back to slot a)"
    $FB set_active b </dev/null 2>&1 | tee -a "$LOG"
    say "current-slot now: $($FB getvar current-slot 2>&1 </dev/null | awk -F': ' '/current-slot/{print $2}')"
    confirm "fastboot reboot  (into Linux on slot b)"
    $FB reboot </dev/null 2>&1 | tee -a "$LOG" ;;
revert-stock)
    ST=$(stock_dir); [ -n "$ST" ] || die "no stock images"
    # The stock set must be THIS phone's own dump (byte-identical to what the OEM signed), checked two ways:
    # its SHA256SUMS, and scripts/avb-verify.py proving init_boot matches the hash descriptor in vbmeta and
    # boot's AVB footer is signed with the key vbmeta chains to. Only then will a LOCKED bootloader accept the bytes.
    say "stock set: ${ST#$HERE/}"
    (cd "$ST" && shasum -a 256 -c SHA256SUMS 2>&1 | grep -E 'Original-(boot|init_boot|vbmeta)\.img' | tee -a "$LOG" | grep -qv ': OK$' && exit 1; true) || die "SHA256SUMS mismatch in $ST"
    python3 -I "$HERE/scripts/avb-verify.py" "$ST/Original-vbmeta.img" "$ST/Original-boot.img" "$ST/Original-init_boot.img" > "$LOG.avb" 2>&1; rc=$?
    cat "$LOG.avb" | tee -a "$LOG"; rm -f "$LOG.avb"; [ "$rc" = 0 ] || die "stock images fail the AVB check: do not flash, do not lock"
    preflight
    confirm "fastboot flash boot_b Original-boot.img  (stock boot over the Linux chain image; Linux on slot b is gone after this)"
    fb_write boot_b "$ST/Original-boot.img"
    confirm "fastboot flash init_boot_a Original-init_boot.img  (stock over Magisk; root is gone after this)"
    fb_write init_boot_a "$ST/Original-init_boot.img"
    confirm "fastboot set_active a  (stock Android slot; it will stop in stock recovery asking to Format data because userdata holds the ext4 rootfs)"
    $FB set_active a </dev/null 2>&1 | tee -a "$LOG"
    say "current-slot now: $($FB getvar current-slot 2>&1 </dev/null | awk -F': ' '/current-slot/{print $2}')  slot-successful a: $($FB getvar slot-successful:a 2>&1 </dev/null | awk -F': ' '/slot-successful/{print $2}')"
    confirm "fastboot reboot  (into Android slot a -> stock recovery -> choose Format data / wipe, then let Android boot and set it up)"
    $FB reboot </dev/null 2>&1 | tee -a "$LOG"
    say "After Android boots: Settings > About > tap Version 7x; Developer options: OEM unlocking ON, USB debugging ON. Then: $0 lock" ;;
lock)
    say "Locking requires: revert-stock done, stock Android booted and set up, OEM unlocking ON (so the phone can be unlocked again later)."
    say "A locked bootloader with any non-stock partition does not boot and may not be recoverable without OPPO's MSM tool. Lock only after revert-stock on a phone whose other partitions were never written (hash both slots first if in doubt)."
    preflight
    say "unlocked=$($FB getvar unlocked 2>&1 </dev/null | awk -F': ' '/unlocked/{print $2}')  current-slot=$($FB getvar current-slot 2>&1 </dev/null | awk -F': ' '/current-slot/{print $2}')"
    confirm "fastboot flashing lock  — WIPES data again, relocks the bootloader; confirm on the phone with the volume keys"
    $FB flashing lock </dev/null 2>&1 | tee -a "$LOG"
    say "lock issued; getvar unlocked: $($FB getvar unlocked 2>&1 </dev/null | awk -F': ' '/unlocked/{print $2}')" ;;
back-to-android)
    preflight
    confirm "fastboot set_active a  — boots stock Android; it will need a factory reset because userdata was replaced"
    $FB set_active a </dev/null 2>&1 | tee -a "$LOG"; $FB reboot </dev/null ;;
*) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
