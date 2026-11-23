#!/bin/bash
# Runs ON THE PHONE (native Ubuntu 24.04 on the OnePlus 13), as root. Installs or removes a graphical desktop.
#
#   phone-desktop.sh gnome  [user]    Ubuntu's GNOME session with GDM (the regular Ubuntu desktop, touch + on-screen keyboard)
#   phone-desktop.sh lomiri [user]    Lomiri, the Ubuntu Touch shell (as packaged in Ubuntu 24.04), started from GDM.
#                                     EXPERIMENTAL: on 2026-11-23 it crashed at login on this phone (see the lomiri) block)
#   phone-desktop.sh phosh  [user]    Phosh, the phone shell (lighter, made for small touch screens)
#   phone-desktop.sh none             back to the text console (packages stay installed; nothing is purged)
#   phone-desktop.sh status           what is configured
#
# From the Mac use scripts/omarchy-desktop.sh, which copies this file over SSH and runs it. The rootfs build
# (omarchy-build-phone.sh rootfs) runs it inside the image when a desktop was chosen: everything here works
# offline in a chroot (no systemctl start, no running D-Bus needed).
#
# What it sets up besides the packages:
#   - touch: the Synaptics panel driver is a module nothing autoloads (modules-load.d)
#   - software rendering: the Adreno 830 has no working userspace driver in Ubuntu 24.04's Mesa
#   - scale 3 on the 1440x3168 panel, on-screen keyboard on, no suspend, power key does nothing
#   - graphical.target as default; the display manager takes tty1 from the text console
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
MODE=${1:-status}
U=${2:-$(getent passwd 1000 | cut -d: -f1)}
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
OVR=/usr/share/glib-2.0/schemas/90_oneplus13.gschema.override
say() { printf '\n==> %s\n' "$*"; }
# systemctl enable/disable/set-default only edit symlinks, so they also work in a chroot; never start anything here.
sc() { systemctl "$@" 2>/dev/null || true; }
apt_get() { apt-get -y -qq -o Dpkg::Options::=--force-confold "$@"; }

common() {
    say "touch driver at boot"
    printf '# OnePlus 13 touch panel (Synaptics TouchComm over GENI SPI); written by phone-desktop.sh\ngpi\nspi_geni_qcom\nsynaptics_tcm2\n' > /etc/modules-load.d/oneplus13-touch.conf
    say "software rendering for every session"
    # Ubuntu 24.04's Mesa (25.2) has no Adreno 830 support. Left alone it still loads its msm driver for the
    # display card, fails ("unsupported GPU id") and gnome-shell segfaults; kms_swrast makes Mesa render with
    # llvmpipe and only scan out through msm. /etc/environment covers PAM sessions (GDM's greeter too),
    # environment.d covers systemd user services.
    mkdir -p /etc/environment.d
    printf 'LIBGL_ALWAYS_SOFTWARE=1\nMESA_LOADER_DRIVER_OVERRIDE=kms_swrast\n' > /etc/environment.d/50-oneplus13-software-gl.conf
    for kv in LIBGL_ALWAYS_SOFTWARE=1 MESA_LOADER_DRIVER_OVERRIDE=kms_swrast; do
        grep -q "^${kv%%=*}=" /etc/environment 2>/dev/null || printf '%s\n' "$kv" >> /etc/environment
    done
}

text_console() { # $1 on|off
    if [ "$1" = on ]; then
        if [ -e /etc/systemd/system/getty.target.wants/kmsconvt@tty1.service ]; then :; else sc enable getty@tty1.service; fi
    fi
}

