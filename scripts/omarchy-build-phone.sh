#!/usr/bin/env bash
# Build the Omarchy Mobile (mainline) kernel chain for the OnePlus 13 (dodge) INSIDE
# the phone's Ubuntu chroot (/data/local/ubuntu). Run from the Mac; each step is
# launched over adb as root and logs to /root/build-*.log in the chroot.
#
#   scripts/omarchy-build-phone.sh stage2     # kernel: defconfig + omamobile.config + sm8750.config -> Image, dtbs, modules
#   scripts/omarchy-build-phone.sh initramfs  # stage-2 initramfs: Alpine minirootfs + dropbear/kexec/e2fsprogs + shared init
#   scripts/omarchy-build-phone.sh chain      # stage-2 DTB (live memory map), stage-1 kernel, boot-chain.img (header v4)
#   scripts/omarchy-build-phone.sh vendor-fw  # stage this phone's Wi-Fi/BT/GPU firmware from Android (+ tmel from modem_a) into /root/dl/vendor-fw
#   scripts/omarchy-build-phone.sh rootfs     # root file system for userdata -> /root/out/rootfs-<system>-dodge.img (ext4, label omamobile-root)
#                                             #   asks for the flavor (OMARCHY_FLAVOR): server (Ubuntu Server 24.04, default), minimal (bare Ubuntu),
#                                             #   or arch (Arch Linux ARM; scripts/arch-rootfs.sh),
#                                             #   then GUI yes or no (OMARCHY_DESKTOP): gnome or none (text console), for any system,
#                                             #   then the device name, Linux user name and password (OMARCHY_HOSTNAME / OMARCHY_USER /
#                                             #   OMARCHY_PASSWORD env for unattended runs; the device name has no default;
#                                             #   SSH takes that password or the project key; root is key only)
#   scripts/omarchy-build-phone.sh verify-rootfs | mkimage   # check the built root; make the minimal ext4 image from it
#   scripts/omarchy-build-phone.sh pull-rootfs               # copy that image to firmware/images/omarchy-dodge-rootfs-<ts>/ on the Mac,
#                                             #   compare its sha256 with the phone's, and write the .sparse.img that gets flashed
#   scripts/omarchy-build-phone.sh pull       # copy build outputs to firmware/images/omarchy-dodge/ on the Mac
#   scripts/omarchy-build-phone.sh status     # tail the logs
#
#   scripts/omarchy-build-phone.sh toolchain  # apt: clang/lld + make/bison/flex/bc/libssl/libelf, dtc, lz4, cpio, e2fsprogs (idempotent; stage2 runs it)
#   scripts/omarchy-build-phone.sh sources    # FIRST: clone kernel/omarchy-mobile/mkbootimg, Alpine minirootfs + apks,
#                                             #        live DTB (/sys/firmware/fdt), SSH public key -> /root/{src,dl} in the chroot
# Inputs the steps expect in the chroot (created by `sources`):
#   /root/src/linux           mrlund/linux-omarchy-mobile tag dodge-v3-20261101 (7.3.0-rc6)
#   /root/src/omarchy-mobile  derekross/omarchy-mobile main
#   /root/src/mkbootimg       AOSP system/tools/mkbootimg
#   /root/dl/alpine-minirootfs-3.24.2-aarch64.tar.gz, /root/dl/apks/*.apk, /root/dl/live.dtb, /root/dl/authorized_keys
# The SSH key pair keys/omarchy-dodge_ed25519 is generated here if missing (the private key is gitignored).
# Nothing here touches the phone's partitions. Flashing is a separate, confirmed step.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
ADB="$HERE/tools/platform-tools/adb"
R=/data/local/ubuntu
su_sh() { local b; b=$(printf '%s' "$1" | base64); "$ADB" shell "su -c 'echo $b | /data/adb/magisk/busybox base64 -d | sh'" </dev/null | tr -d '\r'; }
in_ubuntu_bg() { # $1 log name, $2 script body: copied to /root/steps/<name>.sh in the chroot and run detached
    local tmp; tmp=$(mktemp)
    printf '#!/bin/bash\n%s\n' "$2" > "$tmp"
    "$ADB" push "$tmp" /data/local/tmp/.step </dev/null >/dev/null; rm -f "$tmp"
    su_sh "mkdir -p $R/root/steps && cp /data/local/tmp/.step $R/root/steps/$1.sh && chmod 755 $R/root/steps/$1.sh && rm /data/local/tmp/.step"
    su_sh "$R/start.sh /bin/bash -c 'nohup setsid bash /root/steps/$1.sh > /root/build-$1.log 2>&1 < /dev/null & disown'"
    echo "launched: /root/steps/$1.sh -> /root/build-$1.log"
}

in_ubuntu_run() { # $1 step name, $2 script body: copied to /root/steps/<name>.sh and run synchronously, output returned
    local tmp; tmp=$(mktemp)
    printf '#!/bin/bash\n%s\n' "$2" > "$tmp"
    "$ADB" push "$tmp" /data/local/tmp/.step </dev/null >/dev/null; rm -f "$tmp"
    su_sh "mkdir -p $R/root/steps && cp /data/local/tmp/.step $R/root/steps/$1.sh && chmod 755 $R/root/steps/$1.sh && rm /data/local/tmp/.step"
    su_sh "$R/start.sh /bin/bash /root/steps/$1.sh 2>&1"
}

