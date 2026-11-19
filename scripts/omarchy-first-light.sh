#!/usr/bin/env bash
# RAM-only first-light test of the Omarchy chain image on the OnePlus 13 (dodge).
# Nothing is flashed: `fastboot boot` loads the image into RAM; a failed boot returns to stock Android.
#
#   scripts/omarchy-first-light.sh <boot-chain.img>     boot it, then watch for the USB gadget and try SSH
#   scripts/omarchy-first-light.sh --watch               only watch (image already booted)
#
# Prerequisites: phone on the USB 2.0 cable (bootloader is invisible over USB 3), Android running with adb,
# keys/omarchy-dodge_ed25519 present. The Mac side of the USB network needs 172.16.42.2/24 on the new
# interface, which this script sets with sudo (it asks for your password).
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
ADB="$HERE/tools/platform-tools/adb"; FB="$HERE/tools/platform-tools/fastboot"
KEY="$HERE/keys/omarchy-dodge_ed25519"
IMG=${1:-}
LOG="$HERE/logs/first-light-$(date +%Y%m%d-%H%M%S).log"; mkdir -p "$HERE/logs"
say() { printf '\n==> %s\n' "$*" | tee -a "$LOG"; }
baseline_if() { networksetup -listallhardwareports | awk '/Device:/{print $2}' | sort; }

if [ "$IMG" != "--watch" ]; then
    [ -f "$IMG" ] || { echo "no image: $IMG"; exit 1; }
    python3 -I - "$IMG" <<'PY'
import struct,sys
b=open(sys.argv[1],"rb").read(4096)
assert b[:8]==b"ANDROID!", "not a boot image"
ks,rs=struct.unpack_from("<II",b,8); hv,=struct.unpack_from("<I",b,40)
print(f"boot image: header v{hv} kernel={ks} ramdisk={rs} ({'kernel-only, as dodge-chain packs it' if rs==0 else 'HAS RAMDISK: not the chain image'})")
assert hv==4 and rs==0 and ks>0
PY
    before=$(baseline_if)
    say "Phone state: $($ADB devices </dev/null | tail -n +2 | tr '\n' ' ') / fastboot: $($FB devices </dev/null | tr '\n' ' ')"
    if $ADB get-state </dev/null 2>/dev/null | grep -q device; then
        say "Rebooting to the bootloader (adb reboot bootloader)"
        $ADB reboot bootloader </dev/null
    fi
    say "Waiting for fastboot"
    for i in $(seq 1 60); do $FB devices </dev/null | grep -q . && break; sleep 2; done
    $FB devices </dev/null | grep -q . || { say "bootloader never appeared on USB (USB 2.0 cable?)"; exit 1; }
    say "fastboot boot $IMG   (RAM only)"
    $FB boot "$IMG" </dev/null 2>&1 | tee -a "$LOG"
else
    before=""
fi

say "Watching for the USB gadget (CDC NCM interface + ACM serial) for up to 120 s"
newif=""; serial=""
for i in $(seq 1 60); do
    after=$(baseline_if)
    if [ -n "$before" ]; then newif=$(comm -13 <(echo "$before") <(echo "$after") | head -1); fi
    serial=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
    [ -n "$newif" ] || [ -n "$serial" ] && break
    sleep 2
done
say "new interface: ${newif:-none}   serial: ${serial:-none}   adb: $($ADB devices </dev/null | tail -n +2 | tr '\n' ' ')"
if [ -n "$newif" ]; then
    say "Assigning 172.16.42.2/24 to $newif (sudo)"
    sudo ifconfig "$newif" 172.16.42.2 netmask 255.255.255.0 up
    sleep 2; ping -c 2 -t 3 172.16.42.1 | tail -2 | tee -a "$LOG" || true
    say "ssh root@172.16.42.1 (host key is fresh each boot; checking is disabled for this address)"
    ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 root@172.16.42.1 \
        'uname -a; cat /proc/device-tree/model; echo; dmesg | tail -20; cat /run/ufs-probe.txt 2>/dev/null | head -30' 2>&1 | tee -a "$LOG" || true
fi
[ -n "$serial" ] && say "Serial console available: screen $serial 115200   (Ctrl-A K to quit)"
say "log: ${LOG#$HERE/}"
