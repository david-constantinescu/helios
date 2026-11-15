"""Display backends: the real OLED over I2C (luma.oled), PNG frames for previews and tests, or nothing."""
from __future__ import annotations

import logging
import os
from typing import Optional

from PIL import Image

log = logging.getLogger("crewhub.display")


class NullDisplay:
    def show(self, img: Image.Image) -> None:
        pass

    def contrast(self, level: int) -> None:
        pass

    def off(self) -> None:
        pass


class OledDisplay:
    """Adafruit monochrome OLEDs: SSD1306 (0.96"/1.3" 128x64, PiOLED 128x32) or SH1106 boards, on I2C bus 1."""

    def __init__(self, driver: str = "ssd1306", width: int = 128, height: int = 64, address: int = 0x3C, port: int = 1, rotate: int = 0):
        self.fast = None
        self.device = None
        if driver in ("ssd1306", "sh1106") and rotate in (0, 2):
            # Our own driver: sends only the changed bytes of each frame (see oled_fast.py).
            from .oled_fast import FastOled
            self.fast = FastOled(driver, width, height, address, port, rotate)
        else:
            from luma.core.interface.serial import i2c
            from luma.oled import device as devices
            self.device = getattr(devices, driver)(i2c(port=port, address=address), width=width, height=height, rotate=rotate)
        self._last: Optional[bytes] = None

    def show(self, img: Image.Image) -> None:
        data = img.tobytes()
        if data == self._last:
            return
        self._last = data
        if self.fast:
            self.fast.show(img)
        else:
            self.device.display(img)

    def contrast(self, level: int) -> None:
        if self.fast:
            self.fast.contrast(level)
        else:
            self.device.contrast(max(0, min(255, level)))

    def off(self) -> None:
        if self.fast:
            self.fast.off()
        else:
            self.device.hide()


class TftDisplay:
    """Adafruit 1.8" colour TFT (ST7735R) on SPI: only the changed rectangle of each frame is sent (see tft_fast.py)."""

    def __init__(self, **cfg):
        from .tft_fast import FastTft
        keys = ("width", "height", "rotate", "spi_bus", "spi_device", "dc", "rst", "speed_hz", "bgr", "invert", "col_offset", "row_offset")
        self.tft = FastTft(**{k: cfg[k] for k in keys if k in cfg})
        self.size = (self.tft.w, self.tft.h)

    def show(self, img: Image.Image) -> None:
        self.tft.show(img)

    def contrast(self, level: int) -> None:
        pass

    def off(self) -> None:
        self.tft.off()


class PngDisplay:
    """Writes the current frame to <dir>/oled.png (scaled up, white on black like the panel)."""

    def __init__(self, directory: str, scale: int = 4):
        self.dir, self.scale = directory, scale
        os.makedirs(directory, exist_ok=True)
        self._last: Optional[bytes] = None

    def show(self, img: Image.Image) -> None:
        data = img.tobytes()
        if data == self._last:
            return
        self._last = data
        big = img.convert("RGB" if img.mode == "RGB" else "L").resize((img.width * self.scale, img.height * self.scale), Image.NEAREST)
        tmp = os.path.join(self.dir, ".oled.png")
        big.save(tmp)
        os.replace(tmp, os.path.join(self.dir, "oled.png"))

    def contrast(self, level: int) -> None:
        pass

    def off(self) -> None:
        pass