# Ask for the user account of the native Linux install. Nothing is hard-coded: the name defaults to the
# Mac login name, the password is read twice without echo and only its SHA-512 crypt hash leaves the Mac.
# OMARCHY_USER / OMARCHY_PASSWORD in the environment skip the prompts (CI, scripted rebuilds).
ask_linux_user() {
    local def p1 p2 b
    def=$(id -un)
    OUSER=${OMARCHY_USER:-}
    OHOST=${OMARCHY_HOSTNAME:-}
    if { [ -z "$OUSER" ] || [ -z "$OHOST" ] || [ -z "${OMARCHY_PASSWORD:-}" ]; } && ! { : </dev/tty; } 2>/dev/null; then
        cat >&2 <<MSG
No terminal to ask for the device name, Linux user name and password (e.g. started with the '!' prefix or from a script).
Run this in a normal Terminal window:   scripts/omarchy-build-phone.sh rootfs
or set OMARCHY_HOSTNAME, OMARCHY_USER and OMARCHY_PASSWORD in the environment for an unattended run.
MSG
        exit 1
    fi
    # The device name (hostname) has no default: it is how the phone shows up on the network (<name>.local).
    while [ -z "$OHOST" ]; do
        printf 'Device name for the phone (its hostname; letters, digits, hyphens): '; read -r OHOST </dev/tty || true
    done
    printf '%s' "$OHOST" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' || { echo "invalid device name '$OHOST' (letters, digits and hyphens, at most 63, no hyphen at either end)"; exit 1; }
    OHOST=$(printf '%s' "$OHOST" | tr 'A-Z' 'a-z')
    if [ -z "$OUSER" ]; then
        printf 'Linux user name for the phone [%s]: ' "$def"; read -r OUSER </dev/tty || true; OUSER=${OUSER:-$def}
    fi
    printf '%s' "$OUSER" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || { echo "invalid user name '$OUSER' (lowercase letters, digits, _ -)"; exit 1; }
    [ "$OUSER" != root ] || { echo "root stays locked; pick another name"; exit 1; }
    p1=${OMARCHY_PASSWORD:-}
    while [ -z "$p1" ]; do
        if [ "${OFLAVOR:-}" = arch ]; then printf 'Password or PIN for %s (it unlocks the screen): ' "$OUSER"; else printf 'Password for %s: ' "$OUSER"; fi
        read -rs p1 </dev/tty; echo
        printf 'Repeat: '; read -rs p2 </dev/tty; echo
        [ -n "$p1" ] && [ "$p1" = "$p2" ] || { echo "empty or mismatch, try again"; p1=; continue; }
    done
    # crypt(3) SHA-512 hash: on the Mac when its openssl supports -6, otherwise inside the Ubuntu chroot
    OHASH=$(printf '%s' "$p1" | openssl passwd -6 -stdin 2>/dev/null) || OHASH=
    if [ -z "$OHASH" ]; then
        b=$(printf '%s' "$p1" | base64)
        OHASH=$(su_sh "$R/start.sh /bin/bash -c 'echo $b | base64 -d | openssl passwd -6 -stdin'")
    fi
    unset p1 p2
    case "$OHASH" in '$6$'*) ;; *) echo "password hashing failed"; exit 1 ;; esac
}

KEY="$HERE/keys/omarchy-dodge_ed25519"
if [ ! -f "$KEY" ]; then mkdir -p "$HERE/keys"; ssh-keygen -q -t ed25519 -N '' -C omarchy-dodge -f "$KEY"; echo "generated $KEY (gitignored; it is the only way into the built images)"; fi
# The public half can be lost on its own (it is derived, so write it again from the private key).
[ -f "$KEY.pub" ] || { ssh-keygen -y -f "$KEY" > "$KEY.pub"; echo "rewrote $KEY.pub from the private key"; }

TOOLCHAIN_PKGS="clang lld llvm make bc bison flex libssl-dev libelf-dev libdw-dev build-essential pkg-config python3 python3-pip device-tree-compiler libfdt-dev lz4 zstd xz-utils cpio rsync kmod dwarves file git curl ca-certificates e2fsprogs gdisk util-linux"
# Graphical desktop on top of the chosen system, asked right after the system (a yes/no question). OMARCHY_DESKTOP skips the question; without a terminal
# the answer is none. There is no default at the prompt: the choice changes the image by 1.5 to 3 GB.
#   none   text console on the phone screen (login prompt), SSH
#   gnome  GNOME with the GDM login screen, on-screen keyboard, software rendering
ask_desktop() {
    local a
    ODESK=${OMARCHY_DESKTOP:-}
    if [ -z "$ODESK" ] && { : </dev/tty; } 2>/dev/null; then
        while [ -z "$ODESK" ]; do
            printf 'Do you want a GUI (the GNOME desktop, with a login screen and on-screen keyboard)? yes or no: '
            read -r a </dev/tty || true
            case "$a" in y|Y|yes|Yes|YES|gnome) ODESK=gnome ;; n|N|no|No|NO|none) ODESK=none ;; *) echo "please answer yes or no" ;; esac
        done
    fi
    ODESK=${ODESK:-none}
    case "$ODESK" in none|gnome) ;; *) echo "OMARCHY_DESKTOP must be none or gnome"; exit 1 ;; esac
}

# Which system the root filesystem becomes. OMARCHY_FLAVOR skips the question; without a terminal the default is used.
#   server   Ubuntu Server: ubuntu-minimal + ubuntu-standard + ubuntu-server (no snapd, no cloud-init)
#   minimal  only what the phone needs to boot, network and be reached over SSH (about 350 MB smaller)
#   arch     Arch Linux ARM (rolling release)
# Every system can get the GNOME desktop on top: that is a separate yes/no question, asked next (ask_desktop).
ask_flavor() {
    local a
    OFLAVOR=${OMARCHY_FLAVOR:-}
    if [ -z "$OFLAVOR" ] && { : </dev/tty; } 2>/dev/null; then
        printf 'System for the phone:\n  1) server   Ubuntu Server 24.04 package set (default)\n  2) minimal  bare Ubuntu 24.04: boot, network, SSH\n  3) arch     Arch Linux ARM\nChoice [1]: '
        read -r a </dev/tty || true
        case "$a" in 3|arch) OFLAVOR=arch ;; 2|minimal) OFLAVOR=minimal ;; ""|1|server) OFLAVOR=server ;; *) echo "unknown choice '$a' (1, 2 or 3)"; exit 1 ;; esac
    fi
    OFLAVOR=${OFLAVOR:-server}
    case "$OFLAVOR" in server|minimal|arch) ;; *) echo "OMARCHY_FLAVOR must be server, minimal or arch, not '$OFLAVOR'"; exit 1 ;; esac
}

