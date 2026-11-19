#!/bin/bash
# Build extra in-tree modules for the stage-2 kernel running on the phone, from the same source commit and
# .config (so vermagic 7.3.0-rc6-omamobile-push1-g6cc4b65df980 matches; the kernel has no MODULE_SIG and no
# MODVERSIONS). Output: /mnt/project/firmware/images/omarchy-dodge-modules-<id>/lib/modules/<ver>/extra/*.ko
set -euo pipefail
W=/work; P=/mnt/project; J=${JOBS:-12}
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
cd $W/linux && git checkout -q -- . && test -z "$(git status --short)" && git describe --tags --always
O=$W/stage2-modules; mkdir -p $O
cp $W/stage2/.config $O/.config
say "enable the common USB Wi-Fi drivers as modules"
./scripts/config --file $O/.config \
  --module RTL8XXXU --enable RTL8XXXU_UNTESTED \
  --module RTW88 --module RTW88_8822BU --module RTW88_8821CU --module RTW88_8822CU --module RTW88_8723DU \
  --module RTW88_8821AU --module RTW88_8812AU \
  --module MT7601U --module MT76x0U --module MT76x2U --module MT7921U \
  --module ATH9K_HTC --disable ATH9K_HTC_DEBUGFS \
  --module RT2X00 --module RT2800USB --enable RT2800USB_RT33XX --enable RT2800USB_RT35XX --enable RT2800USB_RT3573 \
  --enable RT2800USB_RT53XX --enable RT2800USB_RT55XX --enable RT2800USB_UNKNOWN
make -s -C $W/linux O=$O ARCH=arm64 LLVM=1 olddefconfig
grep -E "^CONFIG_(RTL8XXXU|RTW88_USB|RTW88_8822BU|RTW88_8821CU|RTW88_8822CU|RTW88_8723DU|RTW88_8821AU|RTW88_8812AU|MT7601U|MT76x0U|MT76x2U|MT7921U|ATH9K_HTC|RT2800USB)=" $O/.config
say "modules_prepare"
make -s -C $W/linux O=$O ARCH=arm64 LLVM=1 -j$J modules_prepare
cat $O/include/generated/utsrelease.h
say "build the driver directories"
DIRS="drivers/net/wireless/realtek/rtl8xxxu drivers/net/wireless/realtek/rtw88 drivers/net/wireless/mediatek/mt76 drivers/net/wireless/mediatek/mt7601u drivers/net/wireless/ath/ath9k drivers/net/wireless/ralink/rt2x00"
# No vmlinux was built in $O, so modpost cannot resolve kernel symbols here: borrow the stage-1 build's
# Module.symvers (same source) and let modpost warn instead of fail. The phone kernel has no MODVERSIONS, so
# symbols resolve at load time by name.
[ -f $W/stage2/chain/Module.symvers ] && cp $W/stage2/chain/Module.symvers $O/Module.symvers
# MO= keeps the objects out of the source tree (kbuild >= 6.13), so the git tree stays clean.
rm -rf $O/extmod
for d in $DIRS; do make -s -C $W/linux O=$O ARCH=arm64 LLVM=1 -j$J KBUILD_MODPOST_WARN=1 M=$d MO=$O/extmod/$d modules; done
say "collect"
ID=$(date -u +%Y%m%d-%H%M%S); VER=$(sed -n 's/.*"\(.*\)".*/\1/p' $O/include/generated/utsrelease.h)
OUT=$P/firmware/images/omarchy-dodge-modules-$ID/lib/modules/$VER/extra; mkdir -p $OUT
find $O/extmod -name '*.ko' -exec cp {} $OUT/ \;
ls -l $OUT | awk '{print $5, $9}'; (cd $OUT && sha256sum *.ko > ../../../../SHA256SUMS)
echo "$VER" > $P/firmware/images/omarchy-dodge-modules-$ID/KERNEL_RELEASE
echo "MODULES-DONE $OUT"
