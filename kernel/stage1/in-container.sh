#!/bin/bash
# Runs inside the root-android-stage1 container (see build.sh). Builds the
# debug stage-1 chainloader kernel around the stage-2 artifacts that booted
# the phone, and packs boot-chain-install-dbg.img.
set -euo pipefail
W=/work; M=/mnt/mac; P=/mnt/project
# Stage-2 artifacts: newest omarchy-dodge-stage2-* unless STAGE2_SRC names one (relative to the project).
STAGE2_SRC=$P/${STAGE2_SRC:-$(cd $P/firmware/images && ls -d omarchy-dodge-stage2-* 2>/dev/null | sort | tail -1)}
[ -f "$STAGE2_SRC/Image" ] || { echo "no stage-2 artifacts under firmware/images/omarchy-dodge-stage2-*/ (scripts/omarchy-build-phone.sh stage2/initramfs/pull)"; exit 1; }
# Live Android device tree (the phone's /sys/firmware/fdt, dumped as root): memory map for stage 2.
LIVE_SRC=${LIVE_DTB:-$(ls $P/firmware/images/Original-*-allfw-*/live-fdt-android.dtb $P/firmware/images/*/live.dtb 2>/dev/null | head -1)}
[ -f "$LIVE_SRC" ] || { echo "no live DTB: adb shell su -c 'cat /sys/firmware/fdt' > firmware/images/<dump-dir>/live-fdt-android.dtb, or set LIVE_DTB"; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

say "kernel source (local clone, case-sensitive fs)"
if [ ! -d $W/linux/.git ]; then git clone -q $M/src/linux $W/linux; fi
cd $W/linux && git checkout -q -- . && git describe --tags --always && test -z "$(git status --short)"

say "omarchy-mobile tree + mkbootimg"
rsync -a --delete --exclude=.git $M/src/omarchy-mobile/ $W/omarchy-mobile/
mkdir -p $W/omarchy-mobile/system/tools
rsync -a --delete $M/src/mkbootimg/ $W/omarchy-mobile/system/tools/mkbootimg/

say "stage-2 inputs"
mkdir -p $W/stage2 $W/dl
cp $STAGE2_SRC/Image $STAGE2_SRC/.config $STAGE2_SRC/initramfs.cpio.lz4 $STAGE2_SRC/sm8750-oneplus-dodge.dtb $W/stage2/
cp "$LIVE_SRC" $W/live.dtb
sha256sum $W/stage2/Image

say "chainload dir: debug init, fbtext, font, build id"
rm -rf $W/chainload; mkdir -p $W/chainload
install -m755 $P/kernel/stage1/init $W/chainload/init
cp $W/omarchy-mobile/device/dodge/chainload/stage2-dtb.py $W/chainload/
musl-gcc -O2 -static -Wall -o $W/chainload/fbtext $P/kernel/stage1/fbtext.c
musl-gcc -O2 -static -Wall -o $W/chainload/memcp $P/kernel/stage1/memcp.c
for f in Lat15-Terminus32x16 Lat15-TerminusBold32x16 Lat15-Fixed16 Lat15-Terminus16; do
  if [ -f /usr/share/consolefonts/$f.psf.gz ]; then gunzip -c /usr/share/consolefonts/$f.psf.gz > $W/chainload/font.psf; echo "font: $f"; break; fi
done
test -s $W/chainload/font.psf
BUILD_ID=$(date -u +%Y%m%d-%H%M%S); echo "$BUILD_ID" > $W/chainload/build-id

say "patched dodge-chain (fdtput/libfdt, fbtext, font, build-id in the stage-1 initramfs)"
cd $W/omarchy-mobile
python3 - <<'PY'
p="tools/dodge-chain"; s=open(p).read()
a='"$dl/apks" busybox-static kexec-tools) ||'; assert a in s; s=s.replace(a,'"$dl/apks" busybox-static kexec-tools dtc libfdt) ||')
a='file /omamobile/memory.reg $work/memory.reg 0644 0 0\n'; assert a in s
s=s.replace(a,a+'''file /omamobile/fbtext $CHAINLOAD_DIR/fbtext 0755 0 0
file /omamobile/memcp $CHAINLOAD_DIR/memcp 0755 0 0
file /omamobile/font.psf $CHAINLOAD_DIR/font.psf 0644 0 0
file /omamobile/build-id $CHAINLOAD_DIR/build-id 0644 0 0
file /omamobile/fdtput $x/usr/bin/fdtput 0755 0 0
file /omamobile/fdtget $x/usr/bin/fdtget 0755 0 0
file /omamobile/lib/libfdt.so.1 $(readlink -f "$x/usr/lib/libfdt.so.1") 0644 0 0
dir /tmp 1777 0 0
''')
a='STAGE1_CMDLINE="rdinit=/omamobile/init panic=10 irqchip.gicv3_nolpi=1"'; assert a in s
s=s.replace(a,'STAGE1_CMDLINE="rdinit=/omamobile/init panic=30 irqchip.gicv3_nolpi=1 ramoops.mem_address=0xfe000000 ramoops.mem_size=0x200000 ramoops.record_size=0x40000 ramoops.console_size=0x100000 ramoops.pmsg_size=0 ramoops.ftrace_size=0"')
open("tools/dodge-chain-dbg","w").write(s)
PY
chmod +x tools/dodge-chain-dbg

say "pack (stage-1 kernel build)"
export KERNEL_DIR=$W/linux STAGE2_OUT=$W/stage2 CHAIN_OUT=$W/stage2/chain
# Stage 2's initrd goes in UNCOMPRESSED: the stage-1 cpio is zstd-compressed as a whole at kernel link, and
# zstd on raw data beats lz4-inside-zstd by several MiB (the flashed boot seems to need the image under ~60 MiB).
lz4 -dc $W/stage2/initramfs.cpio.lz4 > $W/stage2/initramfs.cpio; ls -l $W/stage2/initramfs.cpio*
export STAGE2_IMAGE=$W/stage2/Image STAGE2_DTB_IN=$W/stage2/sm8750-oneplus-dodge.dtb STAGE2_INITRD=$W/stage2/initramfs.cpio
export LIVE_DTB=$W/live.dtb CHAINLOAD_DIR=$W/chainload ALPINE_DL=$W/dl JOBS=${JOBS:-12}
# panic=900 instead of 10 and ramoops (0xfe400000, inside the splash reservation): a crashed stage 2 stays on
# screen and its console survives a warm reset into fastboot; read back with /sys/fs/pstore after a RAM boot.
export STAGE2_CMDLINE="rdinit=/init clk_ignore_unused pd_ignore_unused panic=900 console=tty0 ramoops.mem_address=0xfe400000 ramoops.mem_size=0x200000 ramoops.record_size=0x40000 ramoops.console_size=0x100000 ramoops.pmsg_size=0 ramoops.ftrace_size=0" SLOT_SUFFIX=_b
date; bash tools/dodge-chain-dbg pack; date

say "copy out"
OUT=$P/firmware/images/omarchy-dodge-chain-dbg-$BUILD_ID; mkdir -p $OUT
cp $CHAIN_OUT/images/boot-chain.img $OUT/boot-chain-install-dbg.img
cp $CHAIN_OUT/.config $OUT/stage1.config; cp $CHAIN_OUT/chain/memory.reg $CHAIN_OUT/chain/cmdline $CHAIN_OUT/chain/stage2.dtb $OUT/
cp $W/chainload/init $OUT/stage1-init; cp $W/chainload/build-id $OUT/
(cd $OUT && sha256sum * > SHA256SUMS && cat SHA256SUMS && ls -l boot-chain-install-dbg.img)
echo BUILD-DONE