install_toolchain() { in_ubuntu_run toolchain "set -e; export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq --no-install-recommends $TOOLCHAIN_PKGS >/dev/null; clang --version | head -1; ld.lld --version | head -1; make --version | head -1; echo TOOLCHAIN-DONE"; }

case "${1:-}" in
toolchain)
    install_toolchain ;;
sources)
    "$ADB" push "$KEY.pub" /data/local/tmp/.authorized_keys </dev/null >/dev/null
    su_sh "mkdir -p $R/root/dl && cp /data/local/tmp/.authorized_keys $R/root/dl/authorized_keys && rm /data/local/tmp/.authorized_keys"
    # Ubuntu Base tarball for the rootfs step (same file the chroot was made from; scripts/fetch-inputs.sh downloads it)
    UB=$(ls "$HERE"/rootfs/ubuntu-base-*/ubuntu-base-*-base-arm64.tar.gz 2>/dev/null | tail -1)
    if [ -n "$UB" ] && ! su_sh "test -s $R/root/dl/$(basename "$UB") && echo have" | grep -q have; then
        echo "pushing $(basename "$UB") into the chroot"; "$ADB" push "$UB" /data/local/tmp/.ubuntu-base </dev/null >/dev/null
        su_sh "cp /data/local/tmp/.ubuntu-base $R/root/dl/$(basename "$UB") && rm /data/local/tmp/.ubuntu-base"
    fi
    body=$(cat <<'SRC'
set -e; export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq --no-install-recommends git curl ca-certificates >/dev/null
mkdir -p /root/src /root/dl/apks
[ -d /root/src/linux/.git ] || git clone --depth 1 --branch dodge-v3-20261101 https://github.com/mrlund/linux-omarchy-mobile /root/src/linux
[ -d /root/src/omarchy-mobile/.git ] || git clone --depth 1 https://github.com/derekross/omarchy-mobile /root/src/omarchy-mobile
[ -d /root/src/mkbootimg/.git ] || git clone --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg /root/src/mkbootimg
A=alpine-minirootfs-3.24.2-aarch64.tar.gz
[ -f /root/dl/$A ] || curl -fL -o /root/dl/$A https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/$A
# apks for the stage-2 initramfs, fetched with Alpine's own apk from the minirootfs (nested chroot, root only)
if [ -z "$(ls /root/dl/apks/*.apk 2>/dev/null)" ]; then
  rm -rf /root/dl/alpine-root; mkdir -p /root/dl/alpine-root; tar -xzf /root/dl/$A -C /root/dl/alpine-root
  cp /etc/resolv.conf /root/dl/alpine-root/etc/resolv.conf; mkdir -p /root/dl/alpine-root/dl
  chroot /root/dl/alpine-root /sbin/apk fetch --no-cache -R -o /dl busybox-static kexec-tools dtc libfdt e2fsprogs e2fsprogs-extra dropbear
  mv /root/dl/alpine-root/dl/*.apk /root/dl/apks/; rm -rf /root/dl/alpine-root
fi
[ -s /root/dl/live.dtb ] || cat /sys/firmware/fdt > /root/dl/live.dtb
[ -s /root/dl/ubuntu-base-24.04.5-base-arm64.tar.gz ] || echo "NOTE: the rootfs step needs /root/dl/ubuntu-base-24.04.5-base-arm64.tar.gz (the Mac side of this command pushes it from rootfs/)"
ls -la /root/dl /root/dl/apks | head -40
for d in linux omarchy-mobile mkbootimg; do (cd /root/src/$d && printf '%-16s %s\n' $d "$(git describe --tags --always)"); done
echo SOURCES-DONE
SRC
)
    in_ubuntu_run sources "$body" ;;
verify-rootfs)
    in_ubuntu_run verify-rootfs 'R=/root/rootfs; U=$(cat /root/out/linux-user.name 2>/dev/null || echo "?"); FL=$(cat /root/out/linux-flavor 2>/dev/null || echo server); DESK=$(cat /root/out/linux-desktop 2>/dev/null || echo none)
echo "flavor: $FL   desktop: $DESK   image: $(cat /root/out/rootfs-image.name 2>/dev/null || echo rootfs-ubuntu-noble-dodge.img)"
if [ "$FL" = arch ]; then
  echo "errors in log: $(grep -c -E "^error|^!!" /root/build-rootfs.log)   finished: $(grep -c ARCH-ROOTFS-DONE /root/build-rootfs.log)"
  for f in usr/lib/systemd/systemd usr/bin/sudo usr/bin/sshd usr/bin/NetworkManager usr/bin/sgdisk usr/bin/wpa_supplicant usr/bin/nmcli; do [ -e $R/$f ] && echo "ok   /$f" || echo "MISSING /$f"; done
  echo "arch: $(chroot $R pacman -Q systemd openssh networkmanager 2>&1 | tr "\n" ";") packages: $(chroot $R pacman -Qq | wc -l); generic kernel: $(chroot $R pacman -Qq linux-aarch64 2>/dev/null || echo removed)"
  echo "accounts: alarm $(grep -q "^alarm:" $R/etc/passwd && echo STILL-PRESENT || echo removed); root $(grep "^root:" $R/etc/shadow | cut -d: -f2 | cut -c1 | sed "s/^!$/locked/"); ssh passwords: $(grep -h PasswordAuthentication $R/etc/ssh/sshd_config.d/omamobile.conf)"
else
  echo "apt errors in log: $(grep -c -E "^E:|Error [0-9]" /root/build-rootfs.log)"
  for f in usr/lib/systemd/systemd usr/bin/sudo usr/sbin/sshd usr/sbin/NetworkManager usr/sbin/sgdisk usr/sbin/wpa_supplicant usr/bin/nmcli; do [ -e $R/$f ] && echo "ok   /$f" || echo "MISSING /$f"; done
  echo "(minimal: ubuntu-server below is expected to be MISSING)"
  echo "ubuntu-server: $(chroot $R dpkg-query -W -f "\${Status} \${Version}" ubuntu-server 2>/dev/null || echo MISSING); snapd: $(chroot $R dpkg-query -W -f "\${Status}" snapd 2>/dev/null || echo absent); cloud-init: $(chroot $R dpkg-query -W -f "\${Status}" cloud-init 2>/dev/null || echo absent)"
fi
echo "user: $U   device name: $(cat $R/etc/hostname 2>/dev/null)"; grep -E "^($U|root):" $R/etc/passwd; echo "sudoers: $(cat $R/etc/sudoers.d/$U 2>/dev/null)"; echo "password set: $(grep "^$U:" $R/etc/shadow | cut -d: -f2 | cut -c1-3 | sed s/^\\$6\\$/yes-sha512/)"
echo "modules: $(ls $R/lib/modules 2>/dev/null) ($(find $R/lib/modules/ -name "*.ko*" 2>/dev/null | wc -l) files); ath12k: $(ls $R/lib/modules/*/kernel/drivers/net/wireless/ath/ath12k/ 2>/dev/null | tr "\n" " ")"
echo "firmware: $(du -sh $R/lib/firmware/ 2>/dev/null | cut -f1); ath12k dir: $(ls $R/lib/firmware/ath12k/WCN7850/hw2.0 2>/dev/null | tr "\n" " "); WCN7860 link: $(readlink $R/lib/firmware/ath12k/WCN7860/hw2.0 2>/dev/null); qcom gen8: $(ls $R/lib/firmware/qcom/gen8* 2>/dev/null | wc -l)"
echo "ssh keys: root=$(wc -l < $R/root/.ssh/authorized_keys 2>/dev/null) $U=$(wc -l < $R/home/$U/.ssh/authorized_keys 2>/dev/null)"
echo "fstab: $(cat $R/etc/fstab)"; echo "nm usb0: $(grep address1 $R/etc/NetworkManager/system-connections/usb0.nmconnection 2>/dev/null)"
echo "enabled: $(ls $R/etc/systemd/system/multi-user.target.wants/ $R/etc/systemd/system/getty.target.wants/ 2>/dev/null | grep -v : | tr "\n" " ")"
if [ "$DESK" = gnome ]; then
  for f in usr/bin/gnome-shell usr/bin/gnome-session; do [ -e $R/$f ] && echo "ok   /$f" || echo "MISSING /$f"; done
  { [ -x $R/usr/bin/gdm ] || [ -x $R/usr/sbin/gdm3 ]; } && echo "ok   gdm" || echo "MISSING gdm"
  echo "desktop: gnome; default target $(basename "$(readlink $R/etc/systemd/system/default.target)"); login screen $([ -L $R/etc/systemd/system/display-manager.service ] && echo enabled || echo NOT-ENABLED); touch modules: $(grep -vc "^#" $R/etc/modules-load.d/oneplus13-touch.conf 2>/dev/null); software GL: $([ -f $R/etc/environment.d/50-oneplus13-software-gl.conf ] && echo yes || echo no)"
