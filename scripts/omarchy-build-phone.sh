#!/usr/bin/env bash
# Build the Omarchy Mobile (mainline) kernel chain for the OnePlus 13 (dodge) INSIDE
# the phone's Ubuntu chroot (/data/local/ubuntu). Run from the Mac; each step is
# launched over adb as root and logs to /root/build-*.log in the chroot.
#
#   scripts/omarchy-build-phone.sh stage2     # kernel: defconfig + omamobile.config + sm8750.config -> Image, dtbs, modules
#   scripts/omarchy-build-phone.sh initramfs  # stage-2 initramfs: Alpine minirootfs + dropbear/kexec/e2fsprogs + shared init
#   scripts/omarchy-build-phone.sh chain      # stage-2 DTB (live memory map), stage-1 kernel, boot-chain.img (header v4)
#   scripts/omarchy-build-phone.sh rootfs     # Ubuntu 24.04 root for userdata -> /root/out/rootfs-ubuntu-noble-dodge.img (ext4, label omamobile-root)
#   scripts/omarchy-build-phone.sh verify-rootfs | mkimage   # check the built root; make the minimal ext4 image from it
#   scripts/omarchy-build-phone.sh pull       # copy build outputs to firmware/images/omarchy-dodge/ on the Mac
#   scripts/omarchy-build-phone.sh status     # tail the logs
#
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

KEY="$HERE/keys/omarchy-dodge_ed25519"
if [ ! -f "$KEY" ]; then mkdir -p "$HERE/keys"; ssh-keygen -q -t ed25519 -N '' -C omarchy-dodge -f "$KEY"; echo "generated $KEY (gitignored; it is the only way into the built images)"; fi

case "${1:-}" in
sources)
    "$ADB" push "$KEY.pub" /data/local/tmp/.authorized_keys </dev/null >/dev/null
    su_sh "mkdir -p $R/root/dl && cp /data/local/tmp/.authorized_keys $R/root/dl/authorized_keys && rm /data/local/tmp/.authorized_keys"
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
  chroot /root/dl/alpine-root /sbin/apk fetch --no-cache -R -o /dl busybox-static kexec-tools dtc libfdt e2fsprogs dropbear
  mv /root/dl/alpine-root/dl/*.apk /root/dl/apks/; rm -rf /root/dl/alpine-root
fi
[ -s /root/dl/live.dtb ] || cat /sys/firmware/fdt > /root/dl/live.dtb
ls -la /root/dl /root/dl/apks | head -40
for d in linux omarchy-mobile mkbootimg; do (cd /root/src/$d && printf '%-16s %s\n' $d "$(git describe --tags --always)"); done
echo SOURCES-DONE
SRC
)
    in_ubuntu_run sources "$body" ;;
verify-rootfs)
    in_ubuntu_run verify-rootfs 'R=/root/rootfs
echo "apt errors in log: $(grep -c -E "^E:|Error [0-9]" /root/build-rootfs.log)"
for f in usr/lib/systemd/systemd usr/bin/sudo usr/sbin/sshd usr/sbin/NetworkManager usr/sbin/sgdisk usr/sbin/wpa_supplicant usr/bin/nmcli; do [ -e $R/$f ] && echo "ok   /$f" || echo "MISSING /$f"; done
grep -E "^(min|root):" $R/etc/passwd; echo "sudoers: $(cat $R/etc/sudoers.d/min 2>/dev/null)"
echo "modules: $(ls $R/lib/modules 2>/dev/null) ($(find $R/lib/modules -name "*.ko*" 2>/dev/null | wc -l) files); ath12k: $(ls $R/lib/modules/*/kernel/drivers/net/wireless/ath/ath12k/ 2>/dev/null | tr "\n" " ")"
echo "firmware: $(du -sh $R/lib/firmware 2>/dev/null | cut -f1); ath12k dir: $(ls $R/lib/firmware/ath12k/WCN7850/hw2.0 2>/dev/null | tr "\n" " "); WCN7860 link: $(readlink $R/lib/firmware/ath12k/WCN7860/hw2.0 2>/dev/null); qcom gen8: $(ls $R/lib/firmware/qcom/gen8* 2>/dev/null | wc -l)"
echo "ssh keys: root=$(wc -l < $R/root/.ssh/authorized_keys 2>/dev/null) min=$(wc -l < $R/home/min/.ssh/authorized_keys 2>/dev/null)"
echo "fstab: $(cat $R/etc/fstab)"; echo "nm usb0: $(grep address1 $R/etc/NetworkManager/system-connections/usb0.nmconnection 2>/dev/null)"
echo "enabled: $(ls $R/etc/systemd/system/multi-user.target.wants/ $R/etc/systemd/system/getty.target.wants/ 2>/dev/null | grep -v : | tr "\n" " ")"
echo "size: $(du -sh $R | cut -f1)"' ;;
mkimage)
    in_ubuntu_run mkimage 'set -e; R=/root/rootfs; I=/root/out/rootfs-ubuntu-noble-dodge.img