case "$MODE" in
gnome)
    [ -n "$U" ] || { echo "no user with uid 1000; pass the user name"; exit 1; }
    say "packages (GNOME session, GDM, Yaru theme; about 1.5 GB installed)"
    apt_get update
    # A curated set instead of ubuntu-desktop-minimal: that metapackage pulls snapd and the Firefox snap,
    # which cannot be installed while building the image in a chroot.
    apt_get install --no-install-recommends gdm3 ubuntu-session gnome-shell gnome-session-bin gnome-settings-daemon \
        gnome-control-center gnome-terminal nautilus gnome-text-editor gnome-system-monitor gnome-shell-extension-ubuntu-dock \
        yaru-theme-gtk yaru-theme-icon yaru-theme-gnome-shell yaru-theme-sound fonts-ubuntu fonts-noto-color-emoji \
        xdg-user-dirs-gtk xdg-desktop-portal-gnome dbus-user-session libgl1-mesa-dri mesa-utils-bin epiphany-browser \
        gnome-keyring libpam-gnome-keyring pipewire wireplumber network-manager-gnome gnome-bluetooth-sendto
    common
    say "GNOME defaults for a phone (scale 3, on-screen keyboard, no suspend)"
    cat > "$OVR" <<'G'
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
[org.gnome.desktop.screensaver]
lock-enabled=false
G
    glib-compile-schemas /usr/share/glib-2.0/schemas
    # Wayland only: Xorg has no driver for this panel. GDM's udev rule would otherwise prefer Xorg when it
    # sees no hardware GL.
    mkdir -p /etc/gdm3
    if [ -f /etc/gdm3/custom.conf ]; then sed -i 's/^#\?WaylandEnable=.*/WaylandEnable=true/' /etc/gdm3/custom.conf; fi
    ln -sf /dev/null /etc/udev/rules.d/61-gdm.rules
    sc disable phosh.service
    sc enable gdm3.service; sc enable gdm.service
    printf '/usr/sbin/gdm3\n' > /etc/X11/default-display-manager 2>/dev/null || true
    sc set-default graphical.target
    rm -f /etc/environment.d/51-oneplus13-lomiri.conf "/var/lib/AccountsService/users/$U"
    echo gnome > /etc/oneplus13-desktop
    say "GNOME is set up for user $U. Reboot to start it (sudo reboot)." ;;
phosh)
    [ -n "$U" ] || { echo "no user with uid 1000; pass the user name"; exit 1; }
    say "packages (Phosh shell, phoc compositor, on-screen keyboard; about 700 MB installed)"
    apt_get update
    apt_get install --no-install-recommends phosh phoc phosh-osk-stub phosh-mobile-settings gnome-settings-daemon gnome-session-bin \
        gnome-control-center gnome-terminal nautilus gnome-text-editor epiphany-browser fonts-ubuntu fonts-noto-color-emoji \
        adwaita-icon-theme xdg-user-dirs dbus-user-session libgl1-mesa-dri gnome-keyring libpam-gnome-keyring pipewire wireplumber
    common
    say "Phosh defaults (scale 3, no suspend)"
    mkdir -p /etc/phosh
    printf '[core]\nxwayland=false\n\n[output:DSI-1]\nscale = 3\n' > /etc/phosh/phoc.ini
    cat > "$OVR" <<'G'
[org.gnome.settings-daemon.plugins.power]
power-button-action='nothing'
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
[org.gnome.desktop.a11y.applications]
screen-keyboard-enabled=true
G
    glib-compile-schemas /usr/share/glib-2.0/schemas
    # Debian's phosh.service runs the session for uid 1000 on tty7.
    sc disable gdm3.service; sc disable gdm.service
    sc enable phosh.service
    sc set-default graphical.target
    echo phosh > /etc/oneplus13-desktop
    say "Phosh is set up for user $U. Reboot to start it (sudo reboot). The lock screen takes the user's password." ;;