else
  echo "desktop: none (text console); default target $(basename "$(readlink $R/etc/systemd/system/default.target 2>/dev/null || echo multi-user.target)")"
fi
echo "size: $(du -sh $R | cut -f1)"' ;;
mkimage)
    in_ubuntu_run mkimage 'set -e; R=/root/rootfs; I=/root/out/$(cat /root/out/rootfs-image.name 2>/dev/null || echo rootfs-ubuntu-noble-dodge.img)
need_kb=$(du -sk $R | cut -f1); size_mb=$(( need_kb/1024 * 125 / 100 + 256 ))
rm -f $I; truncate -s ${size_mb}M $I
mkfs.ext4 -q -F -L omamobile-root -O ^has_journal -d $R $I
e2fsck -fn $I >/dev/null && echo fsck-ok
dumpe2fs -h $I 2>/dev/null | grep -E "volume name|Block count|Block size"
ls -la $I; sha256sum $I' ;;
pull-rootfs)
    command -v zstd >/dev/null || { echo "zstd is needed on the Mac for the transfer: brew install zstd"; exit 1; }
    N=$(su_sh "cat $R/root/out/rootfs-image.name 2>/dev/null || echo rootfs-ubuntu-noble-dodge.img")
    su_sh "test -s $R/root/out/$N && echo have" | grep -q have || { echo "no /root/out/$N in the chroot: run rootfs, then mkimage"; exit 1; }
    D="$HERE/firmware/images/omarchy-dodge-rootfs-$(date +%Y%m%d-%H%M)"; mkdir -p "$D"
    echo "compressing $N on the phone"
    su_sh "$R/start.sh /bin/bash -c 'cd /root/out && zstd -T8 -3 -q -f $N && sha256sum $N > $N.sha256'"
    su_sh "cat $R/root/out/$N.sha256" > "$D/$N.sha256"
    su_sh "cp $R/root/out/$N.zst /data/local/tmp/rootfs.img.zst && chmod 644 /data/local/tmp/rootfs.img.zst"
    "$ADB" pull /data/local/tmp/rootfs.img.zst "$D/$N.zst" </dev/null | tail -1
    su_sh "rm -f /data/local/tmp/rootfs.img.zst $R/root/out/$N.zst"
    zstd -d -q --rm "$D/$N.zst"
    a=$(shasum -a 256 "$D/$N" | cut -c1-64); b=$(cut -c1-64 "$D/$N.sha256")
    [ "$a" = "$b" ] || { echo "SHA256 MISMATCH: Mac $a, phone $b. Do not flash this copy."; exit 1; }
    echo "sha256 matches the phone's: $a"
    # fastboot on macOS fails on a large raw image; the sparse file is what gets flashed (scripts/img2simg.py checks it expands to the raw bytes)
    python3 -I "$HERE/scripts/img2simg.py" pack "$D/$N" "$D/${N%.img}.sparse.img"
    ls -la "$D"; echo "flash with: scripts/omarchy-install-slot-b.sh userdata ${D#$HERE/}/${N%.img}.sparse.img" ;;
