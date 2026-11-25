#!/bin/bash
# Runs INSIDE an unpacked Arch Linux ARM aarch64 root (ArchLinuxARM-aarch64-latest.tar.gz), as root, in a chroot.
# Turns it into the OnePlus 13 system: Arch Linux ARM, with a text console or with the GNOME desktop.
#
#   arch-rootfs.sh [USERFILE] [DESKTOP]     DESKTOP is none (text console, default) or gnome.
#                                       USERFILE holds one line "<user> <sha512-crypt hash> [<device name>]" (default /root/.linux-user)
#                                       and is deleted after it is read
#
# scripts/omarchy-build-phone.sh rootfs (flavor "arch") pushes this file to the phone and runs it in the new root.
# It only needs /proc, /sys, /dev and a working /etc/resolv.conf: no running systemd, no D-Bus. Nothing here is
# specific to one phone unit; the kernel modules, the phone's own firmware, the SSH key and the USB network profile
# are added by the caller afterwards, exactly as for the Ubuntu flavors.
#
# What it does:
#   - removes Arch Linux ARM's generic kernel and its firmware (the phone boots the kernel from boot_b)
#   - full upgrade, then the base tools; with DESKTOP=gnome also GNOME (gnome-shell, the GDM login screen, a few apps)
#   - replaces the default "alarm" account (password "alarm") with the given user; root is locked (it ships as "root")
#   - NetworkManager instead of systemd-networkd, sshd, serial console, and for gnome graphical.target with gdm.service
#   - phone settings: no suspend; for gnome also touch driver at boot, software rendering, on-screen keyboard
#
# History: the first version (2026-11-24) installed the Phosh phone shell. It ran on the phone, but the user preferred
# GNOME, which was then installed on the running phone and became this flavor the same day.
set -euo pipefail
say() { printf '\n==> %s\n' "$*"; }
die() { printf '\n!!  %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
[ -f /etc/arch-release ] || die "this is not an Arch Linux root"
UF=${1:-/root/.linux-user}
DESK=${2:-none}
case "$DESK" in none|gnome) ;; *) die "unknown desktop '$DESK' (none or gnome)" ;; esac
[ -s "$UF" ] || die "no $UF (one line: <user> <password hash>)"
read -r U H _ < "$UF"; rm -f "$UF"
printf '%s' "$U" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || die "invalid user name '$U'"
case "$H" in '$6$'*) ;; *) die "the password hash is not SHA-512 crypt" ;; esac

# pacman for a chroot: CheckSpace needs / to be a mount point, the download user and the Landlock sandbox need
# kernel features Android's kernel (which runs this build) does not give a nested chroot.
PC=/etc/pacman.build.conf; ML=/etc/pacman.d/mirrorlist.build
sed -e '/^CheckSpace/d' -e '/^DownloadUser/d' -e "s#^Include *= */etc/pacman.d/mirrorlist\$#Include = $ML#" /etc/pacman.conf > "$PC"
# One named mirror at a time for the build. The default entry (mirror.archlinuxarm.org) redirects every request
# to a different server, and while the mirrors are syncing those disagree: the index comes from one, the package
# from another that answers 404. The mirrors that answer within 8 s are used in order of speed; a failed install
# moves on to the next. The image itself keeps the stock mirrorlist.
MIRRORS=$(for m in $(grep -oE 'http://[a-z0-9.]+\.mirror\.archlinuxarm\.org' /etc/pacman.d/mirrorlist | sort -u); do
    t=$(curl -s -o /dev/null -m 8 -w '%{http_code} %{time_total}' "$m/aarch64/core/core.db" 2>/dev/null || true)
    if [ "${t%% *}" = 200 ]; then echo "${t#200 } $m"; fi
done | sort -n | cut -d' ' -f2)
[ -n "$MIRRORS" ] || MIRRORS=http://mirror.archlinuxarm.org
MIRROR_N=1
use_mirror() { # $1 = 1-based index into MIRRORS, wrapping around
    local n; n=$(echo "$MIRRORS" | wc -l); n=$(( ($1 - 1) % n + 1 ))
    printf 'Server = %s/$arch/$repo\n' "$(echo "$MIRRORS" | sed -n "${n}p")" > "$ML"
}
use_mirror $MIRROR_N
pac() { pacman --config "$PC" --noconfirm --disable-sandbox "$@"; }
# Install with a refresh and a full upgrade each time (never a partial upgrade). A failure switches to the next
# mirror and forces a fresh index (-Syyu), up to five times.
pacr() {
    local i y=-Syu
    for i in 1 2 3 4 5; do
        pac $y --needed "$@" >/dev/null 2>/tmp/pacr.err && return 0
        echo "    attempt $i failed on $(cut -d' ' -f3 "$ML" | cut -d/ -f3): $(grep -m1 -E '^error' /tmp/pacr.err || tail -1 /tmp/pacr.err)"
        MIRROR_N=$((MIRROR_N + 1)); use_mirror $MIRROR_N; y=-Syyu; sleep 3
    done
    cat /tmp/pacr.err >&2; return 1
}

