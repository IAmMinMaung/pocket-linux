#!/bin/bash
# Build extra modules (USB Wi-Fi) for the phone's stage-2 kernel in the same Docker volume/image as kernel/stage1.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd); mkdir -p "$HERE/logs"
docker build -q -t root-android-stage1 "$HERE/kernel/stage1" >/dev/null
exec docker run --rm --platform linux/arm64 -v omarchy-build:/work -v "$HERE:/mnt/project" -e JOBS="${JOBS:-12}" \
  root-android-stage1 bash /mnt/project/kernel/stage2-modules/in-container.sh
