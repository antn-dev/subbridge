#!/usr/bin/env python3
"""Assemble an OpenWrt .ipk from a control directory and a data directory.

The archives are written in GNU format on purpose: OpenWrt's opkg uses a plain
tar parser that rejects the pax headers macOS tar (bsdtar) emits by default.
The .ipk itself is a gzipped tar holding debian-binary, data.tar.gz and
control.tar.gz, in that order.

Gzip headers are written with an empty file name and the requested timestamp,
so building the same tree twice produces byte-identical packages.

Usage: make-ipk.py <control-dir> <data-dir> <output.ipk> <source-date-epoch>
"""
import gzip
import os
import shutil
import sys
import tarfile
import tempfile

SKIP = {".DS_Store"}


def _entries(src):
    return [n for n in sorted(os.listdir(src)) if n not in SKIP and not n.startswith("._")]


def _normalizer(mtime):
    def normalize(ti):
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        ti.mtime = mtime
        return ti

    return normalize


def _gzip_file(src, dest, mtime):
    with open(src, "rb") as raw, open(dest, "wb") as out:
        with gzip.GzipFile(filename="", mode="wb", fileobj=out,
                           mtime=mtime, compresslevel=9) as gz:
            shutil.copyfileobj(raw, gz)


def _tar_gz(dest, mtime, populate):
    """Write a deterministic .tar.gz at dest using populate(tar)."""
    raw = dest + ".tar"
    try:
        with tarfile.open(raw, "w", format=tarfile.GNU_FORMAT) as tf:
            populate(tf)
        _gzip_file(raw, dest, mtime)
    finally:
        if os.path.exists(raw):
            os.unlink(raw)


def _make_tar(src, dest, mtime):
    normalize = _normalizer(mtime)

    def populate(tf):
        root = tarfile.TarInfo("./")
        root.type = tarfile.DIRTYPE
        root.mode = 0o755
        tf.addfile(normalize(root))
        for name in _entries(src):
            tf.add(os.path.join(src, name), arcname="./" + name, filter=normalize)

    _tar_gz(dest, mtime, populate)


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)

    ctrl, data, out, epoch = sys.argv[1:5]
    mtime = int(epoch)

    work = tempfile.mkdtemp(prefix="mkipk-")
    try:
        _make_tar(ctrl, os.path.join(work, "control.tar.gz"), mtime)
        _make_tar(data, os.path.join(work, "data.tar.gz"), mtime)

        with open(os.path.join(work, "debian-binary"), "w") as f:
            f.write("2.0\n")

        normalize = _normalizer(mtime)

        def populate(tf):
            for name in ("debian-binary", "data.tar.gz", "control.tar.gz"):
                tf.add(os.path.join(work, name), arcname="./" + name,
                       filter=normalize)

        _tar_gz(out, mtime, populate)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
