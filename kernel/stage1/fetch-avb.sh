#!/usr/bin/env bash
# Fetch avbtool and the AOSP test key into tools/avb/ (gitignored) for kernel/stage1/add-avb-footer.sh.
#   kernel/stage1/fetch-avb.sh            pinned AOSP commit below; sha256 checked against checksums/inputs.sha256
# Source: platform/external/avb on android.googlesource.com (gitiles serves raw files base64-encoded with ?format=TEXT).
# Pin and checksums are the ones Omarchy Mobile uses (omarchy-mobile/tools/toolchain.lock, commit ba2dec4b035b).
set -eu
HERE=$(cd "$(dirname "$0")/../.." && pwd)
TAG=${AVB_REV:-ba2dec4b035b0a3b61c5f8f8a74d86bcd450b1ee}
BASE="https://android.googlesource.com/platform/external/avb/+/$TAG"
DEST="$HERE/tools/avb"; SUMS="$HERE/checksums/inputs.sha256"
mkdir -p "$DEST"
for f in avbtool.py test/data/testkey_rsa4096.pem; do
    out="$DEST/$(basename "$f")"
    if [ -f "$out" ] && (cd "$DEST" && grep " $(basename "$f")\$" "$SUMS" | shasum -a 256 -c - >/dev/null 2>&1); then echo "ok      $out"; continue; fi
    echo "fetch   $BASE/$f"
    curl -fsSL "$BASE/$f?format=TEXT" | base64 -d > "$out.part"
    if grep -q " $(basename "$f")\$" "$SUMS"; then
        (cd "$DEST" && grep " $(basename "$f")\$" "$SUMS" | sed "s/ $(basename "$f")\$/ $(basename "$f").part/" | shasum -a 256 -c -) || { rm -f "$out.part"; echo "CHECKSUM MISMATCH for $f"; exit 1; }
    else
        echo "no pinned checksum for $(basename "$f") in $SUMS; recording $(shasum -a 256 "$out.part" | cut -d' ' -f1)"
        printf '%s  %s\n' "$(shasum -a 256 "$out.part" | cut -d' ' -f1)" "$(basename "$f")" >> "$SUMS"
    fi
    mv "$out.part" "$out"; echo "ok      $out"
done
chmod 755 "$DEST/avbtool.py"
printf 'avbtool + AOSP test key, platform/external/avb commit %s, fetched by kernel/stage1/fetch-avb.sh. Test key = public, for an UNLOCKED bootloader only.\n' "$TAG" > "$DEST/README.txt"
python3 -I "$DEST/avbtool.py" version