stage2)
    install_toolchain | tail -1
    in_ubuntu_bg stage2 'set -e; export ARCH=arm64 LLVM=1; cd /root/src/linux; mkdir -p /root/out/stage2
make O=/root/out/stage2 defconfig
scripts/kconfig/merge_config.sh -m -O /root/out/stage2 /root/out/stage2/.config /root/src/omarchy-mobile/kernel/configs/omamobile.config arch/arm64/configs/sm8750.config
make O=/root/out/stage2 olddefconfig
date; make O=/root/out/stage2 -j8 Image dtbs modules; date
make O=/root/out/stage2 INSTALL_MOD_PATH=/root/out/stage2/modules-staging INSTALL_MOD_STRIP=1 modules_install >/dev/null
cat /root/out/stage2/include/config/kernel.release; echo STAGE2-BUILD-DONE' ;;
initramfs)
    in_ubuntu_bg initramfs 'set -e; S=/root/out/stage2/initramfs; rm -rf $S; mkdir -p $S; cd $S
tar -xzf /root/dl/alpine-minirootfs-3.24.2-aarch64.tar.gz -C $S
for a in /root/dl/apks/dropbear-*.apk /root/dl/apks/kexec-tools-*.apk /root/dl/apks/e2fsprogs-*.apk /root/dl/apks/lib*.apk /root/dl/apks/*-libs-*.apk /root/dl/apks/xz-libs-*.apk /root/dl/apks/zstd-libs-*.apk; do tar -xzf "$a" -C $S --exclude=.PKGINFO --exclude=".SIGN.*" --exclude=".*.sh" 2>/dev/null || true; done
install -m755 /root/src/omarchy-mobile/initramfs/init $S/init
# descriptor-derived config the shared init reads, exactly as bin/omamobile initramfs writes it for
# device/dodge/device.conf (UFS_RW="boot_b userdata", NAME="OnePlus 13"; no UFS_RW_LUNS, no board steps)
printf "boot_b userdata\n" > $S/etc/omamobile-ufs-rw
printf "running\n" > $S/etc/omamobile-ufs-rw-slot
printf "OnePlus 13\n" > $S/etc/omamobile-usb-product
rm -f $S/etc/omamobile-nfsroot $S/etc/dropbear/dropbear_*_host_key
# SSH login over the USB gadget network: the project public key (keys/omarchy-dodge_ed25519.pub on the Mac)
rm -rf $S/root/.ssh; mkdir -p $S/root/.ssh; cp /root/dl/authorized_keys $S/root/.ssh/authorized_keys; chmod 700 $S/root/.ssh; chmod 600 $S/root/.ssh/authorized_keys
for f in sbin/e2fsck usr/sbin/resize2fs usr/sbin/dumpe2fs usr/sbin/dropbear usr/sbin/kexec; do [ -x $S/$f ] || { echo "missing /$f in initramfs"; exit 1; }; done
find $S -exec touch -h -d @0 {} +
(cd $S && find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --reproducible --quiet) | lz4 -l -9 -q > /root/out/stage2/initramfs.cpio.lz4
ls -l /root/out/stage2/initramfs.cpio.lz4; echo INITRAMFS-DONE' ;;
chain)
    # CHAIN_CMDLINE / CHAIN_NAME from the caller's environment: "install" drops omamobile.initramfs so stage 2 hands over to the root on userdata
    in_ubuntu_bg chain "export CHAIN_CMDLINE='${CHAIN_CMDLINE:-}' CHAIN_NAME='${CHAIN_NAME:-test}'
set -e; export ROOT=/root/src/omarchy-mobile KERNEL_DIR=/root/src/linux STAGE2_OUT=/root/out/stage2 CHAIN_OUT=/root/out/stage2/chain
export CHAINLOAD_DIR=\$ROOT/device/dodge/chainload LIVE_DTB=/root/dl/live.dtb ALPINE_DL=/root/dl JOBS=8
export STAGE2_DTB_IN=/root/out/stage2/arch/arm64/boot/dts/qcom/sm8750-oneplus-dodge.dtb
export STAGE2_CMDLINE=\"\${CHAIN_CMDLINE:-rdinit=/init clk_ignore_unused pd_ignore_unused panic=10 console=tty0 omamobile.ufs-probe omamobile.initramfs}\"
export SLOT_SUFFIX=_b
mkdir -p \$ROOT/system/tools && ln -sfn /root/src/mkbootimg \$ROOT/system/tools/mkbootimg
cd \$ROOT && bash tools/dodge-chain pack && cp \$CHAIN_OUT/images/boot-chain.img \$CHAIN_OUT/images/boot-chain-\${CHAIN_NAME:-test}.img && echo CHAIN-DONE" ;;
pull)
    D="$HERE/firmware/images/omarchy-dodge-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$D"
    for f in chain/images/boot-chain.img arch/arm64/boot/Image arch/arm64/boot/dts/qcom/sm8750-oneplus-dodge.dtb initramfs.cpio.lz4 .config chain/.config chain/chain/stage2.dtb include/config/kernel.release; do
        "$ADB" shell "su -c 'cat $R/root/out/stage2/$f'" </dev/null > "$D/$(echo "$f" | tr '/' '_')" 2>/dev/null || true
    done
    "$ADB" shell "su -c 'cat $R/root/dl/live.dtb'" </dev/null > "$D/live.dtb" 2>/dev/null || true
    (cd "$D" && shasum -a 256 * > SHA256SUMS); ls -la "$D"
    # the layout kernel/stage1/in-container.sh expects for the Docker stage-1 build
    T="${D/omarchy-dodge-/omarchy-dodge-stage2-}"; mkdir -p "$T"
    cp "$D/arch_arm64_boot_Image" "$T/Image"; cp "$D/.config" "$T/.config"; cp "$D/initramfs.cpio.lz4" "$T/"
    cp "$D/arch_arm64_boot_dts_qcom_sm8750-oneplus-dodge.dtb" "$T/sm8750-oneplus-dodge.dtb"; cp "$D/include_config_kernel.release" "$T/kernel.release"
    (cd "$T" && shasum -a 256 Image initramfs.cpio.lz4 sm8750-oneplus-dodge.dtb > SHA256SUMS); echo "stage-1 inputs: ${T#$HERE/}" ;;
vendor-fw)
    # Copies, as root in the chroot (/vendor and /dev/block are visible through the bound /dev and the Android mounts),
    # the firmware this phone's Android uses: WCN7860 "peach" Wi-Fi, "brh" Bluetooth, Adreno gen8 GPU, and the TME-Lite
    # patches that live on the modem_a partition (FAT16, 4 KiB sectors). The rootfs step maps them to the names mainline asks for.
    in_ubuntu_run vendor-fw 'set -e; V=/root/dl/vendor-fw/lib/firmware/vendor-raw; rm -rf /root/dl/vendor-fw; mkdir -p $V/peach $V/bt $V/gpu $V/modem-image
ANDROID=/proc/1/root   # Android'"'"'s root as seen from inside the chroot
cp -a $ANDROID/vendor/firmware_mnt/image/peach/. $V/peach/ 2>/dev/null || cp -a $ANDROID/vendor/firmware_mnt/image/*peach*/. $V/peach/
cp -a $ANDROID/vendor/bt_firmware/image/. $V/bt/ 2>/dev/null || true
cp -a $ANDROID/vendor/firmware/gen8*  $V/gpu/ 2>/dev/null || true
# tmel_peach_*.elf live on the modem_a partition (FAT16 with 4 KiB sectors; Android'"'"'s kernel will not loop-mount it
# from the chroot), so read the files out of a copy of the image with 7z, which parses FAT itself.
command -v 7z >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq --no-install-recommends p7zip-full >/dev/null; }
dd if=/dev/block/by-name/modem_a of=/root/dl/modem_a.img bs=4M status=none
7z e -y -o$V/modem-image /root/dl/modem_a.img "image/tmel_peach_*" >/dev/null 2>&1 || 7z e -y -o$V/modem-image /root/dl/modem_a.img "image/tmel*" >/dev/null 2>&1 || echo "no tmel files found in modem_a"
chmod -R u+rw,go+r /root/dl/vendor-fw
echo "peach: $(ls $V/peach | wc -l) files ($(ls $V/peach | grep -E "amss20|bdwlan.elf|phy_ucode20|aux_ucode20" | tr "\n" " "))"
echo "bt: $(ls $V/bt | wc -l) files; gpu: $(ls $V/gpu | wc -l) files; tmel: $(ls $V/modem-image 2>/dev/null | tr "\n" " ")"
du -sh /root/dl/vendor-fw; echo VENDOR-FW-DONE' ;;
rootfs)
    # Native root for userdata, by flavor:
    #   server / minimal  Ubuntu Base 24.04 + systemd + networking + SSH (+ ubuntu-minimal, ubuntu-standard, ubuntu-server
    #                     for server; no snapd, no cloud-init)
    #   arch              Arch Linux ARM's root tarball (downloaded here, checked against its MD5 file and its detached
    #                     signature from the pinned Arch Linux ARM build key), then scripts/arch-rootfs.sh in it
    # then, for every flavor: this build's kernel modules, the phone's own firmware, the SSH key, USB networking,
    # and an ext4 image labelled omamobile-root (the Omarchy init grows it to the whole partition on first boot).
    ask_flavor
    ask_desktop
    ask_linux_user
    # the script that runs inside the new root: the whole Arch setup, or GNOME on top of Ubuntu
    INROOT=
    if [ "$OFLAVOR" = arch ]; then INROOT=arch-rootfs.sh; elif [ "$ODESK" = gnome ]; then INROOT=ubuntu-gnome-rootfs.sh; fi
    if [ -n "$INROOT" ]; then
        "$ADB" push "$HERE/scripts/$INROOT" /data/local/tmp/.inroot </dev/null >/dev/null
        su_sh "mkdir -p $R/root/dl && cp /data/local/tmp/.inroot $R/root/dl/$INROOT && chmod 755 $R/root/dl/$INROOT && rm /data/local/tmp/.inroot"
    fi
    tmp=$(mktemp); printf '%s %s %s\n' "$OUSER" "$OHASH" "$OHOST" > "$tmp"
    "$ADB" push "$tmp" /data/local/tmp/.linux-user </dev/null >/dev/null; rm -f "$tmp"
    su_sh "mkdir -p $R/root/out && cp /data/local/tmp/.linux-user $R/root/out/linux-user && chmod 600 $R/root/out/linux-user && rm /data/local/tmp/.linux-user"
    echo "user: $OUSER   device name: $OHOST   (stored with the password hash in /root/out/linux-user inside the chroot, root-only)"
    su_sh "printf '%s\n' $OFLAVOR > $R/root/out/linux-flavor; printf '%s\n' $ODESK > $R/root/out/linux-desktop"
    echo "flavor: $OFLAVOR   desktop: $ODESK"
    in_ubuntu_bg rootfs 'set -e
