# Ubuntu 24.04 (arm64) on the OnePlus 13 — native userspace in a chroot

Set up 2026-11-18. This is **Linux userspace inside Android**: a real arm64 Ubuntu
24.04.5 LTS root filesystem running on the phone's own CPU with no emulation,
sharing Android's kernel (6.6.89) via a chroot. Android keeps running. It is not
a native Linux install (see `docs/linux-compatibility.md` for that status).

## Layout

| Where | What |
|---|---|
| `/data/local/ubuntu/` (phone) | the Ubuntu root filesystem (~0.5 GB + whatever you install) |
| `/data/local/ubuntu/start.sh` (phone) | launcher: bind-remounts the rootfs without nosuid, mounts /dev, /dev/pts, /proc, /sys, /tmp and `/mnt/sdcard` → internal storage, then `chroot` |
| `rootfs/ubuntu-base-24.04.5-arm64/` (Mac) | the official Ubuntu Base tarball, SHA-256 verified |
| `scripts/ubuntu-chroot-setup.sh` (Mac) | idempotent setup/reinstall script, runs everything over adb + Magisk su |
| `tools/apk/` (Mac) | Termux v0.118.3 official APK, SHA-256 verified; installed on the phone |

User `min` exists inside Ubuntu with passwordless sudo and is in group `aid_inet`
(3003), which Android requires for any process that opens network sockets.
`_apt` is in that group too, so apt works.

## Entering Ubuntu

```bash
# From the Mac (root shell inside Ubuntu)
tools/platform-tools/adb shell su -c /data/local/ubuntu/start.sh
# As the normal user
tools/platform-tools/adb shell "su -c '/data/local/ubuntu/start.sh su - min'"
# From Termux on the phone (grant Termux superuser in Magisk the first time)
su -c /data/local/ubuntu/start.sh
```

Any command can be appended: `start.sh /bin/bash -c 'apt update'`.

## Facts learned the hard way

- Ubuntu Base ships `/etc/resolv.conf` as a dangling systemd-resolved symlink; the setup replaces it with a plain file (1.1.1.1, 8.8.8.8).
- `/data` is mounted `nosuid,nodev`; without the bind remount in `start.sh`, `sudo` and `su` fail with "effective uid is not 0". The self-bind must be made private and detected via mountinfo: a shared self-bind replicated every submount per launch and hit the 100k mount limit (2026-11-18).
- Nothing works while the phone is offline; "Active default network: none" in `dumpsys connectivity` is the tell. The phone's clock also only syncs once online.
- Processes inside the chroot run in the `u:r:magisk:s0` SELinux context; SELinux stays enforcing for Android.

## Removal

```bash
tools/platform-tools/adb shell su -c "umount -l /data/local/ubuntu/{mnt/sdcard,tmp,sys,proc,dev/pts,dev} /data/local/ubuntu; rm -rf /data/local/ubuntu"
```

## Next steps (optional)

- Desktop: `apt install xfce4` + Termux:X11, or a VNC server, for a GUI on the phone screen.
- Dev stack: build-essential, Node, Rust, Docker is **not** possible (needs its own kernel features/cgroups the Android kernel does not expose for unprivileged use).
- Local AI inference: llama.cpp builds natively here and can use the 8 Elite's CPU; GPU (Adreno 830) acceleration needs OpenCL/Vulkan drivers that Android keeps to itself.
