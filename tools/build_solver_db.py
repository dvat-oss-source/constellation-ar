#!/usr/bin/env python3
"""Builds Data/solver_db.bin: a tetra3-style 4-star edge-ratio pattern database from Data/stars.bin.

Pattern selection (cluster-busting separation, Fibonacci lattice fields, breadth-first combinations, multiscale
FOV steps) and the hashed pattern table (binned sorted edge ratios, multiplicative hash, quadratic probing, 16-bit
key check, largest edge) follow tetra3 / Cedar-Solve `generate_database` (Apache-2.0; see NOTICE.md). numpy only.

Binary layout (little-endian):
  header  64 bytes: "SOLV", u32 version=1, u32 numStars, u32 numPatterns, u32 tableLength, u32 patternBins,
          f32 patternMaxError, f32 minFovDeg, f32 maxFovDeg, f32 magLimit, f32 pmEpoch, u32 verificationStars,
          u32 reserved x3
  stars   numStars x 20 bytes: u32 hip, f32 x, y, z (ICRS unit vector), f32 vmag; brightest first
  table   tableLength x 4 x u16  star indices of the pattern, ordered by distance from the pattern centroid
          (an all-zero row is an empty slot)
  keys    tableLength x u16      low 16 bits of the pattern key hash
  edges   tableLength x u16      IEEE half bits of the largest edge in milliradians
"""
import argparse
import itertools
import math
import struct
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
MAGIC = b"SOLV"
VERSION = 1
HEADER_SIZE = 64
STAR_RECORD = 20
PATTERN_SIZE = 4
MAGIC_RAND = 2654435761


def read_stars(path):
    raw = Path(path).read_bytes()
    if raw[:4] != b"SKYS":
        raise ValueError("not a stars.bin")
    _, count, rec = struct.unpack_from("<III", raw, 4)
    epoch = struct.unpack_from("<d", raw, 16)[0]
    dt = np.dtype([("hip", "<u4"), ("v", "<f4", 3), ("vmag", "<f4"), ("bv", "<f4"), ("plx", "<f4")])
    if rec != dt.itemsize:
        raise ValueError("unexpected stars.bin record size")
    return np.frombuffer(raw, dtype=dt, count=count, offset=24), epoch


def is_prime(n):
    if n < 2:
        return False
    if n % 2 == 0:
        return n == 2
    for i in range(3, int(n ** 0.5) + 1, 2):
        if n % i == 0:
            return False
    return True


def next_prime(n):
    n = n + 1 + (n % 2)
    while not is_prime(n):
        n += 2
    return n


def separation_for_density(fov, stars_per_fov):
    return 0.6 * fov / math.sqrt(stars_per_fov)


def num_fields_for_sky(fov):
    return math.ceil(4 * math.pi / (fov * fov))


def fibonacci_sphere_lattice(n):
    golden_angle = 2 * math.pi * (1 - 2 / (1 + math.sqrt(5)))
    i = np.arange(-n, n + 1, dtype=np.float64)
    z = i / (n + 0.5)
    r = np.sqrt(1 - z * z)
    theta = golden_angle * i
    return np.stack([np.cos(theta) * r, np.sin(theta) * r, z], axis=1)


def breadth_first_combinations(seq, r):
    if r == 1:
        for item in seq:
            yield (item,)
        return
    index = r - 1
    while index < len(seq):
        right = seq[index]
        for prefix in breadth_first_combinations(seq[:index], r - 1):
            yield prefix + (right,)
        index += 1


def angle_from_distance(d):
    return 2.0 * np.arcsin(0.5 * d)


def pattern_key_hash(key, bins):
    key = np.asarray(key, dtype=np.uint64)
    powers = np.uint64(bins) ** np.arange(key.shape[-1], dtype=np.uint64)
    return np.sum(key * powers, axis=-1, dtype=np.uint64)


def hash_index(key_hash, length):
    return (np.asarray(key_hash, dtype=np.uint64) * np.uint64(MAGIC_RAND)) % np.uint64(length)


def select_pattern_stars(vectors, separation):
    """Brightest-first thinning: keep a star only if no kept star lies within `separation` radians."""
    min_cos = math.cos(separation)
    kept = []
    for i in range(len(vectors)):
        if kept and np.max(vectors[kept] @ vectors[i]) > min_cos:
            continue
        kept.append(i)
    return kept


def generate_patterns(vectors, min_fov, max_fov, oversampling, per_field, verification, multiscale_step):
    fov_ratio = max_fov / min_fov
    divisions = int(math.ceil(math.log(fov_ratio) / math.log(multiscale_step))) + 1
    if fov_ratio < math.sqrt(multiscale_step):
        fovs = [max_fov]
        single_scale = True
    else:
        fovs = list(np.exp2(np.linspace(np.log2(min_fov), np.log2(max_fov), divisions)))
        single_scale = False
    patterns = set()
    for fov in reversed(fovs):
        separation = separation_for_density(min_fov if single_scale else fov, verification)
        kept = select_pattern_stars(vectors, separation)
        kept_vectors = vectors[kept]
        cos_radius = math.cos(fov / 2)
        n = num_fields_for_sky(fov) * oversampling
        for center in fibonacci_sphere_lattice(n):
            inside = np.nonzero(kept_vectors @ center >= cos_radius)[0]
            field_stars = sorted(kept[j] for j in inside)
            count = 0
            for pattern in breadth_first_combinations(field_stars, PATTERN_SIZE):
                patterns.add(pattern)
                count += 1
                if count >= per_field:
                    break
    return sorted(patterns)


