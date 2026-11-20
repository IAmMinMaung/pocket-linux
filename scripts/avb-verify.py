#!/usr/bin/env python3
"""Check boot-chain images against the hash descriptors in a vbmeta image (stdlib only).

    python3 scripts/avb-verify.py <vbmeta.img> <image.img> [<image.img> ...]

Each image's partition name is taken from its file name (Original-init_boot_b.img -> init_boot).
For a HASH descriptor the digest of salt+image[:image_size] must match. For a CHAIN descriptor
(boot on this OnePlus 13) the image carries its own AVB footer and vbmeta; this script then checks
that footer's hash descriptor and reports the public key the chain expects (it cannot verify the
RSA signature). Exit code 0 means every given image matched; 1 means at least one did not.
Replaces the deleted tools/avb/check-stock-avb.py; no avbtool needed.
"""
import hashlib, os, re, struct, sys

MAGIC = b"AVB0"

def parse_vbmeta(buf):
    if buf[:4] != MAGIC:
        raise ValueError("not an AVB vbmeta blob")
    # AvbVBMetaImageHeader (256 bytes), libavb avb_vbmeta_image.h
    auth_sz, aux_sz = struct.unpack(">QQ", buf[0x0C:0x1C])
    pub_off, pub_sz = struct.unpack(">QQ", buf[0x40:0x50])
    desc_off, desc_sz = struct.unpack(">QQ", buf[0x60:0x70])
    aux_start = 256 + auth_sz
    pubkey = buf[aux_start + pub_off: aux_start + pub_off + pub_sz]
    d = buf[aux_start + desc_off: aux_start + desc_off + desc_sz]
    out = {}
    while len(d) >= 16:
        tag, nb = struct.unpack(">QQ", d[:16])
        body, d = d[16:16 + nb], d[16 + nb:]
        if tag == 2:  # hash descriptor
            img_sz, = struct.unpack(">Q", body[:8])
            alg = body[8:40].rstrip(b"\0").decode()
            name_len, salt_len, dig_len = struct.unpack(">III", body[40:52])
            p = 116  # 8 + 32 + 4*4 + 60 reserved
            name = body[p:p + name_len].decode(); p += name_len
            salt = body[p:p + salt_len]; p += salt_len
            digest = body[p:p + dig_len]
            out[name] = ("hash", img_sz, alg, salt, digest)
        elif tag == 4:  # chain partition descriptor
            rb_idx, name_len, key_len = struct.unpack(">III", body[:12])
            name = body[76:76 + name_len].decode()  # 4*4 + 60 reserved
            key = body[76 + name_len:76 + name_len + key_len]
            out[name] = ("chain", rb_idx, hashlib.sha256(key).hexdigest())
    return out, hashlib.sha256(pubkey).hexdigest()

def footer_vbmeta(img):
    tail = img[-64:]
    if tail[:4] != b"AVBf":
        return None
    vb_off, vb_sz = struct.unpack(">QQ", tail[0x14:0x24])  # AvbFooter: magic, 2x u32, orig_size, then offset/size
    return img[vb_off:vb_off + vb_sz]

def check(name, img, desc):
    kind = desc[0]
    if kind == "hash":
        _, img_sz, alg, salt, digest = desc
        h = hashlib.new(alg, salt + img[:img_sz]).hexdigest()
        ok = h == digest.hex()
        return ok, f"{alg} {'match' if ok else 'MISMATCH'} (image_size {img_sz})"
    _, rb_idx, keyhash = desc
    vb = footer_vbmeta(img)
    if vb is None:
        return False, f"chained partition but image has no AVB footer (expects key sha256 {keyhash[:16]}…)"
    inner, inner_key = parse_vbmeta(vb)
    if name not in inner:
        return False, "footer vbmeta has no hash descriptor for itself"
    ok, msg = check(name, img, inner[name])
    keyok = inner_key == keyhash
    return ok and keyok, f"footer {msg}; signing key {'matches chain' if keyok else 'DIFFERS from chain (' + inner_key[:16] + '…)'}"

def main(argv):
    if len(argv) < 3:
        print(__doc__); return 2
    vb = open(argv[1], "rb").read()
    descs, _ = parse_vbmeta(vb)
    rc = 0
    for path in argv[2:]:
        name = re.sub(r"^Original-|\.img$|_[ab]$", "", os.path.basename(path))
        name = re.sub(r"_[ab]$", "", name)
        if name not in descs:
            print(f"{path}: no descriptor for '{name}' in vbmeta (has: {', '.join(sorted(descs))})"); rc = 1; continue
        ok, msg = check(name, open(path, "rb").read(), descs[name])
        print(f"{'ok  ' if ok else 'FAIL'} {path}: {msg}")
        rc |= 0 if ok else 1
    return rc

if __name__ == "__main__":
    sys.exit(main(sys.argv))
