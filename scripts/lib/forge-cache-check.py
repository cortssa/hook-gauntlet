"""forge-cache-check.py - compare sources with the content forge recorded for them (used by assert-fresh-build.sh).

Usage:  python3 forge-cache-check.py <cache-file> <source> [<source> ...]      (paths relative to the project root)
        python3 forge-cache-check.py --hash <file> [<file> ...]               (prints "<hash> <file>" - of the text as forge
                                                                               hashes it, CR LF folded - for checking)

forge (foundry-compilers, as shipped with forge 1.8.1) writes, per source, `contentHash`: XXH3-64 (seed 0, default
secret), as 16 lowercase hex digits, of the file's text with every CR LF replaced by LF - one left-to-right pass, and
nothing else. Measured against its own cache on eight fixtures (2026-09-23): CRLF and CRLF with no last newline hash as
their LF text; a lone CR is kept (a file whose lines end in CR alone hashes as its raw bytes); CR CR LF becomes CR LF, not
LF; the last newline is neither added nor stripped. A UTF-8 byte-order mark never gets that far: solc refuses the file.
It recompiles a source when that hash changes, not when its mtime does. This file re-implements XXH3-64 (Python has none
built in, and the kit installs nothing) and was checked against forge's own cache on 34 files of every size class of the
hash (0 to 5000 bytes) and on the kit's own builds. Hashing the raw bytes, as it first did, called a CRLF checkout STALE
on a fresh build.

Prints one TAB-separated line per source: `SAME <path> <evidence>`, `CHANGED <path> <evidence> <hash on disk> <hash in
the cache>`, or `ABSENT <path> <evidence>` (not in the cache). The evidence is the file's mtime and the one the build
recorded - printed, never decided on. Exit 0 read, 3 the cache could not be read or has no contentHash (another forge's
shape): nothing may be decided from it.
"""
import json
import os
import sys

M = (1 << 64) - 1
P32_1, P32_2, P32_3 = 0x9E3779B1, 0x85EBCA77, 0xC2B2AE3D
P64_1, P64_2, P64_3, P64_4, P64_5 = (0x9E3779B185EBCA87, 0xC2B2AE3D27D4EB4F, 0x165667B19E3779F9,
                                     0x85EBCA77C2B2AE63, 0x27D4EB2F165667C5)
MX1, MX2 = 0x165667919E3779F9, 0x9FB21C651E98DF25
SECRET = bytes.fromhex(
    "b8fe6c3923a44bbe7c01812cf721ad1cded46de9839097db7240a4a4b7b3671f"
    "cb79e64eccc0e578825ad07dccff7221b8084674f743248ee03590e6813a264c"
    "3c2852bb91c300cb88d0658b1b532ea371644897a20df94e3819ef46a9deacd8"
    "a8fa763fe39c343ff9dcbbc7c70b4f1d8a51e04bcdb45931c89f7ec9d9787364"
    "eac5ac8334d3ebc3c581a0fffa1363eb170ddd51b7f0da49d316552629d4689e"
    "2b16be587d47a1fc8ff8b8d17ad031ce45cb3a8f95160428afd7fbcabb4b407e")


def _r64(b, o):
    return int.from_bytes(b[o:o + 8], "little")


def _r32(b, o):
    return int.from_bytes(b[o:o + 4], "little")


def _rotl(x, r):
    return ((x << r) | (x >> (64 - r))) & M


def _fold(a, b):
    p = a * b
    return (p & M) ^ (p >> 64)


def _avalanche(h):
    h ^= h >> 37
    h = (h * MX1) & M
    return h ^ (h >> 32)


def _avalanche64(h):
    h ^= h >> 33
    h = (h * P64_2) & M
    h ^= h >> 29
    h = (h * P64_3) & M
    return h ^ (h >> 32)


def _mix16(d, o, so):
    return _fold(_r64(d, o) ^ _r64(SECRET, so), _r64(d, o + 8) ^ _r64(SECRET, so + 8))