R=/root/rootfs; MODS=/root/out/stage2/modules-staging/lib/modules
FL=$(cat /root/out/linux-flavor 2>/dev/null || echo server); DESK=$(cat /root/out/linux-desktop 2>/dev/null || echo none)
if [ "$FL" = arch ]; then IMGNAME=rootfs-arch-dodge.img; else IMGNAME=rootfs-ubuntu-noble-dodge.img; fi
IMG=/root/out/$IMGNAME; printf "%s\n" "$IMGNAME" > /root/out/rootfs-image.name
rm -f /root/out/rootfs-ubuntu-noble-dodge.img /root/out/rootfs-arch-dodge.img
read -r OUSER OHASH OHOST < /root/out/linux-user; [ -n "$OHOST" ] || { echo "!! no device name in /root/out/linux-user"; exit 1; }; printf "%s\n" "$OUSER" > /root/out/linux-user.name
for m in proc sys dev dev/pts; do umount -l $R/$m 2>/dev/null || true; done
rm -rf $R; mkdir -p $R
if [ "$FL" = arch ]; then
  # Arch Linux ARM publishes one moving "latest" tarball, so there is no checksum to commit: it is trusted by its
  # detached signature, which must be valid and made by the Arch Linux ARM build key pinned here. Plain http on
  # purpose: the host serves a certificate for another name, and transport is not what is trusted.
  export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq --no-install-recommends curl ca-certificates gnupg libarchive-tools >/dev/null
  A=ArchLinuxARM-aarch64-latest.tar.gz; AU=http://os.archlinuxarm.org/os/$A; AK=68B3537F39A313B3E574D06777193F152BDBE6A6
  cd /root/dl
  if [ ! -s $A ] || [ ! -s $A.sig ]; then
    echo "downloading $AU"; curl -fL --retry 3 -sS -o $A.part $AU; curl -fsSL -o $A.md5 $AU.md5; curl -fsSL -o $A.sig $AU.sig; mv $A.part $A
  fi
  md5sum -c --quiet $A.md5 || { echo "!!  MD5 mismatch for $A (delete /root/dl/$A to download again)"; exit 1; }
  export GNUPGHOME=/root/dl/alarm-gnupg; mkdir -p -m 700 $GNUPGHOME
  [ -s /root/dl/alarm-builder.asc ] || curl -fsSL -o /root/dl/alarm-builder.asc "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$AK"
  gpg -q --batch --import /root/dl/alarm-builder.asc 2>/dev/null
  gpg --batch --status-fd 1 --verify $A.sig $A 2>/dev/null | grep -q "^\[GNUPG:\] VALIDSIG .*$AK" || { echo "!!  $A is not signed by the Arch Linux ARM build key $AK"; exit 1; }
  echo "$A: MD5 ok, signature by $AK ok, sha256 $(sha256sum $A | cut -c1-64)"
  unset GNUPGHOME; cd /root
  bsdtar -xpf /root/dl/$A -C $R
