#!/bin/bash
# Fetch the three source trees the stage-1 build and the on-phone build use, into kernel/src/ (gitignored).
#   kernel/stage1/fetch-sources.sh            clone or update
# Pins: the kernel tag that produced 7.3.0-rc6-omamobile-push1-g6cc4b65df980 (dodge DTB, omamobile base),
# omarchy-mobile main (tools/dodge-chain, device/dodge), AOSP mkbootimg. Clone on macOS loses a few
# case-colliding kernel files; in-container.sh re-clones inside Linux and restores them with git checkout.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd); S=$HERE/kernel/src; mkdir -p "$S"
KERNEL_REPO=${KERNEL_REPO:-https://github.com/mrlund/linux-omarchy-mobile}
KERNEL_TAG=${KERNEL_TAG:-dodge-v3-20261101}
OMAMOBILE_REPO=${OMAMOBILE_REPO:-https://github.com/derekross/omarchy-mobile}
MKBOOTIMG_REPO=${MKBOOTIMG_REPO:-https://android.googlesource.com/platform/system/tools/mkbootimg}
if [ ! -d "$S/linux/.git" ]; then
  git clone --depth 1 --branch "$KERNEL_TAG" "$KERNEL_REPO" "$S/linux"
else (cd "$S/linux" && git fetch --depth 1 origin "tag" "$KERNEL_TAG" && git checkout -q "$KERNEL_TAG"); fi
if [ ! -d "$S/omarchy-mobile/.git" ]; then git clone --depth 1 "$OMAMOBILE_REPO" "$S/omarchy-mobile"; else (cd "$S/omarchy-mobile" && git pull -q --ff-only); fi
if [ ! -d "$S/mkbootimg/.git" ]; then git clone --depth 1 "$MKBOOTIMG_REPO" "$S/mkbootimg"; else (cd "$S/mkbootimg" && git pull -q --ff-only); fi
for d in linux omarchy-mobile mkbootimg; do printf '%-16s %s\n' "$d" "$(cd "$S/$d" && git describe --tags --always 2>/dev/null)"; done