echo "mirrors, fastest first: $(echo $MIRRORS | sed 's#http://##g')"
say "pacman keyring"
pacman-key --init >/dev/null 2>&1
pacman-key --populate archlinuxarm >/dev/null 2>&1

say "removing the generic kernel and its firmware"
# linux-aarch64 is never booted here, and its mkinitcpio hook would run on every upgrade. linux-firmware is about
# 1 GB of files for other machines, zstd-compressed, which this phone's kernel does not load; Wi-Fi, Bluetooth and
# GPU firmware come from the phone itself (omarchy-build-phone.sh vendor-fw).
# shellcheck disable=SC2046
pac -Rns linux-aarch64 $(pacman -Qq | grep -E '^linux-firmware(-|$)' || true) >/dev/null 2>&1 || echo "note: could not remove the generic kernel/firmware (already gone?)"

say "full upgrade"
pacr archlinuxarm-keyring

say "base tools"
pacr sudo openssh networkmanager wpa_supplicant wireless-regdb iw bluez bluez-utils e2fsprogs gptfdisk kmod \
    usbutils pciutils less nano vim htop tmux git curl wget python zstd lz4 bash-completion man-db which

if [ "$DESK" = gnome ]; then
say "GNOME desktop"
# Required: without any of these there is no usable screen.
pacr gnome-shell gdm gnome-session gnome-settings-daemon gnome-control-center mesa pipewire pipewire-pulse wireplumber \
    noto-fonts adwaita-icon-theme xdg-user-dirs
# Wanted, one call each: a renamed or missing package must not cost the others.
for p in gnome-console nautilus gnome-text-editor epiphany gnome-keyring xdg-desktop-portal-gnome xdg-user-dirs-gtk gvfs \
         gnome-system-monitor gnome-tweaks gnome-backgrounds gnome-calculator loupe noto-fonts-emoji; do
    if pacman -Si "$p" >/dev/null 2>&1; then pacr "$p" || echo "skipped $p (install failed)"; else echo "skipped $p (not in the repositories)"; fi
done

fi

say "user $U (the default alarm account is removed, root is locked)"
if id alarm >/dev/null 2>&1; then userdel -r alarm >/dev/null 2>&1 || userdel alarm; fi
G=""; for g in wheel audio video input render network uucp storage; do getent group "$g" >/dev/null && G="$G,$g"; done
useradd -m -s /bin/bash -G "${G#,}" -p "$H" "$U"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$U" > "/etc/sudoers.d/$U"; chmod 440 "/etc/sudoers.d/$U"
passwd -l root >/dev/null

say "locale and time zone"
sed -i 's/^#\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen >/dev/null
printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime

