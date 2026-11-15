"""Colour TFT driver: Adafruit 1.8" 160x128 (ST7735R) over SPI, sending only the rectangle that changed.

Wiring (Pi Zero, hardware SPI0): SCK=GPIO11 MOSI=GPIO10 TFT_CS=GPIO8(CE0) D/C=GPIO25 RESET=GPIO24, VCC=3.3V, LITE=3.3V.
Run `python -m crewhub.tft_check` on the Pi to put a labelled test pattern on the panel when the first picture looks wrong
(colours swapped, inverted, shifted by a pixel or two, or upside down) — every one of those is a config setting.
"""
from __future__ import annotations

import time
from typing import Callable, List, Optional, Sequence

from PIL import Image, ImageChops, ImageDraw

MY, MX, MV, BGR = 0x80, 0x40, 0x20, 0x08
ROTATIONS = {0: MX | MY, 1: MY | MV, 2: 0x00, 3: MX | MV}          # Adafruit's setRotation() values for the ST7735R

# (command, data, delay_ms) — the init sequence Adafruit uses for the 1.8" ST7735R board.
INIT = [
    (0x01, b"", 150),                                              # software reset
    (0x11, b"", 255),                                              # sleep out
    (0xB1, b"\x01\x2C\x2D", 0), (0xB2, b"\x01\x2C\x2D", 0), (0xB3, b"\x01\x2C\x2D\x01\x2C\x2D", 0),
    (0xB4, b"\x07", 0),                                            # column inversion
    (0xC0, b"\xA2\x02\x84", 0), (0xC1, b"\xC5", 0), (0xC2, b"\x0A\x00", 0), (0xC3, b"\x8A\x2A", 0),
    (0xC4, b"\x8A\xEE", 0), (0xC5, b"\x0E", 0),
    (0x3A, b"\x05", 0),                                            # 16-bit colour (RGB565)
    (0xE0, bytes([0x02, 0x1C, 0x07, 0x12, 0x37, 0x32, 0x29, 0x2D, 0x29, 0x25, 0x2B, 0x39, 0x00, 0x01, 0x03, 0x10]), 0),
    (0xE1, bytes([0x03, 0x1D, 0x07, 0x06, 0x2E, 0x2C, 0x29, 0x2D, 0x2E, 0x2E, 0x37, 0x3F, 0x00, 0x00, 0x02, 0x10]), 10),
    (0x13, b"", 10),                                               # normal display on
]


def to_rgb565(img: Image.Image) -> bytes:
    """RGB image → big-endian RGB565, entirely in Pillow's C code (no numpy, no per-pixel Python)."""
    r, g, b = img.convert("RGB").split()
    hi = ImageChops.add(r.point(lambda v: v & 0xF8), g.point(lambda v: v >> 5))
    lo = ImageChops.add(g.point(lambda v: (v & 0x1C) << 3), b.point(lambda v: v >> 3))
    return Image.merge("LA", (hi, lo)).tobytes()


class _Lgpio:
    """Output pins through lgpio (the supported GPIO library on current Raspberry Pi OS)."""

    def __init__(self, pins: Sequence[int]):
        import lgpio
        self._l = lgpio
        self._h = lgpio.gpiochip_open(0)
        for p in pins:
            lgpio.gpio_claim_output(self._h, p, 0)

    def write(self, pin: int, level: int) -> None:
        self._l.gpio_write(self._h, pin, level)

    def close(self) -> None:
        try:
            self._l.gpiochip_close(self._h)
        except Exception:  # noqa: BLE001
            pass