def edge_ratios(vectors, patterns):
    """(N, 5) sorted edge ratios and (N,) largest edge angle in radians for each pattern."""
    pv = vectors[np.asarray(patterns)]
    pairs = list(itertools.combinations(range(PATTERN_SIZE), 2))
    edges = np.stack([angle_from_distance(np.linalg.norm(pv[:, i] - pv[:, j], axis=1)) for i, j in pairs], axis=1)
    edges.sort(axis=1)
    largest = edges[:, -1]
    return edges[:, :-1] / largest[:, None], largest


def presort(vectors, patterns):
    """Order each pattern's stars by distance from the pattern centroid so a solver can pair stars without trying
    permutations."""
    pv = vectors[np.asarray(patterns)]
    centroid = pv.mean(axis=1, keepdims=True)
    order = np.argsort(np.sum((pv - centroid) ** 2, axis=2), axis=1, kind="stable")
    return np.take_along_axis(np.asarray(patterns), order, axis=1)


def build_table(vectors, patterns, bins):
    length = next_prime(2 * len(patterns))
    ratios, largest = edge_ratios(vectors, patterns)
    keys = (ratios * bins).astype(np.int64)
    hashes = pattern_key_hash(keys, bins)
    indices = hash_index(hashes, length)
    ordered = presort(vectors, patterns)
    table = np.zeros((length, PATTERN_SIZE), dtype=np.uint16)
    key16 = np.zeros(length, dtype=np.uint16)
    edge16 = np.zeros(length, dtype=np.float16)
    occupied = np.zeros(length, dtype=bool)
    for p in range(len(patterns)):
        base = int(indices[p])
        c = 0
        while True:
            slot = (base + c * c) % length
            if not occupied[slot]:
                break
            c += 1
        occupied[slot] = True
        table[slot] = ordered[p]
        key16[slot] = int(hashes[p]) & 0xFFFF
        edge16[slot] = np.float16(largest[p] * 1000)
    return table, key16, edge16


def build(stars_path, out_path, min_fov_deg=25.0, max_fov_deg=80.0, mag_limit=5.0, max_error=0.005,
          oversampling=40, per_field=35, verification=80, multiscale_step=1.5):
    stars, epoch = read_stars(stars_path)
    keep = stars["vmag"] <= mag_limit
    stars = stars[keep][np.argsort(stars["vmag"][keep], kind="stable")]
    if len(stars) >= 65535:
        raise ValueError("too many stars for 16-bit indices")
    vectors = stars["v"].astype(np.float64)
    vectors /= np.linalg.norm(vectors, axis=1, keepdims=True)
    bins = round(1 / 4 / max_error)
    patterns = generate_patterns(vectors, math.radians(min_fov_deg), math.radians(max_fov_deg), oversampling,
                                 per_field, verification, multiscale_step)
    table, key16, edge16 = build_table(vectors, patterns, bins)
    header = MAGIC + struct.pack("<IIIII", VERSION, len(stars), len(patterns), len(table), bins)
    header += struct.pack("<fffffI", max_error, min_fov_deg, max_fov_deg, mag_limit, float(epoch), verification)
    header += b"\0" * (HEADER_SIZE - len(header))
    star_bytes = b"".join(struct.pack("<I4f", int(s["hip"]), *(float(x) for x in v), float(s["vmag"]))
                          for s, v in zip(stars, vectors))
    blob = header + star_bytes + table.astype("<u2").tobytes() + key16.astype("<u2").tobytes() \
        + edge16.view(np.uint16).astype("<u2").tobytes()
    Path(out_path).write_bytes(blob)
    return {"stars": len(stars), "patterns": len(patterns), "table": len(table), "bytes": len(blob), "bins": bins}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--stars", default=ROOT / "Data" / "stars.bin")
    ap.add_argument("--out", default=ROOT / "Data" / "solver_db.bin")
    ap.add_argument("--min-fov", type=float, default=25.0)
    ap.add_argument("--max-fov", type=float, default=80.0)
    ap.add_argument("--mag-limit", type=float, default=5.0)
    ap.add_argument("--max-error", type=float, default=0.005)
    ap.add_argument("--oversampling", type=int, default=40)
    ap.add_argument("--per-field", type=int, default=35)
    ap.add_argument("--verification", type=int, default=80)
    ap.add_argument("--multiscale-step", type=float, default=1.5)
    a = ap.parse_args(argv)
    info = build(a.stars, a.out, a.min_fov, a.max_fov, a.mag_limit, a.max_error, a.oversampling, a.per_field,
                 a.verification, a.multiscale_step)
    print(info)
    return 0


if __name__ == "__main__":
    sys.exit(main())