else
  tar -xzf /root/dl/ubuntu-base-24.04.5-base-arm64.tar.gz -C $R
fi
rm -f $R/etc/resolv.conf; printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > $R/etc/resolv.conf
printf "%s\n" "$OHOST" > $R/etc/hostname; printf "127.0.0.1 localhost %s\n::1 localhost\n" "$OHOST" > $R/etc/hosts
mount -t proc proc $R/proc; mount --bind /dev $R/dev; mount --bind /dev/pts $R/dev/pts; mount -t sysfs sys $R/sys
install -m 600 /root/out/linux-user $R/root/.linux-user
if [ "$FL" = arch ]; then
install -m 755 /root/dl/arch-rootfs.sh $R/root/arch-rootfs.sh
chroot $R /usr/bin/env -i HOME=/root TERM=dumb LANG=C.UTF-8 PATH=/usr/local/sbin:/usr/local/bin:/usr/bin /bin/bash /root/arch-rootfs.sh /root/.linux-user $DESK
rm -f $R/root/arch-rootfs.sh
else
cp /root/out/linux-flavor $R/root/.linux-flavor 2>/dev/null || echo server > $R/root/.linux-flavor
cat > $R/usr/sbin/policy-rc.d <<P
#!/bin/sh
exit 101
P
chmod 755 $R/usr/sbin/policy-rc.d
chroot $R /bin/bash -c "set -e; export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
apt-get update -qq
apt-get install -y -qq --no-install-recommends systemd systemd-sysv systemd-resolved systemd-timesyncd udev dbus kmod iproute2 iputils-ping \
  openssh-server sudo nano vim-tiny less curl wget ca-certificates locales bash-completion util-linux e2fsprogs gdisk fdisk \
  network-manager wpasupplicant wireless-regdb iw rfkill bluez pciutils usbutils i2c-tools zstd lz4 python3 git htop tmux \
  linux-firmware console-setup kbd rsyslog >/dev/null
