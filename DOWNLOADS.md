# Downloads

Every large input is fetched, not committed. One command gets all of them (each is skipped when already present and
its checksum matches):

```bash
scripts/fetch-inputs.sh all      # Ubuntu Base + Termux + the stock OTA (hours: 8.2 GB from OPPO's CDN)
scripts/fetch-inputs.sh          # Ubuntu Base + Termux only
scripts/fetch-inputs.sh ota      # stock OTA only (same as scripts/download-stock-ota.sh)
```

| What | Where it lands | Verify |
|---|---|---|
| Ubuntu Base 24.04.5 arm64 (root for the on-phone chroot and the Linux rootfs) | `rootfs/ubuntu-base-24.04.5-arm64/ubuntu-base-24.04.5-base-arm64.tar.gz` | sha256 `a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2` |
| Termux 0.118.3 arm64 (optional terminal app on the phone) | `tools/apk/termux-app_v0.118.3+github-debug_arm64-v8a.apk` | sha256 `72fdb596045116bf5ba1b5bdf5b26fddb9acc0bd074ad9f2da9eb0ae85e83a4e` |
| Magisk v31.1 app (Phase 2: patches init_boot on the phone; installed with `adb install`, not sideloaded) | `tools/apk/Magisk-v31.1.apk` | sha256 `89cefac0a318afa39fb3880c45c87b036c05bc1ebf02a7a715b7f8d7c26ac6e7`, APK signer CN=John Wu, cert sha256 `B4:CB:83:B4:DA:D9:9F:99:7D:BE:87:2F:01:3A:A1:6C:14:EE:C4:1D:16:70:21:F3:71:F7:E1:33:0F:27:3E:E6` |
| OnePlus 13 PJZ110 full OTA, ColorOS 16.0.5.703(CN01) build C.88 (stock boot/init_boot/vendor_boot/vbmeta for Phase 2) | `firmware/images/PJZ110_16.0.5.703_CN01_C88.zip` | md5 `2cc8031b2589dd4e80bd3c93326c7c7e`, 8769806346 bytes |
| Google Platform-Tools (adb, fastboot), latest macOS build | `tools/platform-tools/` | fetched by `scripts/android-tool.sh env` |
| avbtool 1.4.0 + AOSP test key `testkey_rsa4096.pem` (Phase 3: AVB footer on the flashed boot_b chain image; same pin as Omarchy Mobile `tools/toolchain.lock`, platform/external/avb commit ba2dec4b035b) | `tools/avb/` | sha256 in `checksums/inputs.sha256`; fetched by `kernel/stage1/fetch-avb.sh` |
| Kernel + Omarchy Mobile + mkbootimg sources | `kernel/src/` on the Mac, `/root/src` in the phone chroot | `kernel/stage1/fetch-sources.sh`, `scripts/omarchy-build-phone.sh sources` (tag `dodge-v3-20261101`) |

## Links

- Ubuntu Base: https://cdimage.ubuntu.com/ubuntu-base/releases/24.04.5/release/ubuntu-base-24.04.5-base-arm64.tar.gz
  (release page https://cdimage.ubuntu.com/ubuntu-base/releases/24.04.5/release/ , official SHA256SUMS there)
- Termux: https://github.com/termux/termux-app/releases/tag/v0.118.3
- Magisk: https://github.com/topjohnwu/Magisk/releases/tag/v31.1 (official source only; v31.1 is the version that rooted
  this phone). Install: `tools/platform-tools/adb install tools/apk/Magisk-v31.1.apk`. A newer release is fine as long as
  the checksum file `checksums/inputs.sha256` and the URL in `scripts/fetch-inputs.sh` are updated together.
- Stock OTA, OPPO component OTA CDN (signed link, can expire):
  `https://component-ota-cn.allawntech.com/downloadCheck?c=6ae1589edf7d7740a1f42a85b4a954d0&p=a6c78fdd3751888b39cedbfe149a30629674fce84a6354fe8dbe00ecc720049aefbc31dbee706571eb6fd3282179&d=e181cd82745f88956e8098ec0182623bca30a2a51b7b03ead6e04ce9ca7400d5b4e921c5b4276d&g=10eab6008d5642cf42abd2aa41f847cb&id=69eb51609e207b01827c1fdf&taste=0&supportDLTaste=0&mode=1&tr=manual&s=7af4672db658251c0f05ebba2d4e1ae2`
  Download with `scripts/download-stock-ota.sh`: the CDN resets long connections, so it fetches 128 MiB byte-range
  chunks into `firmware/images/.chunks/` and only accepts the assembled zip when the MD5 matches. Rerun to resume.
  If the server answers with tiny JSON containing `"responseCode":2306`, the link has expired: take a fresh URL and
  MD5 from the phone's own OTA check (see `docs/firmware-sources.md`) and update both in that script together.
- Other PJZ110 firmware sources and which to trust: `docs/firmware-sources.md`.
- Kernel: https://github.com/mrlund/linux-omarchy-mobile (tag `dodge-v3-20261101`), Omarchy Mobile:
  https://github.com/derekross/omarchy-mobile , mkbootimg: https://android.googlesource.com/platform/system/tools/mkbootimg
- Alpine minirootfs 3.24.2 aarch64 (stage-2 initramfs base, fetched on the phone by `omarchy-build-phone.sh sources`):
  https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.2-aarch64.tar.gz
- Arch Linux ARM aarch64 root tarball (only for the `arch` rootfs flavor, fetched on the phone by
  `omarchy-build-phone.sh rootfs`, 830 MB): http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz with its
  `.md5` and `.sig`. It is a moving "latest" file, so no checksum is committed: the build accepts it only when the
  detached signature is valid and made by the Arch Linux ARM build key, fingerprint
  `68B3537F39A313B3E574D06777193F152BDBE6A6` (pinned in the script; the key is fetched from keyserver.ubuntu.com).
  The address is plain http because the host's certificate is issued for another name.

Never flash anything from an older build than the phone runs (anti-rollback), and never flash CDN images as "stock"
on a phone you intend to relock: the lock-safe set is the phone's own dump (`scripts/android-tool.sh backup`).
