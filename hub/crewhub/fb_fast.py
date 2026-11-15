"""HDMI output through the Linux framebuffer (/dev/fb0) that writes only what changed.

Each new frame is compared with what is on screen (Pillow's C-speed difference + bounding box) and only that rectangle is
converted to the panel's pixel format and copied into the memory-mapped framebuffer. A clock tick or a changing number
costs a few kilobytes instead of an 8 MB 1080p frame, which is what lets a Pi Zero 2 W keep the screen at 30 fps.

Needs the KMS driver (dtoverlay=vc4-kms-v3d, the Raspberry Pi OS default). The installer adds `video=HDMI-A-1:1920x1080@60e`
to the kernel command line so /dev/fb0 exists at that size even before a monitor is plugged in.
"""
from __future__ import annotations

import mmap
import os
from dataclasses import dataclass
from typing import Optional, Tuple

from PIL import Image, ImageChops


@dataclass
class FbInfo:
    width: int
    height: int
    bpp: int
    stride: int


def read_fb_info(dev: str = "/dev/fb0") -> FbInfo:
    base = f"/sys/class/graphics/{os.path.basename(dev)}"
    with open(base + "/virtual_size") as f:
        w, h = (int(v) for v in f.read().strip().split(","))
    with open(base + "/bits_per_pixel") as f:
        bpp = int(f.read().strip())
    try:
        with open(base + "/stride") as f:
            stride = int(f.read().strip())
    except OSError:
        stride = w * bpp // 8
    return FbInfo(w, h, bpp, stride)


try:                                    # optional: makes the 16-bit conversion ~10x faster on a Pi (apt install python3-numpy)
    import numpy as _np
except Exception:  # noqa: BLE001
    _np = None


def pack(img: Image.Image, bpp: int) -> bytes:
    """RGB image → the framebuffer's byte order (little-endian XRGB8888 / BGR888 / RGB565)."""
    if bpp == 32:
        return img.tobytes("raw", "BGRX")
    if bpp == 24:
        return img.tobytes("raw", "BGR")
    if bpp == 16 and _np is not None:
        a = _np.asarray(img)
        v = ((a[..., 0] & 0xF8).astype("<u2") << 8) | ((a[..., 1] & 0xFC).astype("<u2") << 3) | (a[..., 2] >> 3)
        return v.tobytes()
    if bpp == 16:
        r, g, b = img.split()
        hi = ImageChops.add(r.point(lambda v: v & 0xF8), g.point(lambda v: v >> 5))
        lo = ImageChops.add(g.point(lambda v: (v & 0x1C) << 3), b.point(lambda v: v >> 3))
        return Image.merge("LA", (lo, hi)).tobytes()            # little-endian: low byte first
    raise ValueError(f"unsupported framebuffer depth: {bpp} bpp")


class FastFb:
    def __init__(self, dev: str = "/dev/fb0", info: Optional[FbInfo] = None, buf=None):
        self.info = info or read_fb_info(dev)
        self._fd: Optional[int] = None
        if buf is None:
            self._fd = os.open(dev, os.O_RDWR)
            buf = mmap.mmap(self._fd, self.info.stride * self.info.height, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
        self.buf = buf
        self.size: Tuple[int, int] = (self.info.width, self.info.height)
        self.shown: Optional[Image.Image] = None
        self.bytes_written = 0
        self._first = True

    def show(self, img: Image.Image) -> int:
        """Writes the part of `img` that differs from the screen. Returns the number of bytes copied."""
        if img.mode != "RGB":
            img = img.convert("RGB")
        if img.size != self.size:
            img = img.resize(self.size)
        box = (0, 0) + self.size if self.shown is None else ImageChops.difference(self.shown, img).getbbox()
        if not box:
            return 0
        n = self._write(img, box)
        self.shown = img.copy()                               # a copy: the caller may keep drawing on the same image
        return n

    def _write(self, img: Image.Image, box: Tuple[int, int, int, int]) -> int:
        x0, y0, x1, y1 = box
        bpp = self.info.bpp
        px = bpp // 8
        data = pack(img.crop(box) if box != (0, 0) + self.size else img, bpp)
        stride, rowlen = self.info.stride, (x1 - x0) * px
        if rowlen == stride:                                  # full-width band: one contiguous copy
            self.buf[y0 * stride: y0 * stride + len(data)] = data
        else:
            off = y0 * stride + x0 * px
            for i in range(y1 - y0):
                self.buf[off: off + rowlen] = data[i * rowlen:(i + 1) * rowlen]
                off += stride
        self.bytes_written += len(data)
        return len(data)

    def show_regions(self, img: Image.Image, boxes) -> int:
        """Writes just these rectangles — for a renderer that already knows what it changed (no full-frame comparison)."""
        w, h = self.size
        if img.size != self.size:
            img = img.resize(self.size)
        if self._first:
            boxes, self._first = [(0, 0, w, h)], False
        merged: list = []
        area = lambda b: (b[2] - b[0]) * (b[3] - b[1])
        for b in sorted((max(0, a), max(0, b_), min(w, c), min(h, d)) for a, b_, c, d in boxes if c > a and d > b_):
            for i, m in enumerate(merged):                    # merge rectangles when one box covers both with little waste
                u = (min(m[0], b[0]), min(m[1], b[1]), max(m[2], b[2]), max(m[3], b[3]))
                if area(u) <= 1.25 * (area(m) + area(b)):
                    merged[i] = u
                    break
            else:
                merged.append(b)
        if sum(area(b) for b in merged) > 0.9 * w * h:
            merged = [(0, 0, w, h)]
        self.shown = None
        return sum(self._write(img, b) for b in merged)

    # --- pre-packed frames (the Deck keeps a ready-to-copy buffer per page) ---------------------------------------
    def blit_all(self, packed) -> None:
        """Copies a complete frame that is already in the framebuffer's pixel format — a few milliseconds."""
        self.buf[:len(packed)] = packed
        self.shown = None
        self._first = False

    def blit_rects(self, packed, boxes) -> int:
        stride, px = self.info.stride, self.info.bpp // 8
        mv = memoryview(packed)
        n = 0
        for x0, y0, x1, y1 in boxes:
            a, b = x0 * px, x1 * px
            if a == 0 and b == stride:
                self.buf[y0 * stride:y1 * stride] = mv[y0 * stride:y1 * stride]
            else:
                for y in range(y0, y1):
                    o = y * stride
                    self.buf[o + a:o + b] = mv[o + a:o + b]
            n += (b - a) * (y1 - y0)
        self.shown = None
        return n

    def clear(self) -> None:
        self.shown = None
        self.show(Image.new("RGB", self.size, (0, 0, 0)))

    def close(self) -> None:
        try:
            self.buf.close()
        finally:
            if self._fd is not None:
                os.close(self._fd)
                self._fd = None
