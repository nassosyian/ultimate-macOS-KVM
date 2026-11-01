#!/usr/bin/env python3
"""For downscaled capture dumps of display frames (cap-SEQ-tT-rREF-att0-fmt44-480x270-s1920.raw),
print the fraction of pixels close to a flat colour (default: the login 'grey', ~137,128,124).

Usage: grey_frames.py DUMP_DIR [R G B [TOL]]
"""
import glob
import os
import re
import sys

import numpy as np

d = sys.argv[1]
ref = np.array([int(x) for x in sys.argv[2:5]] if len(sys.argv) >= 5 else [137, 128, 124])
tol = int(sys.argv[5]) if len(sys.argv) > 5 else 6
for f in sorted(glob.glob(os.path.join(d, "cap-*-fmt44-480x270-*.raw"))):
    m = re.search(r"cap-(\d+)-t(\d+)-r(\d+)-", f)
    px = np.frombuffer(open(f, "rb").read(), np.uint8).reshape(270, 480, 4)[:, :, [2, 1, 0]]
    grey = (np.abs(px.astype(int) - ref).max(axis=2) <= tol).mean()
    print(f"seq {int(m.group(1)):5d} ref {m.group(3):>4s} grey {grey:5.1%}")
