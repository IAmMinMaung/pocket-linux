#!/bin/bash
# Install or remove a graphical desktop on the phone's native Ubuntu, from the Mac, over SSH.
#
#   scripts/omarchy-desktop.sh gnome  USER@HOST    regular Ubuntu desktop (GNOME, GDM login)
#   scripts/omarchy-desktop.sh lomiri USER@HOST    Lomiri, the Ubuntu Touch shell (from Ubuntu's archive)
#   scripts/omarchy-desktop.sh phosh  USER@HOST    Phosh, the phone shell
#   scripts/omarchy-desktop.sh none   USER@HOST    back to the text console (packages stay)
#   scripts/omarchy-desktop.sh status USER@HOST    what is configured
#
# HOST is the phone's Wi-Fi address, or its USB link-local address with the interface, quoted:
#   scripts/omarchy-desktop.sh gnome 'me@fe80::1234:56ff:fe78:9abc%en13'
# (find it with: ndp -an | grep en13 | grep -v permanent). The phone needs internet access (Wi-Fi) for apt.
#
# This copies scripts/phone-desktop.sh to the phone and runs it with sudo; the install takes 5-10 minutes and
# its log stays on the phone in /var/log/phone-desktop.log. Nothing is written to any partition table or boot
# partition. Reboot the phone afterwards (sudo reboot) to start or stop the desktop.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
KEY="$HERE/keys/omarchy-dodge_ed25519"
MODE=${1:-}; TARGET=${2:-}
case "$MODE" in gnome|lomiri|phosh|none|status) ;; *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;; esac
[ -n "$TARGET" ] || { echo "give the phone as USER@HOST (see the top of this script)"; exit 1; }
[ -f "$KEY" ] || { echo "no $KEY (the key baked into the image by omarchy-build-phone.sh)"; exit 1; }
U=${TARGET%%@*}
SSH_OPTS="-i $KEY -o ConnectTimeout=10 -o ServerAliveInterval=15"
case "$TARGET" in *fe80:*) SSH_OPTS="-6 $SSH_OPTS" ;; esac
# scp wants a bracketed IPv6 literal
case "$TARGET" in *:*) SCP_TARGET="$U@[${TARGET#*@}]" ;; *) SCP_TARGET=$TARGET ;; esac

# shellcheck disable=SC2086
scp -q $SSH_OPTS "$HERE/scripts/phone-desktop.sh" "$SCP_TARGET:/tmp/phone-desktop.sh"
if [ "$MODE" = status ]; then
    # shellcheck disable=SC2086
    exec ssh $SSH_OPTS "$TARGET" "sudo bash /tmp/phone-desktop.sh status"
fi
echo "Running on the phone: phone-desktop.sh $MODE $U   (log: /var/log/phone-desktop.log on the phone)"
# shellcheck disable=SC2086
ssh -t $SSH_OPTS "$TARGET" "sudo install -m 755 /tmp/phone-desktop.sh /usr/local/sbin/phone-desktop && sudo /usr/local/sbin/phone-desktop $MODE $U 2>&1 | sudo tee /var/log/phone-desktop.log | grep -E '^==>|^E:|rror' ; exit \${PIPESTATUS[0]}"
echo "Done. Reboot the phone to apply:  ssh $TARGET sudo reboot"