def xxh3_64(d):
    n = len(d)
    if n == 0:
        return _avalanche64(_r64(SECRET, 56) ^ _r64(SECRET, 64))
    if n <= 3:
        c = (d[0] << 16) | (d[n >> 1] << 24) | d[n - 1] | (n << 8)
        return _avalanche64(c ^ (_r32(SECRET, 0) ^ _r32(SECRET, 4)))
    if n <= 8:
        k = ((_r32(d, n - 4) + (_r32(d, 0) << 32)) & M) ^ (_r64(SECRET, 8) ^ _r64(SECRET, 16))
        k ^= _rotl(k, 49) ^ _rotl(k, 24)
        k = (k * MX2) & M
        k ^= (k >> 35) + n
        k = (k * MX2) & M
        return k ^ (k >> 28)
    if n <= 16:
        lo = _r64(d, 0) ^ (_r64(SECRET, 24) ^ _r64(SECRET, 32))
        hi = _r64(d, n - 8) ^ (_r64(SECRET, 40) ^ _r64(SECRET, 48))
        swapped = int.from_bytes(lo.to_bytes(8, "little"), "big")
        return _avalanche((n + swapped + hi + _fold(lo, hi)) & M)
    if n <= 128:
        a = n * P64_1
        if n > 32:
            if n > 64:
                if n > 96:
                    a += _mix16(d, 48, 96) + _mix16(d, n - 64, 112)
                a += _mix16(d, 32, 64) + _mix16(d, n - 48, 80)
            a += _mix16(d, 16, 32) + _mix16(d, n - 32, 48)
        a += _mix16(d, 0, 0) + _mix16(d, n - 16, 16)
        return _avalanche(a & M)
    if n <= 240:
        a = n * P64_1
        for i in range(8):
            a += _mix16(d, 16 * i, 16 * i)
        a = _avalanche(a & M)
        for i in range(8, n // 16):
            a += _mix16(d, 16 * i, 16 * (i - 8) + 3)
        a += _mix16(d, n - 16, 136 - 17)
        return _avalanche(a & M)
    acc = [P32_3, P64_1, P64_2, P64_3, P64_4, P32_2, P64_5, P32_1]

    def stripe(o, so):
        for i in range(8):
            v = _r64(d, o + 8 * i)
            k = v ^ _r64(SECRET, so + 8 * i)
            acc[i ^ 1] = (acc[i ^ 1] + v) & M
            acc[i] = (acc[i] + (k & 0xFFFFFFFF) * (k >> 32)) & M

    def scramble():
        for i in range(8):
            a = acc[i]
            a ^= a >> 47
            a ^= _r64(SECRET, 128 + 8 * i)
            acc[i] = (a * P32_1) & M

    per_block = (192 - 64) // 8
    block_len = 64 * per_block
    blocks = (n - 1) // block_len
    for b in range(blocks):
        for s in range(per_block):
            stripe(b * block_len + 64 * s, 8 * s)
        scramble()
    for s in range(((n - 1) - block_len * blocks) // 64):
        stripe(blocks * block_len + 64 * s, 8 * s)
    stripe(n - 64, 192 - 64 - 7)
    r = n * P64_1
    for i in range(4):
        r += _fold(acc[2 * i] ^ _r64(SECRET, 11 + 16 * i), acc[2 * i + 1] ^ _r64(SECRET, 11 + 16 * i + 8))
    return _avalanche(r & M)


def content_hash(path):
    # forge's normalisation, exactly: CR LF -> LF in one pass (bytes.replace is left to right, non-overlapping, as
    # forge's is), a lone CR untouched. Dropping every CR, or turning a lone CR into LF, disagrees with forge.
    with open(path, "rb") as f:
        return "%016x" % xxh3_64(f.read().replace(b"\r\n", b"\n"))


def main(argv):
    try:
        sys.stdout.reconfigure(newline="\n")  # a Windows interpreter would otherwise end every line with CR LF
    except AttributeError:
        pass
    if len(argv) >= 2 and argv[1] == "--hash":
        for p in argv[2:]:
            print(content_hash(p), p)
        return 0
    if len(argv) < 2:
        print("usage: forge-cache-check.py <cache-file> <source>...", file=sys.stderr)
        return 3
    try:
        with open(argv[1], "rb") as f:
            files = json.load(f)["files"]
        recorded = {k: v["contentHash"] for k, v in files.items()}
        dates = {k: v.get("lastModificationDate") for k, v in files.items()}
        if not recorded:
            raise KeyError("no files")
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        print("UNREADABLE\t%s\t%s" % (argv[1], e.__class__.__name__))
        return 3
    root = os.getcwd()
    for p in argv[2:]:
        absolute = os.path.join(root, p)
        key = p if p in recorded else absolute if absolute in recorded else None
        evidence = "mtime on disk %d ms" % int(os.stat(p).st_mtime * 1000)
        if key is None:
            print("ABSENT\t%s\t%s" % (p, evidence))
            continue
        evidence += ", recorded by the build %s ms" % dates.get(key)
        h = content_hash(p)
        if h == recorded[key]:
            print("SAME\t%s\t%s" % (p, evidence))
        else:
            print("CHANGED\t%s\t%s\t%s\t%s" % (p, evidence, h, recorded[key]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