class FastTft:
    def __init__(self, width: int = 160, height: int = 128, rotate: int = 1, spi_bus: int = 0, spi_device: int = 0,
                 dc: int = 25, rst: int = 24, speed_hz: int = 16_000_000, bgr: bool = True, invert: bool = False,
                 col_offset: int = 0, row_offset: int = 0, spi=None, gpio=None, sleep: Callable[[float], None] = time.sleep):
        self.w, self.h, self.dc, self.rst = width, height, dc, rst
        self.col_off, self.row_off, self.sleep = col_offset, row_offset, sleep
        if spi is None:
            import spidev
            spi = spidev.SpiDev()
            spi.open(spi_bus, spi_device)
            spi.max_speed_hz = int(speed_hz)
            spi.mode = 0
        self.spi = spi
        self.gpio = gpio if gpio is not None else _Lgpio([dc, rst])
        self.shown: Optional[Image.Image] = None
        self.bytes_sent = 0
        self.madctl = ROTATIONS.get(rotate, ROTATIONS[1]) | (BGR if bgr else 0)
        self.invert = invert
        self._init()
        self.show(Image.new("RGB", (self.w, self.h), (0, 0, 0)))

    # --- low level ---------------------------------------------------------------------------------------------
    def _write(self, data: bytes) -> None:
        if not data:
            return
        self.bytes_sent += len(data)
        self.spi.writebytes2(data)

    def _cmd(self, cmd: int, data: bytes = b"") -> None:
        self.gpio.write(self.dc, 0)
        self._write(bytes([cmd]))
        if data:
            self.gpio.write(self.dc, 1)
            self._write(data)

    def _init(self) -> None:
        self.gpio.write(self.rst, 1)
        self.sleep(0.01)
        self.gpio.write(self.rst, 0)
        self.sleep(0.02)
        self.gpio.write(self.rst, 1)
        self.sleep(0.15)
        for cmd, data, delay in INIT:
            self._cmd(cmd, data)
            if delay:
                self.sleep(delay / 1000.0)
        self._cmd(0x21 if self.invert else 0x20)                  # display inversion on / off
        self._cmd(0x36, bytes([self.madctl]))
        self._cmd(0x29)                                           # display on
        self.sleep(0.1)

    def _window(self, x0: int, y0: int, x1: int, y1: int) -> None:
        x0, x1, y0, y1 = x0 + self.col_off, x1 + self.col_off, y0 + self.row_off, y1 + self.row_off
        self._cmd(0x2A, bytes([x0 >> 8, x0 & 255, x1 >> 8, x1 & 255]))
        self._cmd(0x2B, bytes([y0 >> 8, y0 & 255, y1 >> 8, y1 & 255]))
        self._cmd(0x2C)
        self.gpio.write(self.dc, 1)

    # --- frames ------------------------------------------------------------------------------------------------
    def show(self, img: Image.Image) -> int:
        """Sends the part of `img` that differs from what the panel shows. Returns the number of bytes written."""
        img = img.convert("RGB")
        if img.size != (self.w, self.h):
            img = img.resize((self.w, self.h))
        before = self.bytes_sent
        box = (0, 0, self.w, self.h) if self.shown is None else ImageChops.difference(self.shown, img).getbbox()
        if box:
            x0, y0, x1, y1 = box
            self._window(x0, y0, x1 - 1, y1 - 1)
            self._write(to_rgb565(img.crop(box)))
            self.shown = img
        return self.bytes_sent - before

    def contrast(self, level: int) -> None:                       # the backlight is wired straight to 3.3 V
        pass

    def off(self) -> None:
        self._cmd(0x28)

    def on(self) -> None:
        self._cmd(0x29)

    def close(self) -> None:
        try:
            self.spi.close()
        finally:
            if hasattr(self.gpio, "close"):
                self.gpio.close()


def calibration_image(w: int = 160, h: int = 128, label: str = "") -> Image.Image:
    """Labelled pattern: a 1-px white border on every edge, R/G/B blocks, a white→black ramp and an arrow marking the top.
    Read it like this — wrong colours: flip `bgr`; inverted (black ↔ white): flip `invert`; border cut off on the left/top:
    set `col_offset`/`row_offset` (try 1–2); arrow not at the top: change `rotate` (1 ↔ 3, or 0/2 for portrait)."""
    img = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w - 1, h - 1], outline=(255, 255, 255))
    bw = (w - 8) // 3
    for i, (name, col) in enumerate((("R", (255, 0, 0)), ("G", (0, 255, 0)), ("B", (0, 0, 255)))):
        x = 4 + i * bw
        d.rectangle([x, 28, x + bw - 2, 58], fill=col)
        d.text((x + bw // 2 - 3, 38), name, fill=(255, 255, 255) if name != "G" else (0, 0, 0))
    for x in range(4, w - 4):
        v = int(255 * (1 - (x - 4) / max(1, w - 9)))
        d.line([x, 64, x, 74], fill=(v, v, v))
    cx = w // 2
    d.polygon([(cx, 5), (cx - 6, 14), (cx + 6, 14)], fill=(255, 214, 10))
    d.text((cx + 10, 5), "TOP", fill=(255, 214, 10))
    d.text((6, 80), "Helios TFT test", fill=(255, 255, 255))
    d.text((6, 92), label or f"{w}x{h}", fill=(142, 142, 147))
    d.text((6, 104), "L/R edges: 1px border", fill=(142, 142, 147))
    return img
