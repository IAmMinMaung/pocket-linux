#!/usr/bin/env bash
# android-tool.sh — guided bootloader unlock, root, and custom ROM helper.
#
# Works on macOS (bash 3.2). Uses Google's Platform-Tools (adb, fastboot) from
# tools/platform-tools and downloads them from dl.google.com when missing.
# Every command is logged to logs/. Read-only steps run freely, reboots ask
# for a y/N, and anything that unlocks, flashes, erases, or sideloads requires
# you to type the device serial. Nothing destructive ever runs automatically.
#
# Usage: scripts/android-tool.sh [--dry-run] <command> [args]
#
#   env                         Ensure Platform-Tools in tools/, check unzip/payload-dumper-go
#   discover                    Identify the connected device, write profiles/device-profile.*
#   unlock                      Pre-flight (Developer options, USB debugging, OEM-unlocking checklist),
#                               get_unlock_ability must be 1, then unlock the bootloader (wipes data)
#   extract-boot <ota.zip>      Stock images -> firmware/images/Original-<build>-from-OTA/Original-*.img
#                               (set EXPECTED_OTA_MD5 to refuse a zip whose MD5 differs)
#   root                        Patch the correct image with Magisk on-device, then boot/flash it
#   recovery boot|flash <img>   Temporarily boot or permanently flash a custom recovery
#   rom <rom.zip>               Sideload a custom ROM zip through recovery (checks target device)
#   restore <partition>         Flash the stock image for a partition back (boot, init_boot, vbmeta…)
#   backup [recovery.img]       Dump live partitions (needs root, or a recovery that fastboot boot
#                               backup gpt: only the GPT head/tail of every LUN, into the LAST_BACKUP dump
#                               accepts; on this OnePlus 13 temp-boot failed, use extract-boot)
#   reboot <system|bootloader|fastbootd|recovery|sideload>
#
# Set ALLOW_DEVICE_MISMATCH=1 to override the ROM/firmware codename check (not advised).

set -eu
set -o pipefail

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
DOCS_DIR="$PROJECT_DIR/docs"
PROFILE_DIR="$PROJECT_DIR/profiles"
LOG_DIR="$PROJECT_DIR/logs"
FW_DIR="$PROJECT_DIR/firmware"
STOCK_DIR="$FW_DIR/stock"
PATCHED_DIR="$FW_DIR/patched"
BACKUP_DIR="$FW_DIR/backup"
IMAGES_DIR="$FW_DIR/images"
TOOLS_DIR="$PROJECT_DIR/tools"
PLATFORM_TOOLS_DIR="$TOOLS_DIR/platform-tools"
PLATFORM_TOOLS_URL="https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"
PROFILE_MD="$PROFILE_DIR/device-profile.md"
PROFILE_ENV="$PROFILE_DIR/device-profile.env"
DRY_RUN=0

mkdir -p "$DOCS_DIR" "$PROFILE_DIR" "$LOG_DIR" "$STOCK_DIR" "$PATCHED_DIR" "$BACKUP_DIR" "$TOOLS_DIR" "$IMAGES_DIR"
LOG_FILE="$LOG_DIR/android-tool-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'sleep 0.2' EXIT   # let tee flush the last lines before the shell returns

# ---------------------------------------------------------------- helpers ---

# adb/fastboot must never read the script's stdin, or they swallow the
# answers typed (or piped) for the confirmation prompts.
adb()      { command adb "$@" </dev/null; }
fastboot() { command fastboot "$@" </dev/null; }

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\n!!  %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

# Log and run a command. In --dry-run only print it.
run() {
    printf '    $ %s\n' "$*"
    [ "$DRY_RUN" = 1 ] && return 0
    "$@"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

confirm_state_change() {
    [ "$DRY_RUN" = 1 ] && { note "(dry-run) would ask: $1"; return 0; }
    printf '\nSTATE CHANGE: %s\n' "$1"
    # AUTO_CONFIRM_STATE=1 answers reboots/temporary boots only. High-risk
    # prompts (unlock, flash, sideload) always require the serial.
    [ "${AUTO_CONFIRM_STATE:-0}" = 1 ] && { note "auto-confirmed (AUTO_CONFIRM_STATE=1)"; return 0; }
    printf 'Proceed? [y/N] '
    read -r answer || die "No answer (stdin closed). Aborted."
    case "$answer" in y|Y|yes|YES) ;; *) die "Aborted by user." ;; esac
}

confirm_high_risk() {
    # $1 description, $2 serial
    [ "$DRY_RUN" = 1 ] && { note "(dry-run) would require serial for: $1"; return 0; }
    cat <<MSG

################################################################################
HIGH RISK: $1
Device serial: $2
This can erase all data or leave the device unbootable. Confirm you have a
documented recovery path (stock firmware + checksum) before continuing.
Type the device serial exactly to proceed, anything else to abort.
################################################################################
MSG
    printf 'Serial: '
    read -r typed || die "No answer (stdin closed). Aborted."
    [ "$typed" = "$2" ] || die "Serial did not match. Aborted."
}

# ---------------------------------------------------------- platform tools ---

platform_tools_version() {
    awk -F= '$1=="Pkg.Revision"{print $2}' "$PLATFORM_TOOLS_DIR/source.properties" 2>/dev/null | tr -d '\r'
}

