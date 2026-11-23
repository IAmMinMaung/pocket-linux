#!/usr/bin/env bash
# Set up a native arm64 Ubuntu 24.04 chroot on the rooted phone under /data/local/ubuntu.
# Runs from the Mac over adb; everything on the phone happens as root via Magisk su.
# Reversible: `adb shell su -c 'rm -rf /data/local/ubuntu'`. Android is not modified.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
ADB="$HERE/tools/platform-tools/adb"
R=/data/local/ubuntu
TAR=/data/local/tmp/ubuntu-base.tar.gz
# User inside the chroot (no password: the chroot is only entered through Magisk su). UBUNTU_USER skips the prompt.
USER_NAME=${UBUNTU_USER:-}
if [ -z "$USER_NAME" ]; then
    { : </dev/tty; } 2>/dev/null || { echo "No terminal to ask for the user name: run from a Terminal window or set UBUNTU_USER=<name>." >&2; exit 1; }
    printf 'Ubuntu user name inside the chroot [%s]: ' "$(id -un)"; read -r USER_NAME </dev/tty || true; USER_NAME=${USER_NAME:-$(id -un)}
fi
printf '%s' "$USER_NAME" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || { echo "invalid user name '$USER_NAME'"; exit 1; }
STAGE=$(mktemp)

# Run a shell snippet as root on the phone. The snippet is passed base64-encoded
# so no quoting survives three shells (zsh/bash -> adb -> su -> sh).
su_sh() { local b; b=$(printf '%s' "$1" | base64); "$ADB" shell "su -c 'echo $b | /data/adb/magisk/busybox base64 -d | sh'" </dev/null; }
# Push a local file to a root-owned path on the phone with a mode.
push_root() { "$ADB" push "$1" /data/local/tmp/.stage </dev/null >/dev/null; su_sh "cp /data/local/tmp/.stage '$2' && chmod $3 '$2' && rm /data/local/tmp/.stage"; }

echo "==> checking root and tarball"
su_sh "id" | grep -q 'uid=0' || { echo "no root"; exit 1; }
LOCAL_TAR=$(ls "$HERE"/rootfs/ubuntu-base-*/ubuntu-base-*-base-arm64.tar.gz 2>/dev/null | tail -1)
if ! su_sh "test -f $TAR && echo tarball-ok" | grep -q tarball-ok; then
    [ -n "$LOCAL_TAR" ] || { echo "no Ubuntu Base tarball under rootfs/ (run scripts/fetch-inputs.sh)"; exit 1; }
    echo "==> pushing $(basename "$LOCAL_TAR") to $TAR"; "$ADB" push "$LOCAL_TAR" "$TAR" </dev/null >/dev/null
fi

echo "==> extracting rootfs to $R"
su_sh "mkdir -p $R && /data/adb/magisk/busybox tar -xzf $TAR -C $R && ls $R | tr '\n' ' '; echo"

echo "==> base config: dns, hosts, hostname, Android network groups"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$STAGE"; push_root "$STAGE" $R/etc/resolv.conf 644
printf '127.0.0.1 localhost oneplus13\n::1 localhost\n' > "$STAGE"; push_root "$STAGE" $R/etc/hosts 644
printf 'oneplus13\n' > "$STAGE"; push_root "$STAGE" $R/etc/hostname 644
# Android's paranoid networking: a process may open sockets only if it is in AID_INET (3003).
su_sh "grep -q '^aid_inet:' $R/etc/group || printf 'aid_inet:x:3003:root,_apt\naid_net_raw:x:3004:root\naid_inet_admin:x:3005:root\n' >> $R/etc/group"

echo "==> launcher $R/start.sh"
cat > "$STAGE" <<'LAUNCH'
#!/system/bin/sh
# Enter the Ubuntu chroot. Needs root:  su -c /data/local/ubuntu/start.sh [command]
R=/data/local/ubuntu
BB=/data/adb/magisk/busybox
# mountpoint(1) compares device numbers, which cannot see a directory bound over itself (same fs),
# so the self-bind is checked in mountinfo by exact mount point; everything else uses mountpoint(1).
m() { tgt=$1; shift; $BB mountpoint -q "$R$tgt" || $BB mount "$@" "$R$tgt"; }
# /data is mounted nosuid,nodev: bind the rootfs over itself and drop those flags so sudo/su work.
# The new mount is made private: /data is a shared mount, and a shared self-bind replicates every
# submount into each peer, doubling the mount table per launch (it reached the 100k limit once).
if ! $BB awk -v r="$R" '$5==r {f=1} END {exit !f}' /proc/self/mountinfo; then
    $BB mount -o bind "$R" "$R"; $BB mount --make-private "$R"; $BB mount -o remount,bind,suid,dev,exec "$R"
fi
m /dev     -o bind /dev
m /dev/pts -o bind /dev/pts
m /proc    -t proc proc
m /sys     -t sysfs sysfs
m /tmp     -t tmpfs -o mode=1777 tmpfs
$BB mkdir -p "$R/mnt/sdcard"; m /mnt/sdcard -o bind /storage/emulated/0
# An interactive login gets its own session with the terminal as controlling tty: Magisk su hands over
# a pty that is not one, and bash then starts with "cannot set terminal process group / no job control".
TTY=""; if [ $# -eq 0 ]; then set -- /bin/bash -l; [ -t 0 ] && TTY="$BB setsid -c"; fi
exec $TTY $BB chroot "$R" /usr/bin/env -i HOME=/root TERM="${TERM:-xterm-256color}" LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
LAUNCH
push_root "$STAGE" $R/start.sh 755

echo "==> first boot inside Ubuntu: apt update, essentials, user '$USER_NAME' (takes a few minutes)"
cat > "$STAGE" <<FIRST
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends sudo nano vim-tiny curl wget ca-certificates locales iproute2 iputils-ping procps less git python3 htop tmux >/dev/null
locale-gen C.UTF-8 >/dev/null 2>&1 || true
id $USER_NAME >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,aid_inet $USER_NAME
printf '$USER_NAME ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/$USER_NAME; chmod 440 /etc/sudoers.d/$USER_NAME
echo first-boot-done
FIRST
push_root "$STAGE" $R/root/first-boot.sh 755
su_sh "$R/start.sh /bin/bash /root/first-boot.sh"

echo "==> verify"
su_sh "$R/start.sh /bin/bash -c 'head -2 /etc/os-release; uname -m; nproc; curl -sI https://archive.ubuntu.com | head -1; su - $USER_NAME -c \"id; sudo -n true && echo sudo-ok\"'"
rm -f "$STAGE"
echo
echo "Ubuntu chroot ready."
echo "  From the Mac:   tools/platform-tools/adb shell -t su -c /data/local/ubuntu/start.sh"
echo "  From Termux:    su -c /data/local/ubuntu/start.sh      (grant Termux root in Magisk when asked)"
echo "  As $USER_NAME:  su -c '/data/local/ubuntu/start.sh su - $USER_NAME'"
