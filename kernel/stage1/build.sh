#!/bin/bash
# Build the debug stage-1 chain image in Docker (arm64 natively on Apple Silicon).
#   kernel/stage1/build.sh            build image + run the build (log in logs/)
# Sources: kernel/src/{linux,omarchy-mobile,mkbootimg}, fetched by kernel/stage1/fetch-sources.sh
# (override with SRC_MAC=<dir containing src/>). They are cloned into the Docker volume
# omarchy-build (created on demand) so the kernel's case-colliding files survive (macOS is
# case-insensitive). Inputs: the latest firmware/images/omarchy-dodge-stage2-*/ (from
# scripts/omarchy-build-phone.sh pull) and a live DTB dump; see in-container.sh.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
SRC_MAC=${SRC_MAC:-$HERE/kernel}
for d in linux omarchy-mobile mkbootimg; do
  [ -d "$SRC_MAC/src/$d" ] || { echo "missing $SRC_MAC/src/$d: run kernel/stage1/fetch-sources.sh first"; exit 1; }
done
mkdir -p "$HERE/logs"
docker build -q -t root-android-stage1 "$HERE/kernel/stage1"
docker volume create omarchy-build >/dev/null
exec docker run --rm --platform linux/arm64 -v omarchy-build:/work -v "$SRC_MAC:/mnt/mac:ro" -v "$HERE:/mnt/project" \
  -e JOBS="${JOBS:-12}" root-android-stage1 bash /mnt/project/kernel/stage1/in-container.sh
