#!/usr/bin/env python3
"""Zip a folder reproducibly: sorted names, fixed timestamps and modes.

    python3 tool/xcc/pack_usr.py <dir> <out.zip>

Used by tool/build_compiler.sh for assets/compiler/usr.zip, which F-Droid
rebuilds and compares byte for byte.
"""
import os
import sys
import zipfile

src, out = sys.argv[1], sys.argv[2]
names = []
for base, dirs, files in os.walk(src):
    for f in files:
        names.append(os.path.relpath(os.path.join(base, f), src))
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for n in sorted(names):
        info = zipfile.ZipInfo(n.replace(os.sep, '/'), (1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        with open(os.path.join(src, n), 'rb') as f:
            z.writestr(info, f.read(), compresslevel=9)
