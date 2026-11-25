#!/bin/bash
# Runs INSIDE the Ubuntu 24.04 root that scripts/omarchy-build-phone.sh rootfs is building (flavor server or minimal),
# as root, in a chroot, when the GNOME desktop was chosen. Adds GNOME with the GDM login screen.
#
#   ubuntu-gnome-rootfs.sh
#
# Everything here works offline in a chroot: packages, files and systemctl enable (which only edits symlinks).
# The package set and the settings are the ones that ran on the OnePlus 13 under native Ubuntu on 2026-11-23
# (then installed on the running phone by scripts/phone-desktop.sh on the Desktop branch).
#
# What it sets up besides the packages:
#   - touch: the Synaptics panel driver is a module nothing autoloads (modules-load.d)
#   - software rendering: the Adreno 830 has no working userspace driver in Ubuntu 24.04's Mesa
#   - scale 3 on the 1440x3168 panel, on-screen keyboard on, no suspend, power key does nothing
#   - graphical.target as default with GDM, Wayland only
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "!!  run as root" >&2; exit 1; }
[ -f /etc/os-release ] && grep -q '^ID=ubuntu' /etc/os-release || { echo "!!  this is not an Ubuntu root" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
say() { printf '\n==> %s\n' "$*"; }
sc() { systemctl "$@" >/dev/null 2>&1 || echo "note: systemctl $* failed"; }
apt_get() { apt-get -y -qq -o Dpkg::Options::=--force-confold "$@"; }

say "GNOME packages (GNOME session, GDM, Yaru theme; about 1.5 GB installed)"
apt_get update
# A curated set instead of ubuntu-desktop-minimal: that metapackage pulls snapd and the Firefox snap, which cannot
# be installed while building the image in a chroot.
apt_get install --no-install-recommends gdm3 ubuntu-session gnome-shell gnome-session-bin gnome-settings-daemon \
    gnome-control-center gnome-terminal nautilus gnome-text-editor gnome-system-monitor gnome-shell-extension-ubuntu-dock \
    yaru-theme-gtk yaru-theme-icon yaru-theme-gnome-shell yaru-theme-sound fonts-ubuntu fonts-noto-color-emoji \
    xdg-user-dirs-gtk xdg-desktop-portal-gnome dbus-user-session libgl1-mesa-dri mesa-utils-bin epiphany-browser \
    gnome-keyring libpam-gnome-keyring pipewire wireplumber network-manager-gnome gnome-bluetooth-sendto >/dev/null

say "touch driver at boot"
printf '# OnePlus 13 touch panel (Synaptics TouchComm over GENI SPI); written by ubuntu-gnome-rootfs.sh\ngpi\nspi_geni_qcom\nsynaptics_tcm2\n' > /etc/modules-load.d/oneplus13-touch.conf

say "software rendering"
# Ubuntu 24.04's Mesa (25.2) has no Adreno 830 support. Left alone it still loads its msm driver for the display
# card, fails ("unsupported GPU id") and gnome-shell segfaults; kms_swrast makes Mesa render with llvmpipe and only
# scan out through msm. /etc/environment covers PAM sessions (GDM's login screen too), environment.d covers
# systemd user services.
mkdir -p /etc/environment.d
printf 'LIBGL_ALWAYS_SOFTWARE=1\nMESA_LOADER_DRIVER_OVERRIDE=kms_swrast\n' > /etc/environment.d/50-oneplus13-software-gl.conf
for kv in LIBGL_ALWAYS_SOFTWARE=1 MESA_LOADER_DRIVER_OVERRIDE=kms_swrast; do
    grep -q "^${kv%%=*}=" /etc/environment 2>/dev/null || printf '%s\n' "$kv" >> /etc/environment
done

say "GNOME defaults for a phone (scale 3, on-screen keyboard, no suspend)"
cat > /usr/share/glib-2.0/schemas/90_oneplus13.gschema.override <<'G'
[org.gnome.desktop.interface]
scaling-factor=uint32 3
[org.gnome.desktop.a11y.applications]
screen-keyboard-enabled=true
[org.gnome.settings-daemon.plugins.power]
power-button-action='nothing'
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
[org.gnome.desktop.session]
idle-delay=uint32 300
G
glib-compile-schemas /usr/share/glib-2.0/schemas
# Nothing may suspend the phone: s2idle is not reliable on this kernel yet.
sc mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
# Wayland only: Xorg has no driver for this panel. GDM's udev rule would otherwise prefer Xorg when it sees no
# hardware GL.
mkdir -p /etc/gdm3
if [ -f /etc/gdm3/custom.conf ]; then sed -i 's/^#\?WaylandEnable=.*/WaylandEnable=true/' /etc/gdm3/custom.conf; fi
ln -sf /dev/null /etc/udev/rules.d/61-gdm.rules
# The phone's own UFS partitions (Android firmware, modem, both boot slots) are not user drives: keep them out of
# the dock and Files, where one tap would mount them. USB drives (ID_BUS=usb) still appear.
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/62-oneplus13-hide-internal.rules <<'U'
SUBSYSTEM=="block", KERNEL=="sd*", ENV{ID_BUS}=="scsi", ENV{UDISKS_IGNORE}="1"
U
sc enable gdm3.service
[ -L /etc/systemd/system/display-manager.service ] || ln -sf /usr/lib/systemd/system/gdm3.service /etc/systemd/system/display-manager.service
mkdir -p /etc/X11; printf '/usr/sbin/gdm3\n' > /etc/X11/default-display-manager
sc set-default graphical.target
echo gnome > /etc/oneplus13-desktop
apt-get clean

say "summary"
dpkg-query -W -f '    ${Package} ${Version}\n' gdm3 gnome-shell libgl1-mesa-dri
echo UBUNTU-GNOME-DONE
