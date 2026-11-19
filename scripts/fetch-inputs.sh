#!/usr/bin/env bash
# Download the third-party inputs that are not committed (binary) and verify them against the committed checksums.
#   scripts/fetch-inputs.sh          Ubuntu Base tarball + Termux apk
#   scripts/fetch-inputs.sh ota      the stock OTA zip only (delegates to scripts/download-stock-ota.sh, 8.2 GB)
#   scripts/fetch-inputs.sh all      everything above
#   rootfs/ubuntu-base-24.04.5-arm64/ubuntu-base-24.04.5-base-arm64.tar.gz   Ubuntu Base for the on-phone chroot
#   tools/apk/termux-app_v0.118.3+github-debug_arm64-v8a.apk                  Termux (optional terminal on the phone)
#   tools/apk/Magisk-v31.1.apk                                                 Magisk app (patches init_boot on the phone, Phase 2)
# Links and checksums are listed in DOWNLOADS.md.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
get() { # $1 url, $2 dest dir, $3 sums file (in dest dir)
    local url=$1 dir=$2 sums=$3 f; f=$(basename "$url"); mkdir -p "$dir"
    if [ -f "$dir/$f" ] && (cd "$dir" && grep " $f\$" "$sums" | shasum -a 256 -c - >/dev/null 2>&1); then echo "ok      $dir/$f"; return; fi
    echo "fetch   $url"; curl -fL --retry 3 -o "$dir/$f.part" "$url"
    (cd "$dir" && grep " $f\$" "$sums" | sed "s/ $f\$/ $f.part/" | shasum -a 256 -c -) || { rm -f "$dir/$f.part"; echo "CHECKSUM MISMATCH for $f"; exit 1; }
    mv "$dir/$f.part" "$dir/$f"; echo "ok      $dir/$f"
}
MODE=${1:-inputs}
if [ "$MODE" = ota ] || [ "$MODE" = all ]; then sh "$HERE/scripts/download-stock-ota.sh"; fi
[ "$MODE" = ota ] && exit 0
get https://cdimage.ubuntu.com/ubuntu-base/releases/24.04.5/release/ubuntu-base-24.04.5-base-arm64.tar.gz \
    "$HERE/rootfs/ubuntu-base-24.04.5-arm64" SHA256SUMS
get https://github.com/termux/termux-app/releases/download/v0.118.3/termux-app_v0.118.3+github-debug_arm64-v8a.apk \
    "$HERE/tools/apk" termux_sha256sums.txt
get https://github.com/topjohnwu/Magisk/releases/download/v31.1/Magisk-v31.1.apk \
    "$HERE/tools/apk" magisk_sha256sums.txt