# Use Google's Platform-Tools from tools/platform-tools, downloading the
# official macOS build from dl.google.com if adb or fastboot is missing there.
ensure_platform_tools() {
    if [ -x "$PLATFORM_TOOLS_DIR/adb" ] && [ -x "$PLATFORM_TOOLS_DIR/fastboot" ]; then
        export PATH="$PLATFORM_TOOLS_DIR:$PATH"
        return 0
    fi
    say "Google Platform-Tools not found in tools/platform-tools; downloading"
    need_cmd curl "curl is required to download Platform-Tools."
    need_cmd unzip "unzip is required to extract Platform-Tools."
    local tmp="$TOOLS_DIR/.download-$$"
    rm -rf "$tmp"; mkdir -p "$tmp"
    note "$PLATFORM_TOOLS_URL"
    curl --fail --location --retry 3 --connect-timeout 30 --progress-bar \
        "$PLATFORM_TOOLS_URL" --output "$tmp/platform-tools.zip" \
        || { rm -rf "$tmp"; die "Download failed. Check the network, or place platform-tools/ in tools/ manually."; }
    unzip -tq "$tmp/platform-tools.zip" >/dev/null \
        || { rm -rf "$tmp"; die "Downloaded file is not a valid zip."; }
    unzip -q "$tmp/platform-tools.zip" -d "$tmp"
    [ -x "$tmp/platform-tools/adb" ] && [ -x "$tmp/platform-tools/fastboot" ] \
        || { rm -rf "$tmp"; die "Archive did not contain platform-tools/adb and fastboot."; }
    rm -rf "$PLATFORM_TOOLS_DIR"
    mv "$tmp/platform-tools" "$PLATFORM_TOOLS_DIR"
    rm -rf "$tmp"
    export PATH="$PLATFORM_TOOLS_DIR:$PATH"
    note "Installed Platform-Tools $(platform_tools_version) to ${PLATFORM_TOOLS_DIR#$PROJECT_DIR/}"
}

# ------------------------------------------------------------ device state ---

adb_state() {
    # prints: device | unauthorized | sideload | recovery | none | multiple
    local lines
    lines=$(adb devices 2>/dev/null | awk 'NR>1 && NF>=2 {print $2}')
    [ -z "$lines" ] && { echo none; return; }
    [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -gt 1 ] && { echo multiple; return; }
    echo "$lines"
}

fb_count() { fastboot devices 2>/dev/null | awk 'NF>0' | wc -l | tr -d ' '; }

device_state() {
    local a
    a=$(adb_state)
    if [ "$(fb_count)" -gt 0 ]; then
        [ "$a" != none ] && { echo multiple; return; }
        echo fastboot; return
    fi
    echo "$a"
}

require_adb() {
    case "$(device_state)" in
        device) ;;
        unauthorized) die "Device is attached but unauthorized. Accept the USB debugging prompt on the phone." ;;
        fastboot) die "Device is in fastboot. Run: $0 reboot system" ;;
        none) die "No device found over adb. Enable USB debugging and check the cable." ;;
        multiple) die "More than one device attached. Connect only the target device." ;;
        *) die "Device is in '$(device_state)' mode; adb shell is not available." ;;
    esac
}

require_fastboot() {
    case "$(device_state)" in
        fastboot) ;;
        device) confirm_state_change "Reboot the device into the bootloader (fastboot)."
                run adb reboot bootloader
                wait_for fastboot ;;
        none) die "No device found. Boot the phone into fastboot (usually Power + Volume Down) and connect it." ;;
        multiple) die "More than one device attached. Connect only the target device." ;;
        *) die "Device is in '$(device_state)' mode; fastboot is not available." ;;
    esac
}

wait_for() {
    # $1 = fastboot | device | sideload
    local i=0
    [ "$DRY_RUN" = 1 ] && return 0
    printf '    waiting for %s' "$1"
    while [ $i -lt 90 ]; do
        [ "$(device_state)" = "$1" ] && { echo; return 0; }
        printf '.'; sleep 2; i=$((i+1))
    done
    echo; die "Timed out waiting for the device to appear in '$1' mode."
}

serial() {
    case "$(device_state)" in
        fastboot) fastboot devices 2>/dev/null | awk 'NR==1{print $1}' ;;
        none|multiple) echo unknown ;;
        *) adb get-serialno 2>/dev/null ;;
    esac
}

fb_var() { fastboot getvar "$1" 2>&1 | awk -F': ' -v k="$1" '$1==k {print $2}' | head -n1; }

# ------------------------------------------------------------- profile io ---

