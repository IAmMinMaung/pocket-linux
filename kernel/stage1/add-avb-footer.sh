#!/usr/bin/env bash
# Give a dodge chain image the AVB footer ABL needs for a FLASHED boot of boot_b.
#   kernel/stage1/add-avb-footer.sh <boot-chain-install*.img>   -> <same name>-avb.img (96 MiB)
# vbmeta_b chains `boot` to a vbmeta inside the partition's own footer. Unlocked ABL tolerates any key and
# a stale hash, but a chained partition with NO footer is an invalid-metadata error even when unlocked: the
# phone resets ~10 s after the yellow screen and falls back to slot a. `fastboot boot` skips AVB, which is
# why RAM boots always worked. Parameters mirror the stock boot_b footer (rollback 0, os 15, SPL 2026-03-01).
set -eu
HERE=$(cd "$(dirname "$0")/../.." && pwd)
IMG=${1:?chain image}; OUT=${IMG%.img}-avb.img
AVB=$HERE/tools/avb
[ -f "$AVB/avbtool.py" ] && [ -f "$AVB/testkey_rsa4096.pem" ] || { echo "tools/avb/ missing (see its README)"; exit 1; }
cp "$IMG" "$OUT"
python3 -I "$AVB/avbtool.py" add_hash_footer --image "$OUT" --partition_name boot --partition_size 100663296 \
  --algorithm SHA256_RSA4096 --key "$AVB/testkey_rsa4096.pem" --salt "$(shasum -a 256 "$IMG" | cut -d' ' -f1)" \
  --rollback_index 0 --prop com.android.build.boot.os_version:15 --prop com.android.build.boot.security_patch:2026-03-01
python3 -I "$AVB/avbtool.py" info_image --image "$OUT" | grep -E "Image size|Original image size|Algorithm|Rollback Index:|Partition Name"
shasum -a 256 "$OUT" | tee -a "$(dirname "$OUT")/SHA256SUMS"
