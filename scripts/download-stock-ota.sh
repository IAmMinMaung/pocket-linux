#!/bin/sh
set -eu

# Official full OTA for OnePlus 13 PJZ110, ColorOS 16.0.5.703(CN01) C.88, from
# OPPO's OTA CDN. Downloads only; never flashes. The CDN resets connections
# every few hundred MB, so the file is fetched as 128 MiB byte-range chunks
# into firmware/images/.chunks/, each accepted only when its length is exact.
# Safe to rerun: finished chunks are skipped. Final MD5 must match.
dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out_dir="$dir/firmware/images"
out="$out_dir/PJZ110_16.0.5.703_CN01_C88.zip"
chunks="$out_dir/.chunks"
expected_md5='2cc8031b2589dd4e80bd3c93326c7c7e'
expected_size=8769806346
chunk=$((128 * 1024 * 1024))
max_tries=40
url='https://component-ota-cn.allawntech.com/downloadCheck?c=6ae1589edf7d7740a1f42a85b4a954d0&p=a6c78fdd3751888b39cedbfe149a30629674fce84a6354fe8dbe00ecc720049aefbc31dbee706571eb6fd3282179&d=e181cd82745f88956e8098ec0182623bca30a2a51b7b03ead6e04ce9ca7400d5b4e921c5b4276d&g=10eab6008d5642cf42abd2aa41f847cb&id=69eb51609e207b01827c1fdf&taste=0&supportDLTaste=0&mode=1&tr=manual&s=7af4672db658251c0f05ebba2d4e1ae2'

fetch() { # $1 byte range, $2 output
    curl --fail --silent --show-error --location --connect-timeout 30 \
        --speed-limit 10240 --speed-time 60 --range "$1" \
        --user-agent 'okhttp/3.12.12' \
        --header 'userId: oplus-ota|16002018' \
        --header 'Accept-Encoding: identity' \
        "$url" --output "$2"
}

if [ -f "$out" ] && [ "$(md5 -q "$out")" = "$expected_md5" ]; then
    echo "Already downloaded and verified: $out"; exit 0
fi
mkdir -p "$chunks"

# Confirm the link is alive and the size is what we expect.
total=$(curl --silent --location --range 0-0 --dump-header - --output /dev/null \
    --user-agent 'okhttp/3.12.12' --header 'userId: oplus-ota|16002018' --header 'Accept-Encoding: identity' \
    "$url" | tr -d '\r' | awk 'tolower($1)=="content-range:" {sub(/.*\//,"",$3); print $3; exit}')
[ "$total" = "$expected_size" ] || { echo "Server reports size '${total:-none}', expected $expected_size. Link expired or wrong file." >&2; exit 1; }

n=$(( (total + chunk - 1) / chunk ))
i=0
while [ "$i" -lt "$n" ]; do
    start=$((i * chunk)); end=$((start + chunk - 1))
    [ "$end" -ge "$total" ] && end=$((total - 1))
    want=$((end - start + 1))
    f=$(printf '%s/chunk.%05d' "$chunks" "$i")
    if [ -f "$f" ] && [ "$(wc -c < "$f" | tr -d ' ')" -eq "$want" ]; then i=$((i + 1)); continue; fi
    tries=0
    while :; do
        tries=$((tries + 1))
        if fetch "$start-$end" "$f.tmp" 2>/dev/null && [ "$(wc -c < "$f.tmp" | tr -d ' ')" -eq "$want" ]; then
            mv "$f.tmp" "$f"
            printf '%s chunk %d/%d done (%d MB)\n' "$(date +%H:%M:%S)" "$((i + 1))" "$n" "$(( (end + 1) / 1048576 ))"
            break
        fi
        rm -f "$f.tmp"
        [ "$tries" -ge "$max_tries" ] && { echo "chunk $i failed $tries times; rerun later to continue." >&2; exit 1; }
        sleep 5
    done
    i=$((i + 1))
done

echo "Assembling..."
rm -f "$out.part"; i=0
while [ "$i" -lt "$n" ]; do cat "$(printf '%s/chunk.%05d' "$chunks" "$i")" >> "$out.part"; i=$((i + 1)); done
got=$(md5 -q "$out.part")
if [ "$got" != "$expected_md5" ]; then
    echo "MD5 mismatch: $got (expected $expected_md5). Not accepted; chunks kept in $chunks" >&2; exit 1
fi
mv "$out.part" "$out"; rm -rf "$chunks"
echo "Verified: $out"
unzip -p "$out" META-INF/com/android/metadata | grep -E '^(pre-device|post-build|post-build-incremental)='