profile_get() {
    [ -f "$PROFILE_ENV" ] || { echo ""; return; }
    awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$PROFILE_ENV"
}
# Paths in the profile (STOCK_DIR, LAST_BACKUP) are stored relative to the project so the checkout can move
# between machines; the LAST value wins (the tool appends). Absolute values from older profiles still work.
profile_path() {
    local v
    [ -f "$PROFILE_ENV" ] || { echo ""; return; }
    v=$(awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/, ""); v=$0} END{print v}' "$PROFILE_ENV")
    case "$v" in "") echo "" ;; /*) echo "$v" ;; *) echo "$PROJECT_DIR/$v" ;; esac
}

profile_require() {
    [ -f "$PROFILE_ENV" ] || die "No device profile yet. Run: $0 discover"
}

# ---------------------------------------------------------------- commands ---

cmd_env() {
    say "Checking the macOS development environment"
    note "Platform-Tools: ${PLATFORM_TOOLS_DIR#$PROJECT_DIR/} (revision $(platform_tools_version))"
    for c in adb fastboot unzip curl md5; do
        if command -v "$c" >/dev/null 2>&1; then
            note "ok       $c -> $(command -v "$c")"
        else
            note "MISSING  $c"
        fi
    done
    if command -v payload-dumper-go >/dev/null 2>&1; then
        note "ok       payload-dumper-go (needed for OTA zips that contain payload.bin)"
    else
        note "optional payload-dumper-go not found; needed to extract images from payload.bin OTAs"
    fi
    if command -v adb >/dev/null 2>&1; then
        note ""; adb version | head -n2 | sed 's/^/    /'
    else
        note "Platform-Tools download failed; rerun to retry."
    fi
    say "Device state: $(device_state)"
}

# discover rewrites the profile from scratch; keep the keys other commands appended (stock set, last dump).
profile_keep_extras() { # $1 = snapshot file; call before the rewrite with "save", after it with "restore"
    case "$1" in
        save)    [ -f "$PROFILE_ENV" ] && grep -E '^(STOCK_BUILD|STOCK_DIR|LAST_BACKUP)=' "$PROFILE_ENV" | awk -F= '!seen[$1]++' > "$2" || : > "$2" ;;
        restore) [ -s "$2" ] && cat "$2" >> "$PROFILE_ENV"; rm -f "$2" ;;
    esac
}

cmd_discover() {
    need_cmd adb "Run: $0 env"
    local state ts extras
    extras="$LOG_DIR/.profile-extras.$$"
    profile_keep_extras save "$extras"
    state=$(device_state)
    ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    say "Device state: $state"

    if [ "$state" = fastboot ]; then
        need_cmd fastboot "Run: $0 env"
        say "Collecting fastboot variables"
        fastboot getvar all 2>&1 | tee "$LOG_DIR/fastboot-getvar-all.txt" | sed 's/^/    /'
        {
            echo "# generated $ts (fastboot mode)"
            echo "SERIAL=$(serial)"
            echo "PRODUCT=$(fb_var product)"
            echo "UNLOCKED=$(fb_var unlocked)"
            echo "SECURE=$(fb_var secure)"
            echo "SLOT_COUNT=$(fb_var slot-count)"
            echo "CURRENT_SLOT=$(fb_var current-slot)"
            echo "HAS_INIT_BOOT=$(fastboot getvar partition-type:init_boot 2>&1 | grep -q 'partition-type' && echo yes || echo no)"
        } > "$PROFILE_ENV"
        profile_keep_extras restore "$extras"
        note "Only partial profile possible from fastboot. Reboot to Android and rerun for full details."
        return
    fi

    require_adb
    say "Collecting Android properties"
    local props="ro.product.manufacturer ro.product.brand ro.product.model ro.product.name ro.product.device ro.product.board ro.board.platform ro.hardware ro.product.cpu.abi ro.build.version.release ro.build.version.sdk ro.build.version.security_patch ro.build.display.id ro.build.version.ota ro.build.version.incremental ro.build.fingerprint ro.boot.verifiedbootstate ro.boot.flash.locked ro.boot.vbmeta.device_state ro.boot.slot_suffix ro.build.ab_update ro.boot.dynamic_partitions ro.boot.dynamic_partitions_retrofit ro.boot.hardware.revision ro.treble.enabled ro.vndk.version"
    adb shell getprop > "$LOG_DIR/getprop-full.txt" 2>&1 || true

    local p v has_init_boot kernel
    {
        echo "# generated $ts"
        echo "SERIAL=$(serial)"
        for p in $props; do
            v=$(adb shell getprop "$p" 2>/dev/null | tr -d '\r')
            printf '%s=%s\n' "$(echo "$p" | tr '.' '_' | tr '[:lower:]' '[:upper:]')" "$v"
        done
        kernel=$(adb shell uname -a 2>/dev/null | tr -d '\r')
        echo "KERNEL=$kernel"
        if adb shell ls /dev/block/by-name/init_boot >/dev/null 2>&1 || adb shell ls /dev/block/by-name/init_boot_a >/dev/null 2>&1; then
            has_init_boot=yes
        else
            has_init_boot=unknown
        fi
        echo "HAS_INIT_BOOT=$has_init_boot"
        echo "ROOTED=$(adb shell 'command -v su >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null | tr -d '\r')"
    } > "$PROFILE_ENV"
    profile_keep_extras restore "$extras"

    adb shell ls -la /dev/block/by-name/ > "$LOG_DIR/partitions-by-name.txt" 2>&1 || \
        note "Could not list /dev/block/by-name (needs root on many devices)."

    {
        echo "# Device Profile"
        echo
        echo "Generated by scripts/android-tool.sh discover on $ts."
        echo
        echo "| Key | Value |"
        echo "|-----|-------|"
        sed -n '/^[A-Z_]*=/p' "$PROFILE_ENV" | sed 's/^\([A-Z_]*\)=\(.*\)$/| \1 | \2 |/'
        echo
        echo "Raw dumps: logs/getprop-full.txt, logs/partitions-by-name.txt"
    } > "$PROFILE_MD"

    say "Profile written"
    sed 's/^/    /' "$PROFILE_ENV"
    note ""
    note "Markdown: ${PROFILE_MD#$PROJECT_DIR/}"
    if [ "$(profile_get RO_BOOT_FLASH_LOCKED)" = 1 ]; then
        note "Bootloader is LOCKED. Next: $0 unlock"
    elif [ "$(profile_get ROOTED)" = yes ]; then
        note "Bootloader UNLOCKED and device ROOTED. Live partition dump: $0 backup"
    elif [ "$(profile_get RO_BOOT_FLASH_LOCKED)" = 0 ]; then
        note "Bootloader is UNLOCKED. Next: $0 extract-boot <stock-ota.zip> then $0 root"
    fi
    if [ "$has_init_boot" = yes ]; then
        note "Device has an init_boot partition: Magisk must patch init_boot.img, not boot.img."
    fi
}

vendor_unlock_hint() {
    local mfr
    mfr=$(lower "$(profile_get RO_PRODUCT_MANUFACTURER)$(profile_get RO_PRODUCT_BRAND)$(profile_get PRODUCT)")
    case "$mfr" in
        *oppo*|*oneplus*|*realme*)
            warn "OPPO / OnePlus / realme: 'fastboot flashing unlock' works once 'OEM unlocking' is ON in Developer options (verified on OnePlus 13 PJZ110 C.88, no Deep Testing app needed). Some Chinese-market ColorOS builds additionally require approval through the Deep Testing app; 'get_unlock_ability' reports 0 until then. OnePlus fastboot is often invisible over USB 3: use a USB 2.0 cable/hub." ;;
        *xiaomi*|*redmi*|*poco*)
            warn "Xiaomi: unlocking requires the Mi Unlock tool (Windows) and a waiting period bound to your Mi account. fastboot alone will not unlock." ;;
        *samsung*)
            warn "Samsung: no fastboot. Unlock is done in Download Mode (Odin/Heimdall); US carrier models cannot be unlocked." ;;
        *huawei*|*honor*)
            warn "Huawei/Honor: official unlock codes are no longer issued." ;;
        *) ;;
    esac
}

unlock_preflight() {
    # Pre-unlock readiness check. Runs over adb when the phone is still in
    # Android; skipped (with a note) when it is already in fastboot, where
    # get_unlock_ability is the authoritative answer anyway.
    say "Unlock pre-flight"
    case "$(device_state)" in
        fastboot) note "Device already in fastboot; skipping the adb-side checks (get_unlock_ability decides)."; return ;;
        device) ;;
        unauthorized) die "Device is attached but unauthorized. Accept the USB debugging prompt on the phone." ;;
        none) die "No device found over adb. Enable USB debugging and check the cable, or boot the phone into fastboot by hand." ;;
        multiple) die "More than one device attached. Connect only the target device." ;;
        *) die "Device is in '$(device_state)' mode; cannot run the pre-flight." ;;
    esac

    local dev usb oem
    dev=$(adb shell settings get global development_settings_enabled 2>/dev/null | tr -d '\r')
    usb=$(adb shell settings get global adb_enabled 2>/dev/null | tr -d '\r')
    oem=$(adb shell getprop sys.oem_unlock_allowed 2>/dev/null | tr -d '\r')
    note "Developer options enabled : ${dev:-unknown}"
    note "USB debugging enabled     : ${usb:-unknown}"
    note "sys.oem_unlock_allowed    : ${oem:-not exposed on this device}"
    [ "$dev" = 1 ] || die "Developer options are not enabled. Settings > About > tap Build number 7x, then Developer options > OEM unlocking ON."
    [ "$usb" = 1 ] || die "USB debugging is off; the tool needs adb to reboot into fastboot and to verify the result."
    case "$oem" in
        0) die "sys.oem_unlock_allowed=0: 'OEM unlocking' is OFF in Developer options. Turn it on and rerun." ;;
        1) note "OEM unlocking is ON (confirmed by sys.oem_unlock_allowed)." ;;
        *) note "This device does not report the OEM-unlocking toggle to adb (OnePlus/OPPO keep it in the persistent data block)."
           note "Open Settings > System > Developer options and confirm 'OEM unlocking' is ON now." ;;
    esac
    note "Checklist before the reboot:"
    note "  - 'OEM unlocking' toggle is ON in Developer options."
    note "  - Phone is on a USB 2.0 cable/hub (OnePlus fastboot is invisible over USB 3 on many Macs)."
    note "  - Everything you need from the phone is backed up: the unlock wipes userdata."
    confirm_state_change "I have confirmed the three items above."
}

cmd_unlock() {
    need_cmd fastboot "Run: $0 env"
    profile_require
    say "Bootloader unlock"
    vendor_unlock_hint
    note "Unlocking performs a factory reset. Back up the phone first."
    unlock_preflight
    require_fastboot

    local s unlocked ability
    if [ "$DRY_RUN" = 1 ] && [ "$(device_state)" != fastboot ]; then
        note "(dry-run) device is not in fastboot, so getvar reads are skipped. Would run:"
        note "  $ fastboot getvar unlocked            (stop if yes)"
        note "  $ fastboot flashing get_unlock_ability (must be 1)"
        note "  $ fastboot flashing unlock             (serial-gated; falls back to 'fastboot oem unlock')"
        return
    fi
    s=$(serial)
    unlocked=$(fb_var unlocked)
    say "fastboot reports unlocked=$unlocked"
    [ "$unlocked" = yes ] && { note "Bootloader is already unlocked."; return; }

    ability=$(fastboot flashing get_unlock_ability 2>&1 | tr -d '\r' | grep -i -m1 'unlock_ability\|(bootloader)' || true)
    note "get_unlock_ability: ${ability:-no response}"
    case "$ability" in
        *1*) note "Unlock ability is 1: the bootloader will accept the unlock command." ;;
        *0*) die "Unlock ability is 0: 'OEM unlocking' is OFF or the vendor has not approved this device. Reboot to Android ($0 reboot system), turn the toggle on, and rerun. Forcing the command would fail." ;;
        *)   warn "Could not read get_unlock_ability (${ability:-no response}). The bootloader may not implement it; the unlock command below may still work." ;;
    esac

    confirm_high_risk "fastboot flashing unlock (erases all user data)" "$s"
    if ! run fastboot flashing unlock; then
        warn "'flashing unlock' failed. Some devices use the legacy command instead."
        confirm_high_risk "fastboot oem unlock (erases all user data)" "$s"
        run fastboot oem unlock || die "Unlock refused by the bootloader. See the vendor note above."
    fi
    note "Confirm the unlock prompt on the phone with the volume/power keys if it asks."
    say "Now: fastboot getvar unlocked -> $(fb_var unlocked)"
    note "Record this in docs/bootloader.md, then reboot: $0 reboot system"
}

cmd_extract_boot() {
    local zip=${1:-}
    [ -n "$zip" ] || die "Usage: $0 extract-boot <stock-ota.zip>"
    [ -f "$zip" ] || die "File not found: $zip"
    need_cmd unzip "Install unzip."
    local build dest meta pre_device
    meta=$(unzip -p "$zip" META-INF/com/android/metadata 2>/dev/null || true)
    build=$(printf '%s' "$meta" | awk -F= '$1=="post-build-incremental"{print $2}' | tr -d '\r')
    [ -z "$build" ] && build=$(basename "$zip" .zip)
    pre_device=$(printf '%s' "$meta" | awk -F= '$1=="pre-device"{print $2}' | tr -d '\r')
    check_codename "$pre_device" "firmware zip"
    check_fingerprint "$(printf '%s' "$meta" | awk -F= '$1=="post-build"{print $2}' | tr -d '\r')" "firmware zip"

    dest="$IMAGES_DIR/Original-$build-from-OTA"
    mkdir -p "$dest"
    say "Extracting stock images from $(basename "$zip") into ${dest#$PROJECT_DIR/}"
    printf '%s\n' "$meta" > "$dest/metadata.txt"
    local zip_md5; zip_md5=$(md5 -q "$zip")
    note "MD5: $zip_md5"
    if [ -n "${EXPECTED_OTA_MD5:-}" ] && [ "$zip_md5" != "$EXPECTED_OTA_MD5" ]; then
        die "MD5 does not match EXPECTED_OTA_MD5=$EXPECTED_OTA_MD5. Do not use this file."
    fi

    local parts="boot,init_boot,vendor_boot,dtbo,recovery,vbmeta,vbmeta_system,vbmeta_vendor"
    if unzip -l "$zip" | grep -q ' payload.bin$'; then
        need_cmd payload-dumper-go "This OTA uses payload.bin. Install payload-dumper-go (Homebrew or GitHub releases) and retry."
        run unzip -o -j "$zip" payload.bin -d "$dest"
        run payload-dumper-go -partitions "$parts" -output "$dest" "$dest/payload.bin"
        rm -f "$dest/payload.bin"
    else
        run unzip -o -j "$zip" $(echo "$parts" | tr ',' '\n' | sed 's/$/.img/') -d "$dest" || true
    fi
    # Name every image Original-<partition>.img
    local f
    for f in "$dest"/*.img; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in Original-*) ;; *) mv "$f" "$dest/Original-$(basename "$f")" ;; esac
    done
    [ "$DRY_RUN" = 1 ] || (cd "$dest" && shasum -a 256 Original-*.img > SHA256SUMS 2>/dev/null || true)
    {
        echo "Stock images extracted $(date '+%Y-%m-%d %H:%M') from $(basename "$zip") (MD5 $zip_md5)."
        echo "Build: $build. Verify: shasum -a 256 -c SHA256SUMS"
        echo "Restore: fastboot flash <partition> Original-<partition>.img  (flashes the active slot)"
    } > "$dest/README.txt"

    say "Extracted:"
    ls -la "$dest" | sed 's/^/    /'
    if [ -f "$dest/Original-init_boot.img" ]; then
        note "Original-init_boot.img present: patch THIS with Magisk."
    elif [ -f "$dest/Original-boot.img" ]; then
        note "No init_boot: patch Original-boot.img with Magisk."
    elif [ "$DRY_RUN" = 1 ]; then
        note "(dry-run) nothing extracted."
    else
        die "No boot image found in this OTA. It may be an incremental update; use a full OTA."
    fi
    printf 'STOCK_BUILD=%s\nSTOCK_DIR=%s\nLAST_BACKUP=%s\n' "$build" "${dest#$PROJECT_DIR/}" "${dest#$PROJECT_DIR/}" >> "$PROFILE_ENV"
}

check_codename() {
    # $1 codename from zip, $2 description
    local want=${1:-} have
    have=$(profile_get RO_PRODUCT_DEVICE)
    [ -z "$want" ] && { note "No pre-device field in $2 metadata; cannot verify target device."; return; }
    [ -z "$have" ] && { note "No device profile; cannot verify $2 targets this device."; return; }
    if [ "$(lower "$want")" != "$(lower "$have")" ]; then
        warn "$2 targets '$want' but the connected device is '$have'."
        [ "${ALLOW_DEVICE_MISMATCH:-0}" = 1 ] || die "Refusing to continue. Set ALLOW_DEVICE_MISMATCH=1 only if you are certain."
    else
        note "$2 targets '$want' (matches device profile)."
    fi
}

check_fingerprint() {
    # $1 post-build from zip metadata, $2 description. Full-fingerprint match
    # proves the OTA is for this device on exactly the installed build.
    local want=${1:-} have
    have=$(profile_get RO_BUILD_FINGERPRINT)
    [ -z "$want" ] && { note "No post-build field in $2 metadata; cannot verify build."; return; }
    [ -z "$have" ] && { note "No fingerprint in device profile; run discover to enable the build check."; return; }
    if [ "$want" != "$have" ]; then
        warn "$2 is built for:   $want"
        warn "but the phone runs: $have"
        [ "${ALLOW_DEVICE_MISMATCH:-0}" = 1 ] || die "Build mismatch. Images from this zip must not be flashed to this phone."
    else
        note "$2 post-build matches the installed fingerprint exactly."
    fi
}

latest_stock_dir() {
    local d
    d=$(profile_path STOCK_DIR)
    [ -n "$d" ] && [ -d "$d" ] && { echo "$d"; return; }
    ls -td "$IMAGES_DIR"/Original-*-from-OTA/ 2>/dev/null | head -n1 | sed 's:/$::'
}

# Return the stock image path for a partition inside a stock dir (Original- prefix or plain).
stock_img() { # $1 dir, $2 partition
    if [ -f "$1/Original-$2.img" ]; then echo "$1/Original-$2.img"; elif [ -f "$1/$2.img" ]; then echo "$1/$2.img"; fi
}

cmd_root() {
    need_cmd adb "Run: $0 env"; need_cmd fastboot "Run: $0 env"
    profile_require
    local stock part img patched s
    stock=$(latest_stock_dir)
    if [ -z "$stock" ]; then
        # No OTA extracted: fall back to the device's own dumped active-slot image.
        local bk slot
        bk=$(profile_path LAST_BACKUP); slot=$(profile_get RO_BOOT_SLOT_SUFFIX)
        if [ -n "$bk" ] && [ -f "$bk/Original-init_boot$slot.img" ]; then
            stock="$STOCK_DIR/from-device-$(basename "$bk")"; mkdir -p "$stock"
            cp "$bk/Original-init_boot$slot.img" "$stock/init_boot.img"
            cp "$bk/Original-boot$slot.img" "$stock/boot.img" 2>/dev/null || true
            note "Using the phone's own dumped init_boot$slot as the stock image (${stock#$PROJECT_DIR/})."
        fi
    fi
    [ -n "$stock" ] || die "No stock images. Run: $0 extract-boot <full-stock-ota.zip>"

    if [ -n "$(stock_img "$stock" init_boot)" ]; then part=init_boot; else part=boot; fi
    img=$(stock_img "$stock" "$part")
    [ -n "$img" ] || die "No stock $part image in $stock"
    if [ -z "$(profile_path LAST_BACKUP)" ] || [ ! -d "$(profile_path LAST_BACKUP)" ]; then
        die "No partition backup recorded. Run: $0 backup   (required before any flash)"
    fi

    say "Rooting with Magisk (partition: $part, stock image: ${img#$PROJECT_DIR/})"
    if [ "$(profile_get RO_BUILD_VERSION_INCREMENTAL)" != "" ] && [ "$(profile_get STOCK_BUILD)" != "" ] && \
       [ "$(profile_get RO_BUILD_VERSION_INCREMENTAL)" != "$(basename "$stock")" ]; then
        warn "Installed build '$(profile_get RO_BUILD_VERSION_INCREMENTAL)' differs from extracted stock build '$(basename "$stock")'. Flashing a mismatched image will not boot."
        confirm_state_change "Continue anyway"
    fi
    [ "$(profile_get RO_BOOT_FLASH_LOCKED)" = 0 ] || warn "Profile says the bootloader is locked. Rooting will fail until it is unlocked."

    require_adb
    say "Step 1: push the stock $part image to the phone"
    run adb push "$img" "/sdcard/Download/$part.img"
    cat <<MSG

    Step 2: on the phone, install the Magisk app (from github.com/topjohnwu/Magisk),
            open it, tap Install > Select and Patch a File, choose
            Download/$part.img, and let it finish. It writes
            Download/magisk_patched-*.img.

MSG
    [ "$DRY_RUN" = 1 ] || { printf '    Press Enter when the patched image exists... '; read -r _ || die "stdin closed."; }

    say "Step 3: pull the patched image"
    patched=$(adb shell 'ls -t /sdcard/Download/magisk_patched-*.img 2>/dev/null | head -n1' | tr -d '\r')
    [ -n "$patched" ] || [ "$DRY_RUN" = 1 ] || die "No magisk_patched-*.img found in Download/."
    local local_patched="$PATCHED_DIR/$(basename "$stock")-$part-magisk.img"
    run adb pull "$patched" "$local_patched"
    note "Saved ${local_patched#$PROJECT_DIR/}"

    require_fastboot
    s=$(serial)
    if [ "$part" = boot ]; then
        say "Step 4: temporary boot test (nothing is written)"
        confirm_state_change "fastboot boot the patched image once. If the phone hangs, hold Power to reboot to stock."
        run fastboot boot "$local_patched"
        note "If Android boots and the Magisk app shows 'Installed', come back to fastboot and run '$0 root' again to flash permanently, or flash now:"
        note "  fastboot flash boot ${local_patched#$PROJECT_DIR/}"
        return
    fi

    say "Step 4: flash patched $part (init_boot cannot be temp-booted)"
    note "Rollback: $0 restore $part   (flashes ${img#$PROJECT_DIR/})"
    confirm_high_risk "fastboot flash $part $(basename "$local_patched")" "$s"
    run fastboot flash "$part" "$local_patched"
    confirm_state_change "Reboot to Android"
    run fastboot reboot
    note "Verify with: adb shell su -c id"
}

cmd_recovery() {
    local mode=${1:-} img=${2:-} s
    [ -n "$mode" ] && [ -n "$img" ] || die "Usage: $0 recovery boot|flash <recovery.img>"
    [ -f "$img" ] || die "File not found: $img"
    need_cmd fastboot "Run: $0 env"
    require_fastboot
    s=$(serial)
    case "$mode" in
        boot)
            confirm_state_change "fastboot boot $(basename "$img") (temporary, not written)"
            run fastboot boot "$img" ;;
        flash)
            warn "A/B devices without a dedicated recovery partition cannot take this; follow the ROM's own instructions (often 'fastboot flash boot' or a temp boot + install)."
            confirm_high_risk "fastboot flash recovery $(basename "$img")" "$s"
            run fastboot flash recovery "$img" ;;
        *) die "Unknown mode '$mode'. Use boot or flash." ;;
    esac
}

cmd_rom() {
    local zip=${1:-} s meta pre_device
    [ -n "$zip" ] || die "Usage: $0 rom <custom-rom.zip>"
    [ -f "$zip" ] || die "File not found: $zip"
    profile_require
    say "Custom ROM install: $(basename "$zip")"
    note "MD5: $(md5 -q "$zip")  (compare with the ROM's published checksum)"
    meta=$(unzip -p "$zip" META-INF/com/android/metadata 2>/dev/null || true)
    pre_device=$(printf '%s' "$meta" | awk -F= '$1=="pre-device"{print $2}' | tr -d '\r')
    check_codename "$pre_device" "ROM zip"
    [ -n "$meta" ] && printf '%s\n' "$meta" | sed 's/^/    /'
    [ "$(profile_get RO_BOOT_FLASH_LOCKED)" = 0 ] || warn "Profile says the bootloader is locked. Custom ROM install will fail until it is unlocked."
    need_cmd adb "Run: $0 env"

    case "$(device_state)" in
        sideload) ;;
        device)
            confirm_state_change "Reboot into recovery. Boot a custom recovery first if the stock one cannot sideload this ROM."
            run adb reboot recovery
            note "On the phone choose 'Apply update from ADB' (stock) or Advanced > ADB sideload (TWRP/Lineage)."
            wait_for sideload ;;
        recovery)
            note "On the phone choose 'Apply update from ADB' or Advanced > ADB sideload."
            wait_for sideload ;;
        *) die "Device must be in recovery/sideload mode (state: $(device_state))." ;;
    esac

    s=$(serial)
    confirm_high_risk "adb sideload $(basename "$zip") — replaces the OS; a factory reset is usually required afterwards" "$s"
    run adb sideload "$zip"
    note "Sideload exit codes around 47% / 'Total xfer: 1.00x' are normal for many recoveries."
    note "Next: factory reset from recovery if switching ROMs, then reboot system."
}

cmd_restore() {
    local part=${1:-} stock img s
    [ -n "$part" ] || die "Usage: $0 restore <boot|init_boot|vbmeta|recovery|dtbo>"
    need_cmd fastboot "Run: $0 env"
    stock=$(latest_stock_dir)
    [ -n "$stock" ] || die "No extracted stock images. Run: $0 extract-boot <stock-ota.zip>"
    img=$(stock_img "$stock" "$part")
    [ -n "$img" ] || die "No stock image for '$part' in ${stock#$PROJECT_DIR/}"
    require_fastboot
    s=$(serial)
    say "Restore stock $part from ${img#$PROJECT_DIR/}"
    confirm_high_risk "fastboot flash $part $part.img (stock, build $(basename "$stock"))" "$s"
    run fastboot flash "$part" "$img"
    confirm_state_change "Reboot to Android"
    run fastboot reboot
}

BACKUP_PARTS="init_boot_a init_boot_b boot_a boot_b vendor_boot_a vendor_boot_b dtbo_a dtbo_b recovery_a recovery_b vbmeta_a vbmeta_b vbmeta_system_a vbmeta_system_b vbmeta_vendor_a vbmeta_vendor_b"

latest_recovery_img() {
    ls -t "$IMAGES_DIR"/*/recovery.img 2>/dev/null | head -n1
}

