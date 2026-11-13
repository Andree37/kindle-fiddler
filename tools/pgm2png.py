#!/usr/bin/env python3
# Converts a PGM image (as noface-scenarios writes its snapshots) to an 8-bit gray PNG.
# Usage: tools/pgm2png.py in.pgm out.png
import sys, zlib, struct
d = open(sys.argv[1], 'rb').read()
# P5 header: magic, width height, maxval, then pixels
parts = d.split(b'\n', 3)
w, h = map(int, parts[1].split())
px = parts[3]
raw = b''.join(b'\x00' + px[y*w:(y+1)*w] for y in range(h))
def chunk(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 0, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b'')
open(sys.argv[2], 'wb').write(png)
print(w, h)