lomiri)
    [ -n "$U" ] || { echo "no user with uid 1000; pass the user name"; exit 1; }
    say "packages (Lomiri shell on Mir, Ubuntu Touch core apps, Maliit keyboard, GDM login; about 1.2 GB installed)"
    apt_get update
    # Ubuntu Touch itself (the Halium system image) has no OnePlus 13 port; this is its shell from Ubuntu's archive.
    # State 2026-11-23 (lomiri 0.2.1, qtmir 0.8.0~git20240131, Mir 2.14.1): Mir comes up on the panel with llvmpipe
    # and sees the touch panel, then lomiri segfaults about 2 s in, in qtmir's PlatformScreen::makeCurrent(), and
    # GDM returns to the login screen. Not fixed by the missing wizard modules or the wizard-has-run marker below.
    # GDM is the login screen: Lomiri's own greeter needs LightDM, one more unknown on this panel.
    apt_get install --no-install-recommends gdm3 gnome-shell gnome-session-bin gnome-settings-daemon yaru-theme-gnome-shell \
        lomiri lomiri-desktop-session lomiri-system-settings lomiri-terminal-app maliit-keyboard maliit-framework \
        suru-icon-theme fonts-ubuntu fonts-noto-color-emoji dbus-user-session libgl1-mesa-dri mesa-utils-bin \
        mir-graphics-drivers-desktop pipewire pipewire-pulse wireplumber xdg-user-dirs morph-browser \
        qtwayland5 qml-module-ofono lomiri-polkit-agent lomiri-indicator-transfer lomiri-sounds inotify-tools
    # qtwayland5: the Maliit keyboard is a Qt Wayland client. qml-module-ofono: the first-run wizard imports it.
    # Never install repowerd (a Recommends of lomiri-system-settings): it suspends the phone on its own.
    # One apt call per app: a single unknown name would otherwise skip them all.
    for a in lomiri-calculator-app lomiri-clock-app lomiri-filemanager-app lomiri-gallery-app lomiri-music-app \
             lomiri-docviewer-app lomiri-mediaplayer-app content-hub; do
        apt_get install --no-install-recommends "$a" >/dev/null 2>&1 || echo "skipped $a (not available)"
    done
    common
    say "Lomiri defaults (phone-sized grid unit, no suspend), Lomiri as $U's session"
    # One grid unit is 8 px at about 160 dpi; this panel is about 510 dpi.
    printf 'GRID_UNIT_PX=26\nQT_WAYLAND_DISABLE_WINDOWDECORATION=1\n' > /etc/environment.d/51-oneplus13-lomiri.conf
    cat > "$OVR" <<'G'
[org.gnome.desktop.interface]
scaling-factor=uint32 3
[org.gnome.desktop.a11y.applications]
screen-keyboard-enabled=true
[org.gnome.settings-daemon.plugins.power]
power-button-action='nothing'
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
G
    glib-compile-schemas /usr/share/glib-2.0/schemas
    mkdir -p /etc/gdm3 /var/lib/AccountsService/users
    if [ -f /etc/gdm3/custom.conf ]; then sed -i 's/^#\?WaylandEnable=.*/WaylandEnable=true/' /etc/gdm3/custom.conf; fi
    ln -sf /dev/null /etc/udev/rules.d/61-gdm.rules
    LS=$(basename "$(ls /usr/share/wayland-sessions/lomiri*.desktop 2>/dev/null | head -1)" .desktop)
    [ -n "$LS" ] || { echo "no Lomiri session file in /usr/share/wayland-sessions"; exit 1; }
    printf '[User]\nSession=%s\nXSession=%s\nSystemAccount=false\n' "$LS" "$LS" > "/var/lib/AccountsService/users/$U"
    # The first-run wizard needs modules Ubuntu does not package (Lomiri.SystemSettings.Update); skip it.
    H=$(getent passwd "$U" | cut -d: -f6)
    if [ -d "$H" ]; then install -d -o "$U" -g "$U" "$H/.config" "$H/.config/lomiri"; install -o "$U" -g "$U" -m 644 /dev/null "$H/.config/lomiri/wizard-has-run"; fi
    sc disable phosh.service
    sc enable gdm3.service; sc enable gdm.service
    printf '/usr/sbin/gdm3\n' > /etc/X11/default-display-manager 2>/dev/null || true
    sc set-default graphical.target
    echo lomiri > /etc/oneplus13-desktop
    say "Lomiri is set up for user $U (session $LS). Reboot to start it (sudo reboot); log in at the GDM screen." ;;
none)
    sc disable gdm3.service; sc disable gdm.service; sc disable phosh.service
    sc set-default multi-user.target
    text_console on
    echo none > /etc/oneplus13-desktop
    say "Text console is the default again. Reboot to apply (sudo reboot). Packages were left installed." ;;
status)
    echo "configured desktop: $(cat /etc/oneplus13-desktop 2>/dev/null || echo none)"
    echo "default target:     $(systemctl get-default 2>/dev/null)"
    for s in gdm3 gdm phosh; do printf '%-19s %s / %s\n' "$s.service:" "$(systemctl is-enabled $s.service 2>&1 | head -1)" "$(systemctl is-active $s.service 2>&1 | head -1)"; done
    echo "touch at boot:      $([ -f /etc/modules-load.d/oneplus13-touch.conf ] && echo yes || echo no)"
    grep -E '^N: Name="touchpanel"' /proc/bus/input/devices >/dev/null 2>&1 && echo "touch panel:        present" || echo "touch panel:        not loaded" ;;
*)
    sed -n '2,8p' "$0"; exit 1 ;;
esac