# GPT head (first 1 MiB: protective MBR, header, entries) and tail (last 1 MiB: backup entries + header) of every
# UFS LUN, so a damaged partition table can be put back with dd. Needed by omarchy-install-slot-b.sh preflight.
dump_gpt() { # $1 = root shell prefix, $2 = destination dir
    local pre=$1 dest=$2/gpt lun size
    mkdir -p "$dest"
    for lun in $(adb shell "$pre 'ls /dev/block/ | grep -E \"^sd[a-z]\$\"'" 2>/dev/null | tr -d '\r'); do
        size=$(adb shell "$pre 'blockdev --getsize64 /dev/block/$lun'" 2>/dev/null | tr -d '\r')
        case "$size" in ''|*[!0-9]*) continue ;; esac
        if [ "$DRY_RUN" = 1 ]; then note "(dry-run) would dump GPT head/tail of $lun ($size bytes)"; continue; fi
        adb exec-out "$pre 'dd if=/dev/block/$lun bs=1048576 count=1 2>/dev/null'" > "$dest/$lun-head.bin"
        adb exec-out "$pre 'dd if=/dev/block/$lun bs=1048576 skip=$(( size / 1048576 - 1 )) count=1 2>/dev/null'" > "$dest/$lun-tail.bin"
        note "ok     gpt/$lun-head.bin + $lun-tail.bin  (LUN $size bytes)"
    done
    adb shell "$pre 'ls -la /dev/block/by-name/'" 2>/dev/null | tr -d '\r' > "$dest/by-name.txt"
    [ "$DRY_RUN" = 1 ] || (cd "$dest" && shasum -a 256 ./*.bin > SHA256SUMS 2>/dev/null || true)
}

dump_partitions() {
    # $1 = shell prefix for root ("" in recovery, "su -c" on a rooted system)
    local pre=$1 ts dest p size got failed=0 build
    ts=$(date +%Y%m%d-%H%M%S)
    build=$(profile_get RO_BUILD_DISPLAY_ID | tr -d '()' | tr ' /' '__')
    dest="$IMAGES_DIR/Original-${build:-unknown}-$ts"; mkdir -p "$dest"
    say "Dumping partitions to ${dest#$PROJECT_DIR/}"
    for p in $BACKUP_PARTS; do
        if [ -n "$pre" ]; then
            size=$(adb shell "$pre 'blockdev --getsize64 /dev/block/by-name/$p'" 2>/dev/null | tr -d '\r')
        else
            size=$(adb shell "blockdev --getsize64 /dev/block/by-name/$p" 2>/dev/null | tr -d '\r')
        fi
        case "$size" in ''|*[!0-9]*) note "skip   $p (not present)"; continue ;; esac
        if [ "$DRY_RUN" = 1 ]; then note "(dry-run) would dump $p ($size bytes)"; continue; fi
        if [ -n "$pre" ]; then
            adb exec-out "$pre 'dd if=/dev/block/by-name/$p bs=1048576 2>/dev/null'" > "$dest/Original-$p.img"
        else
            adb exec-out "dd if=/dev/block/by-name/$p bs=1048576 2>/dev/null" > "$dest/Original-$p.img"
        fi
        got=$(wc -c < "$dest/Original-$p.img" | tr -d ' ')
        if [ "$got" = "$size" ]; then
            if [ "$p" = "init_boot$(profile_get RO_BOOT_SLOT_SUFFIX)" ] && [ "$(profile_get ROOTED)" = yes ]; then
                mv "$dest/Original-$p.img" "$dest/Magisk-$p.img"
                note "ok     Magisk-$p.img  $size bytes  (active slot, contains the patched image, NOT stock)"
            else
                note "ok     Original-$p.img  $size bytes"
            fi
        else
            warn "$p: got $got bytes, expected $size. Dump is incomplete."
            mv "$dest/Original-$p.img" "$dest/Original-$p.img.INCOMPLETE"; failed=1
        fi
    done
    say "GPT of every LUN"
    dump_gpt "$pre" "$dest"
    [ "$DRY_RUN" = 1 ] && return 0
    (cd "$dest" && shasum -a 256 ./*.img > SHA256SUMS 2>/dev/null || true)
    [ -f "$PROFILE_ENV" ] && cp "$PROFILE_ENV" "$dest/device-profile.env"
    {
        echo "Stock partition dump taken $ts from serial $(profile_get SERIAL), build $(profile_get RO_BUILD_DISPLAY_ID)."
        echo "Active slot at dump time: $(profile_get RO_BOOT_SLOT_SUFFIX). Verify with: shasum -a 256 -c SHA256SUMS"
        echo "Restore one partition: fastboot flash <name> Original-<name>.img   (e.g. fastboot flash init_boot_a Original-init_boot_a.img)"
    } > "$dest/README.txt"
    say "Backup complete: ${dest#$PROJECT_DIR/}"
    ls -la "$dest" | sed 's/^/    /'
    [ "$failed" = 1 ] && die "One or more dumps were incomplete. Do not rely on this backup."
    printf 'LAST_BACKUP=%s\n' "${dest#$PROJECT_DIR/}" >> "$PROFILE_ENV"
    return 0
}

cmd_backup() {
    # backup [recovery.img]  — dumps every boot-chain partition on both slots.
    # Works from a rooted system, from a booted recovery, or by temporarily
    # booting a recovery image (fastboot boot writes nothing to the phone).
    local img=${1:-} state
    need_cmd adb "Run: $0 env"
    profile_require
    state=$(device_state)
    if [ "$img" = gpt ]; then
        local bk; bk=$(profile_path LAST_BACKUP)
        [ -n "$bk" ] && [ -d "$bk" ] || die "no LAST_BACKUP dump to add the GPT to; run: $0 backup"
        [ "$state" = device ] && adb shell 'su -c id' 2>/dev/null | grep -q 'uid=0' || die "needs a rooted Android (su)"
        say "Dumping GPT head/tail of every LUN into ${bk#$PROJECT_DIR/}/gpt"
        dump_gpt "su -c" "$bk"; return
    fi
    case "$state" in
        device)
            if adb shell 'command -v su' >/dev/null 2>&1 && adb shell 'su -c id' 2>/dev/null | grep -q 'uid=0'; then
                say "Device is rooted; dumping via su"
                dump_partitions "su -c"; return
            fi
            note "Device is not rooted: partitions are unreadable from the normal shell."
            ;;
        recovery)
            say "Device is in recovery; dumping via its root shell"
            if ! adb shell id 2>/dev/null | grep -q 'uid=0'; then
                die "Recovery adb shell is not root. In LineageOS recovery choose Advanced > Enable ADB, then rerun."
            fi
            dump_partitions ""; return
            ;;
    esac

    [ -n "$img" ] || img=$(latest_recovery_img)
    [ -n "$img" ] && [ -f "$img" ] || die "No recovery image. Put one in firmware/images/<name>/recovery.img (LineageOS for 'dodge' is verified) or pass its path."
    need_cmd fastboot "Run: $0 env"
    say "Temporarily booting ${img#$PROJECT_DIR/} to get a root shell"
    note "fastboot boot loads the image into RAM only; no partition is written."
    require_fastboot
    confirm_state_change "fastboot boot $(basename "$img") (temporary). If the phone hangs on the logo, hold Power for 10s; it returns to stock untouched."
    run fastboot boot "$img"
    note "When the recovery menu appears: Advanced > Enable ADB (LineageOS recovery)."
    wait_for recovery
    [ "$DRY_RUN" = 1 ] || adb shell id 2>/dev/null | grep -q 'uid=0' || die "Recovery shell is not root; cannot dump."
    dump_partitions ""
    confirm_state_change "Reboot back to Android"
    run adb reboot
}

cmd_reboot() {
    local target=${1:-}
    case "$target" in
        system)     confirm_state_change "Reboot to Android"
                    if [ "$(device_state)" = fastboot ]; then run fastboot reboot; else run adb reboot; fi ;;
        bootloader) confirm_state_change "Reboot to fastboot"
                    if [ "$(device_state)" = fastboot ]; then run fastboot reboot bootloader; else run adb reboot bootloader; fi ;;
        recovery)   confirm_state_change "Reboot to recovery"; run adb reboot recovery ;;
        fastbootd)  confirm_state_change "Reboot to fastbootd (userspace fastboot; pick English on the phone, then 'fastboot devices' must list it)"
                    if [ "$(device_state)" = fastboot ]; then run fastboot reboot fastboot; else run adb reboot fastboot; fi ;;
        sideload)   confirm_state_change "Reboot to sideload (custom recoveries only)"; run adb reboot sideload ;;
        *) die "Usage: $0 reboot <system|bootloader|fastbootd|recovery|sideload>" ;;
    esac
}

# ---------------------------------------------------------------- dispatch ---

[ "${1:-}" = "--dry-run" ] && { DRY_RUN=1; shift; }
cmd=${1:-help}; shift || true
note "log: ${LOG_FILE#$PROJECT_DIR/}"
case "$cmd" in help|-h|--help) ;; *) ensure_platform_tools ;; esac
case "$cmd" in
    env)          cmd_env ;;
    discover)     cmd_discover ;;
    unlock)       cmd_unlock ;;
    extract-boot) cmd_extract_boot "$@" ;;
    root)         cmd_root ;;
    recovery)     cmd_recovery "$@" ;;
    rom)          cmd_rom "$@" ;;
    restore)      cmd_restore "$@" ;;
    backup)       cmd_backup "$@" ;;
    reboot)       cmd_reboot "$@" ;;
    help|-h|--help) awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0" ;;
    *) die "Unknown command '$cmd'. Run: $0 help" ;;
esac