need_kb=$(du -sk $R | cut -f1); size_mb=$(( need_kb/1024 * 125 / 100 + 256 ))
rm -f $I; truncate -s ${size_mb}M $I
mkfs.ext4 -q -F -L omamobile-root -O ^has_journal -d $R $I
e2fsck -fn $I >/dev/null && echo fsck-ok
dumpe2fs -h $I 2>/dev/null | grep -E "volume name|Block count|Block size"
ls -la $I; sha256sum $I' ;;
stage2)
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
cd \$ROOT && bash tools/dodge-chain pack && cp \$CHAIN_OUT/images/boot-chain.img \$CHAIN_OUT/images/boot-chain-\${CHAIN_NAME:-test}.img; echo CHAIN-DONE" ;;
pull)
    D="$HERE/firmware/images/omarchy-dodge-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$D"
    for f in chain/images/boot-chain.img arch/arm64/boot/Image arch/arm64/boot/dts/qcom/sm8750-oneplus-dodge.dtb initramfs.cpio.lz4 .config chain/.config chain/chain/stage2.dtb include/config/kernel.release; do
        "$ADB" shell "su -c 'cat $R/root/out/stage2/$f'" </dev/null > "$D/$(echo "$f" | tr '/' '_')" 2>/dev/null || true
    done
    (cd "$D" && shasum -a 256 * > SHA256SUMS); ls -la "$D" ;;
rootfs)
    # Native Ubuntu 24.04 root for userdata: Ubuntu Base + systemd + networking + SSH + this build's kernel modules,
    # then an ext4 image labelled omamobile-root (the Omarchy init grows it to the whole partition on first boot).
    in_ubuntu_bg rootfs 'set -e
R=/root/rootfs; IMG=/root/out/rootfs-ubuntu-noble-dodge.img; MODS=/root/out/stage2/modules-staging/lib/modules
for m in proc sys dev dev/pts; do umount -l $R/$m 2>/dev/null || true; done
rm -rf $R; mkdir -p $R
tar -xzf /root/dl/ubuntu-base-24.04.5-base-arm64.tar.gz -C $R
rm -f $R/etc/resolv.conf; printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > $R/etc/resolv.conf
printf "oneplus13\n" > $R/etc/hostname; printf "127.0.0.1 localhost oneplus13\n::1 localhost\n" > $R/etc/hosts
mount -t proc proc $R/proc; mount --bind /dev $R/dev; mount --bind /dev/pts $R/dev/pts; mount -t sysfs sys $R/sys
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
locale-gen C.UTF-8 >/dev/null 2>&1 || true
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
useradd -m -s /bin/bash -G sudo,adm,dialout,plugdev,netdev min
echo min:oneplus13 | chpasswd
printf \"min ALL=(ALL) NOPASSWD:ALL\n\" > /etc/sudoers.d/min; chmod 440 /etc/sudoers.d/min
passwd -l root
systemctl enable ssh NetworkManager systemd-resolved systemd-timesyncd serial-getty@ttyGS0.service getty@tty1.service >/dev/null 2>&1 || true
systemctl disable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
apt-get clean"
rm -f $R/usr/sbin/policy-rc.d
# this build'"'"'s kernel modules
mkdir -p $R/lib/modules; cp -a $MODS/* $R/lib/modules/
# the phone'"'"'s own vendor firmware (staged from the running Android): raw copies plus the names mainline asks for
if [ -d /root/dl/vendor-fw/lib/firmware ]; then
  cp -a /root/dl/vendor-fw/lib/firmware/. $R/lib/firmware/
  P=$R/lib/firmware/vendor-raw/peach; W=$R/lib/firmware/ath12k/WCN7850/hw2.0; mkdir -p $W
  for f in amss.bin m3.bin regdb.bin; do [ -f $P/$f ] && cp $P/$f $W/; done
  ls $P/bdwlan* >/dev/null 2>&1 && cp $P/bdwlan.e01 $W/board.bin 2>/dev/null || true
  mkdir -p $R/lib/firmware/ath12k/WCN7860 && ln -sfn ../WCN7850/hw2.0 $R/lib/firmware/ath12k/WCN7860/hw2.0
  mkdir -p $R/lib/firmware/qcom && cp $R/lib/firmware/vendor-raw/gpu/* $R/lib/firmware/qcom/ && cp $R/lib/firmware/vendor-raw/gpu/* $R/lib/firmware/
  mkdir -p $R/lib/firmware/qca && cp $R/lib/firmware/vendor-raw/bt/*.mbn $R/lib/firmware/vendor-raw/bt/*.tlv $R/lib/firmware/vendor-raw/bt/*nv*.bin $R/lib/firmware/qca/ 2>/dev/null || true
  chmod -R u+rw,go+r $R/lib/firmware/vendor-raw $R/lib/firmware/qca $R/lib/firmware/qcom $R/lib/firmware/ath12k
fi
# SSH keys for root and min (project key); root login by key only
for h in $R/root $R/home/min; do mkdir -p $h/.ssh; cp /root/dl/authorized_keys $h/.ssh/authorized_keys; chmod 700 $h/.ssh; chmod 600 $h/.ssh/authorized_keys; done
chroot $R chown -R min:min /home/min/.ssh
printf "PermitRootLogin prohibit-password\nPasswordAuthentication yes\n" > $R/etc/ssh/sshd_config.d/omamobile.conf
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
*) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
