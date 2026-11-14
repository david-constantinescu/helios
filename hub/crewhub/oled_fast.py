"""Fast OLED driver: SSD1306 / SH1106 over I2C that sends only what changed.

The screen memory is 8 pages of 8-pixel rows. For every frame we compare each page with what the panel already shows
and write just the changed column span of the changed pages, in one I2C transaction per span. A clock tick costs a
few dozen bytes instead of the full 1 KB frame, so the panel updates within a few milliseconds of an input.
"""
from __future__ import annotations

from typing import List, Optional, Sequence

from PIL import Image

SSD1306_INIT = [0xAE, 0xD5, 0x80, 0xA8, None, 0xD3, 0x00, 0x40, 0x8D, 0x14, 0x20, 0x00, 0xA1, 0xC8,
                0xDA, None, 0x81, 0xCF, 0xD9, 0xF1, 0xDB, 0x40, 0xA4, 0xA6, 0x2E, 0xAF]
SH1106_INIT = [0xAE, 0xD5, 0x80, 0xA8, None, 0xD3, 0x00, 0x40, 0xAD, 0x8B, 0xA1, 0xC8, 0xDA, 0x12,
               0x81, 0xCF, 0xD9, 0x22, 0xDB, 0x40, 0xA4, 0xA6, 0xAF]


_ROT_CW = getattr(getattr(Image, "Transpose", Image), "ROTATE_270")


def to_pages(img: Image.Image) -> List[bytearray]:
    """1-bit image → one bytearray per 8-pixel page. Rotating each 8-row strip clockwise turns every column into
    one byte with the top pixel in bit 0 — the panel's layout — so the conversion is done in C, not per pixel."""
    img = img.convert("1")
    w, h = img.size
    return [bytearray(img.crop((0, p * 8, w, p * 8 + 8)).transpose(_ROT_CW).tobytes()) for p in range(h // 8)]


def to_pages_slow(img: Image.Image) -> List[bytearray]:
    """1-bit image → one bytearray per 8-pixel page; bit k of byte x is pixel (x, page*8 + k)."""
    w, h = img.size
    px = img.convert("1").load()
    pages = []
    for p in range(h // 8):
        row = bytearray(w)
        y0 = p * 8
        for x in range(w):
            b = 0
            for k in range(8):
                if px[x, y0 + k]:
                    b |= 1 << k
            row[x] = b
        pages.append(row)
    return pages


def dirty_spans(old: Optional[Sequence[bytearray]], new: Sequence[bytearray]):
    """Yields (page, first_col, last_col) for every page whose bytes differ (inclusive span)."""
    for p, row in enumerate(new):
        prev = old[p] if old is not None else None
        if prev is None:
            yield p, 0, len(row) - 1
            continue
        first = last = -1
        for x in range(len(row)):
            if row[x] != prev[x]:
                if first < 0:
                    first = x
                last = x
        if first >= 0:
            yield p, first, last


class FastOled:
    def __init__(self, driver: str = "ssd1306", width: int = 128, height: int = 64, address: int = 0x3C,
                 port: int = 1, rotate: int = 0, bus=None):
        if bus is None:
            from smbus2 import SMBus
            bus = SMBus(port)
        self.bus, self.addr, self.w, self.h = bus, address, width, height
        self.sh1106 = driver == "sh1106"
        self.shown: Optional[List[bytearray]] = None
        self.bytes_sent = 0
        init = list(SH1106_INIT if self.sh1106 else SSD1306_INIT)
        init[init.index(None)] = height - 1
        if None in init:
            init[init.index(None)] = 0x12 if height == 64 else 0x02
        if rotate == 2:                                   # 180°: flip segment and COM scan direction
            init[init.index(0xA1)] = 0xA0
            init[init.index(0xC8)] = 0xC0
        self._cmd(init)
        self.show(Image.new("1", (width, height), 0))

    # --- low level ---------------------------------------------------------------------------------------------
    def _write(self, control: int, data: Sequence[int]) -> None:
        payload = [control] + list(data)
        self.bytes_sent += len(payload)
        if hasattr(self.bus, "i2c_rdwr"):
            from smbus2 import i2c_msg
            self.bus.i2c_rdwr(i2c_msg.write(self.addr, payload))
        else:                                             # test double
            self.bus.write(self.addr, payload)

    def _cmd(self, cmds: Sequence[int]) -> None:
        self._write(0x00, cmds)

    # --- frames ------------------------------------------------------------------------------------------------
    def show(self, img: Image.Image) -> int:
        """Sends the changed parts of `img`. Returns the number of bytes written."""
        new = to_pages(img)
        before = self.bytes_sent
        for p, c0, c1 in dirty_spans(self.shown, new):
            if self.sh1106:
                col = c0 + 2                              # SH1106 RAM is 132 wide, the panel starts at column 2
                self._cmd([0xB0 | p, col & 0x0F, 0x10 | (col >> 4)])
            else:
                self._cmd([0x21, c0, c1, 0x22, p, p])
            self._write(0x40, new[p][c0:c1 + 1])
        self.shown = new
        return self.bytes_sent - before

    def contrast(self, level: int) -> None:
        self._cmd([0x81, max(0, min(255, level))])

    def off(self) -> None:
        self._cmd([0xAE])

    def on(self) -> None:
        self._cmd([0xAF])