# Ubuntu Server: the three metapackages a server image is seeded from. Without Recommends this leaves out snapd and
# cloud-init (both wrong on a phone: no seed, and cloud-init rewrites network and SSH settings at first boot).
# multipathd probes every SCSI LUN and this phone has six UFS LUNs it has no business claiming; lxd-installer
# needs snapd. NetworkManager stays the network stack (netplan is installed by ubuntu-minimal but has no config).
if [ \"\$(cat /root/.linux-flavor 2>/dev/null)\" != minimal ]; then
  apt-get install -y -qq --no-install-recommends ubuntu-minimal ubuntu-standard ubuntu-server >/dev/null
  systemctl mask multipathd.service multipathd.socket lxd-installer.socket >/dev/null 2>&1 || true
fi
rm -f /root/.linux-flavor
locale-gen C.UTF-8 >/dev/null 2>&1 || true
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
read -r u h _ < /root/.linux-user; rm -f /root/.linux-user
useradd -m -s /bin/bash -G sudo,adm,dialout,plugdev,netdev -p \"\$h\" \"\$u\"
printf \"%s ALL=(ALL) NOPASSWD:ALL\n\" \"\$u\" > /etc/sudoers.d/\$u; chmod 440 /etc/sudoers.d/\$u
passwd -l root
systemctl enable ssh NetworkManager systemd-resolved systemd-timesyncd serial-getty@ttyGS0.service getty@tty1.service >/dev/null 2>&1 || true
systemctl disable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
apt-get clean"
if [ "$DESK" = gnome ]; then
  install -m 755 /root/dl/ubuntu-gnome-rootfs.sh $R/root/ubuntu-gnome-rootfs.sh
  chroot $R /usr/bin/env -i HOME=/root TERM=dumb PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash /root/ubuntu-gnome-rootfs.sh
  rm -f $R/root/ubuntu-gnome-rootfs.sh
fi
rm -f $R/usr/sbin/policy-rc.d
fi
# this build'"'"'s kernel modules (on Arch /lib is a link to usr/lib; the trailing slashes follow it)
mkdir -p $R/lib/modules/ $R/lib/firmware/; cp -a $MODS/* $R/lib/modules/
# the phone'"'"'s own vendor firmware (staged from the running Android): raw copies plus the names mainline asks for
if [ -d /root/dl/vendor-fw/lib/firmware ]; then
  cp -a /root/dl/vendor-fw/lib/firmware/. $R/lib/firmware/
  P=$R/lib/firmware/vendor-raw/peach; W=$R/lib/firmware/ath12k/WCN7850/hw2.0; mkdir -p $W
  # the set that brought wlp1s0 up on 2026-11-18 (hw2.0, board_id 0xff): the "20" variants and Android'"'"'s default board file
  for f in m3.bin regdb.bin qdss_trace_config_v2.cfg; do [ -f $P/$f ] && cp $P/$f $W/; done
  [ -f $P/amss20.bin ] && cp $P/amss20.bin $W/amss.bin || cp $P/amss.bin $W/amss.bin
  [ -f $P/bdwlan.elf ] && cp $P/bdwlan.elf $W/board.bin || cp $P/bdwlan.e01 $W/board.bin 2>/dev/null || true
  [ -f $P/phy_ucode20.elf ] && cp $P/phy_ucode20.elf $W/
  [ -f $P/aux_ucode20.elf ] && cp $P/aux_ucode20.elf $W/aux_ucode.bin
  cp $R/lib/firmware/vendor-raw/modem-image/tmel_peach_*.elf $W/ 2>/dev/null || true
  mkdir -p $R/lib/firmware/ath12k/WCN7860 && ln -sfn ../WCN7850/hw2.0 $R/lib/firmware/ath12k/WCN7860/hw2.0
  mkdir -p $R/lib/firmware/qcom && cp $R/lib/firmware/vendor-raw/gpu/* $R/lib/firmware/qcom/ && cp $R/lib/firmware/vendor-raw/gpu/* $R/lib/firmware/
  mkdir -p $R/lib/firmware/qca && cp $R/lib/firmware/vendor-raw/bt/*.mbn $R/lib/firmware/vendor-raw/bt/*.tlv $R/lib/firmware/vendor-raw/bt/*nv*.bin $R/lib/firmware/qca/ 2>/dev/null || true
  chmod -R u+rw,go+r $R/lib/firmware/vendor-raw $R/lib/firmware/qca $R/lib/firmware/qcom $R/lib/firmware/ath12k
fi
# SSH keys for root and the user (project key); root login by key only
for h in $R/root $R/home/$OUSER; do mkdir -p $h/.ssh; cp /root/dl/authorized_keys $h/.ssh/authorized_keys; chmod 700 $h/.ssh; chmod 600 $h/.ssh/authorized_keys; done
chroot $R chown -R $OUSER:$OUSER /home/$OUSER/.ssh
# the user logs in over SSH with the password or the project key, on every system and with or without a desktop
# (requested 2026-11-25: plain "ssh user@ip" must work without the key file); root stays key only
mkdir -p $R/etc/ssh/sshd_config.d
printf "PermitRootLogin prohibit-password\nPasswordAuthentication yes\n" > $R/etc/ssh/sshd_config.d/omamobile.conf
# The phone answers to <device name>.local on Wi-Fi and USB (mDNS by systemd-resolved, switched on per connection by
# NetworkManager), whatever address the router gives it.
mkdir -p $R/etc/systemd/resolved.conf.d $R/etc/NetworkManager/conf.d
printf "[Resolve]\nMulticastDNS=yes\n" > $R/etc/systemd/resolved.conf.d/10-mdns.conf
printf "[connection]\nconnection.mdns=2\n" > $R/etc/NetworkManager/conf.d/10-mdns.conf
# One Wi-Fi hardware address per installation. ath12k finds no address in its board data and makes one up at every
# boot (00:03:7f:12:xx:xx), so a router sees a new device each time: a new IP at every boot and no way to reserve one.
# "stable" derives the address from this installation (NetworkManager secret key, created at first boot) and the id
# below: the same at every boot and on every network, different from phone to phone.
printf "[connection]\nwifi.cloned-mac-address=stable\nconnection.stable-id=oneplus13-wifi\n" > $R/etc/NetworkManager/conf.d/20-stable-wifi-mac.conf
# USB gadget network (the initramfs creates the gadget; the kernel keeps it across switch_root)
mkdir -p $R/etc/NetworkManager/system-connections
cat > $R/etc/NetworkManager/system-connections/usb0.nmconnection <<N
[connection]
id=usb0
type=ethernet
interface-name=usb0
autoconnect=true
[ipv4]
method=manual
address1=172.16.42.1/24
[ipv6]
method=ignore
N
chmod 600 $R/etc/NetworkManager/system-connections/usb0.nmconnection
# a short press of the power button must not shut the phone down (USB power reboots it at once; each boot of a
# not-yet-successful slot burns an ABL retry). Found 2026-11-20; see docs/linux-compatibility.md.
mkdir -p $R/etc/systemd/logind.conf.d
printf "[Login]\nHandlePowerKey=ignore\nHandlePowerKeyLongPress=ignore\n" > $R/etc/systemd/logind.conf.d/10-powerkey.conf
printf "LABEL=omamobile-root / ext4 defaults,noatime 0 1\n" > $R/etc/fstab
: > $R/etc/machine-id; rm -f $R/var/lib/dbus/machine-id
ln -sf /run/systemd/resolve/stub-resolv.conf $R/etc/resolv.conf
for m in dev/pts dev proc sys; do umount -l $R/$m; done
du -sh $R
rm -f $IMG; truncate -s 8G $IMG
mkfs.ext4 -q -F -L omamobile-root -O ^has_journal,^metadata_csum_seed -d $R $IMG
e2fsck -fn $IMG >/dev/null && echo fsck-ok
ls -la $IMG; echo ROOTFS-DONE' ;;
status)
    su_sh "for f in $R/root/build-*.log; do echo \"== \$f\"; tail -4 \"\$f\"; done" ;;
*) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