say "services"
# systemctl enable/disable/mask only edit symlinks, so they work in a chroot; nothing is started here.
sc() { systemctl "$@" >/dev/null 2>&1 || echo "note: systemctl $* failed"; }
sc disable systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service systemd-network-generator.service
sc enable NetworkManager.service sshd.service systemd-resolved.service systemd-timesyncd.service bluetooth.service
sc enable serial-getty@ttyGS0.service getty@tty1.service
# s2idle is not reliable on this kernel yet: a suspended phone may not come back. Nothing may suspend it.
sc mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
rm -f /etc/systemd/network/en.network /etc/systemd/network/eth.network

if [ "$DESK" = gnome ]; then
say "GNOME on the panel"
# GDM is the login screen; it picks its own virtual terminal, so no terminal switch is needed (Phosh needed one).
# The display scale is left to GNOME (Settings > Displays > Scale changes it).
# The phone's own UFS partitions (Android firmware, modem, both boot slots) are not user drives: keep them out of
# the dock and Files, where one tap would mount them. USB drives (ID_BUS=usb) still appear.
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/62-oneplus13-hide-internal.rules <<'U'
SUBSYSTEM=="block", KERNEL=="sd*", ENV{ID_BUS}=="scsi", ENV{UDISKS_IGNORE}="1"
U
sc enable gdm.service
sc set-default graphical.target
# Touch: the Synaptics panel driver is a module that nothing loads by itself.
printf '# OnePlus 13 touch panel (Synaptics TouchComm over GENI SPI); written by arch-rootfs.sh\ngpi\nspi_geni_qcom\nsynaptics_tcm2\n' > /etc/modules-load.d/oneplus13-touch.conf
# Software rendering. The Adreno 830 does not start on this kernel (its zap firmware gen80000_zap.mbn is missing),
# and under Ubuntu 24.04 the compositor crashed in a loop without this setting. GNOME ran with it on the phone on
# 2026-11-24. To try the GPU later: delete this file and the two lines in /etc/environment, then reboot.
mkdir -p /etc/environment.d
printf 'LIBGL_ALWAYS_SOFTWARE=1\nMESA_LOADER_DRIVER_OVERRIDE=kms_swrast\n' > /etc/environment.d/50-oneplus13-software-gl.conf
for kv in LIBGL_ALWAYS_SOFTWARE=1 MESA_LOADER_DRIVER_OVERRIDE=kms_swrast; do
    grep -q "^${kv%%=*}=" /etc/environment 2>/dev/null || printf '%s\n' "$kv" >> /etc/environment
done
# /etc/environment.d reaches gnome-shell (a systemd user service, also for the GDM login screen); /etc/environment
# reaches everything started through PAM.
# No automatic suspend; the power key does nothing in GNOME (logind ignores it too, set by the caller).
# The on-screen keyboard is on for the login screen and the session: the phone has no other keyboard.
cat > /usr/share/glib-2.0/schemas/90_oneplus13.gschema.override <<'G'
[org.gnome.settings-daemon.plugins.power]
power-button-action='nothing'
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
[org.gnome.desktop.a11y.applications]
screen-keyboard-enabled=true
[org.gnome.shell]
favorite-apps=['org.gnome.Console.desktop', 'org.gnome.Epiphany.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Settings.desktop']
G
glib-compile-schemas /usr/share/glib-2.0/schemas
echo gnome > /etc/oneplus13-desktop
else
say "text console"
sc set-default multi-user.target
echo none > /etc/oneplus13-desktop
fi

say "cleanup"
pac -Scc >/dev/null 2>&1 || true
rm -f "$PC" "$ML" /tmp/pacr.err /etc/ssh/ssh_host_* /root/.bash_history
rm -rf /var/cache/pacman/pkg/* /var/log/journal/* /tmp/* 2>/dev/null || true

say "summary"
pacman -Q networkmanager openssh systemd | sed 's/^/    /'
if [ "$DESK" = gnome ]; then pacman -Q gnome-shell gdm mesa | sed 's/^/    /'; fi
echo "    desktop: $DESK"
echo "    packages: $(pacman -Qq | wc -l)   default target: $(systemctl get-default 2>/dev/null)"
echo ARCH-ROOTFS-DONE
