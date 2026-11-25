#!/usr/bin/env python3
"""Raw image <-> Android sparse image, standard library only (no img2simg on macOS).

  python3 -I scripts/img2simg.py pack   <raw.img> <sparse.img>     raw -> sparse
  python3 -I scripts/img2simg.py verify <raw.img> <sparse.img>     expand the sparse image in memory, compare sha256

Why: fastboot on macOS fails to read a raw image of 2 GiB or more ("Failed reading from userdata", before any
"Sending" line). A sparse image stores runs of zero blocks as 16-byte FILL chunks, so the file stays well below
that size and fastboot splits it by max-download-size as usual.

Zero blocks are written as FILL(0), never DONT_CARE: ext4 has zeroed metadata blocks (inode tables, bitmaps,
journal) that must really be zero on a partition that held other data before.
"""
import hashlib
import struct
import sys

BLK = 4096
MAGIC = 0xED26FF3A
RAW, FILL, DONT_CARE = 0xCAC1, 0xCAC2, 0xCAC3
MAX_RAW_BLOCKS = 16384  # 64 MiB per RAW chunk
ZERO = bytes(BLK)


def pack(raw_path, sparse_path):
    with open(raw_path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(0)
        if size % BLK:
            sys.exit(f"{raw_path}: size {size} is not a multiple of {BLK}")
        total_blocks = size // BLK
        chunks = 0
        with open(sparse_path, "wb") as o:
            o.write(bytes(28))  # header, filled in at the end
            pending = []  # raw blocks waiting to be written
            zeros = 0

            def flush_raw():
                nonlocal chunks, pending
                if pending:
                    o.write(struct.pack("<HHII", RAW, 0, len(pending), 12 + len(pending) * BLK))
                    o.write(b"".join(pending))
                    chunks += 1
                    pending = []

            def flush_zeros():
                nonlocal chunks, zeros
                if zeros:
                    o.write(struct.pack("<HHII", FILL, 0, zeros, 16) + bytes(4))
                    chunks += 1
                    zeros = 0

            for _ in range(total_blocks):
                b = f.read(BLK)
                if len(b) != BLK:
                    sys.exit("short read")
                if b == ZERO:
                    flush_raw()
                    zeros += 1
                else:
                    flush_zeros()
                    pending.append(b)
                    if len(pending) == MAX_RAW_BLOCKS:
                        flush_raw()
            flush_raw()
            flush_zeros()
            o.seek(0)
            o.write(struct.pack("<IHHHHIIII", MAGIC, 1, 0, 28, 12, BLK, total_blocks, chunks, 0))
    print(f"packed {total_blocks} blocks into {chunks} chunks: {sparse_path}")


def sparse_sha256(sparse_path):
    h = hashlib.sha256()
    with open(sparse_path, "rb") as f:
        magic, major, _minor, fh, ch, blk, total_blocks, chunks, _crc = struct.unpack("<IHHHHIIII", f.read(28))
        if magic != MAGIC or major != 1 or fh != 28 or ch != 12 or blk != BLK:
            sys.exit(f"{sparse_path}: not a sparse image this tool understands")
        seen = 0
        for _ in range(chunks):
            ctype, _res, nblk, total = struct.unpack("<HHII", f.read(12))
            if ctype == RAW:
                if total != 12 + nblk * BLK:
                    sys.exit("bad RAW chunk size")
                left = nblk * BLK
                while left:
                    d = f.read(min(left, 1 << 22))
                    if not d:
                        sys.exit("truncated RAW chunk")
                    h.update(d)
                    left -= len(d)
            elif ctype == FILL:
                if total != 16:
                    sys.exit("bad FILL chunk size")
                block = f.read(4) * (BLK // 4)
                for _ in range(nblk):
                    h.update(block)
            else:
                sys.exit(f"unexpected chunk type {ctype:#x}")
            seen += nblk
        if seen != total_blocks or f.read(1):
            sys.exit("block count mismatch or trailing data")
    return h.hexdigest(), total_blocks * BLK


def raw_sha256(raw_path):
    h = hashlib.sha256()
    n = 0
    with open(raw_path, "rb") as f:
        while True:
            d = f.read(1 << 22)
            if not d:
                break
            h.update(d)
            n += len(d)
    return h.hexdigest(), n


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("pack", "verify"):
        sys.exit(__doc__)
    cmd, raw, sparse = sys.argv[1:]
    if cmd == "pack":
        pack(raw, sparse)
    a, b = raw_sha256(raw), sparse_sha256(sparse)
    print(f"raw    {a[0]}  {a[1]} bytes\nsparse {b[0]}  {b[1]} bytes (expanded)")
    if a != b:
        sys.exit("MISMATCH: do not flash this sparse image")
    print("ok: the sparse image expands to exactly the raw image")


if __name__ == "__main__":
    main()
