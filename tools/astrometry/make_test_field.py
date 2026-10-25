#!/usr/bin/env python
"""Render a synthetic wide-field star image from Data/stars.bin as FITS.

Default: 1920x1440, ~60 deg horizontal FOV, gnomonic projection, centred on
Orion (RA 82.5 deg, Dec 0 deg). Used to prove the local astrometry.net install.

Usage: .venv/bin/python tools/astrometry/make_test_field.py [out.fits] [--ra 82.5 --dec 0 --fov 60 --roll 0]
"""
import argparse
import struct
from pathlib import Path

import numpy as np
from astropy.io import fits

REPO = Path(__file__).resolve().parents[2]


def load_stars(path):
    buf = path.read_bytes()
    magic, version, count, rec, epoch = struct.unpack_from("<4sIIId", buf, 0)
    assert magic == b"SKYS" and rec == 28, (magic, rec)
    dt = np.dtype([("hip", "<u4"), ("x", "<f4"), ("y", "<f4"), ("z", "<f4"),
                   ("vmag", "<f4"), ("bv", "<f4"), ("plx", "<f4")])
    return np.frombuffer(buf, dtype=dt, count=count, offset=24)


def render(stars, ra0, dec0, fov_deg, w, h, roll_deg=0.0, maglim=7.0, seed=1):
    ra0, dec0, roll = np.radians([ra0, dec0, roll_deg])
    # Camera basis: forward, east, north
    f = np.array([np.cos(dec0) * np.cos(ra0), np.cos(dec0) * np.sin(ra0), np.sin(dec0)])
    e = np.array([-np.sin(ra0), np.cos(ra0), 0.0])
    n = np.cross(f, e)
    v = np.stack([stars["x"], stars["y"], stars["z"]], axis=1).astype(np.float64)
    d = v @ f
    keep = (d > 0.3) & (stars["vmag"] < maglim)
    v, d, mag = v[keep], d[keep], stars["vmag"][keep]
    xe, yn = (v @ e) / d, (v @ n) / d  # tangent-plane (gnomonic) coords
    xr = xe * np.cos(roll) - yn * np.sin(roll)
    yr = xe * np.sin(roll) + yn * np.cos(roll)
    focal = (w / 2) / np.tan(np.radians(fov_deg) / 2)  # px
    px = w / 2 - xr * focal  # RA increases to the left (sky view)
    py = h / 2 + yr * focal
    inside = (px > -5) & (px < w + 5) & (py > -5) & (py < h + 5)
    px, py, mag = px[inside], py[inside], mag[inside]

    img = np.zeros((h, w), dtype=np.float64)
    flux = 4000.0 * 10 ** (-0.4 * (mag - 3.0))
    sigma = 1.3
    yy, xx = np.mgrid[-4:5, -4:5]
    for x, y, fl in zip(px, py, flux):
        ix, iy = int(round(x)), int(round(y))
        g = fl * np.exp(-((xx + ix - x) ** 2 + (yy + iy - y) ** 2) / (2 * sigma**2)) / (2 * np.pi * sigma**2)
        y0, y1, x0, x1 = iy - 4, iy + 5, ix - 4, ix + 5
        sy0, sx0 = max(0, -y0), max(0, -x0)
        sy1, sx1 = 9 - max(0, y1 - h), 9 - max(0, x1 - w)
        if sy1 <= sy0 or sx1 <= sx0:
            continue
        img[max(y0, 0):min(y1, h), max(x0, 0):min(x1, w)] += g[sy0:sy1, sx0:sx1]
    rng = np.random.default_rng(seed)
    img += 200.0 + rng.normal(0, 8.0, img.shape)
    img = np.clip(rng.poisson(np.clip(img, 0, None)).astype(np.float64), 0, 65535)
    return img.astype(np.float32), len(px), focal


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=str(REPO / "build/astrometry-test/orion_60deg.fits"))
    ap.add_argument("--ra", type=float, default=82.5)
    ap.add_argument("--dec", type=float, default=0.0)
    ap.add_argument("--fov", type=float, default=60.0, help="horizontal FOV, degrees")
    ap.add_argument("--roll", type=float, default=0.0)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1440)
    ap.add_argument("--maglim", type=float, default=7.0)
    a = ap.parse_args()

    stars = load_stars(REPO / "Data/stars.bin")
    img, nstars, focal = render(stars, a.ra, a.dec, a.fov, a.width, a.height, a.roll, a.maglim)
    hdu = fits.PrimaryHDU(img)
    hdu.header["TRUE_RA"] = (a.ra, "true centre RA [deg]")
    hdu.header["TRUE_DEC"] = (a.dec, "true centre Dec [deg]")
    hdu.header["TRUE_FOV"] = (a.fov, "true horizontal FOV [deg]")
    hdu.header["TRUEROLL"] = (a.roll, "true roll [deg]")
    hdu.header["FOCALPX"] = (focal, "focal length [px]")
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    hdu.writeto(out, overwrite=True)
    print(f"wrote {out}  stars={nstars}  focal={focal:.1f}px  centre_scale={np.degrees(1/focal)*3600:.1f}\"/px")


if __name__ == "__main__":
    main()
