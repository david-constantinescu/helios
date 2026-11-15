"""Display backends: the real OLED over I2C (luma.oled), PNG frames for previews and tests, or nothing."""
from __future__ import annotations

import logging
import os
import time
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


class HdmiDisplay:
    """HDMI through /dev/fb0 (see fb_fast.py). Waits for the framebuffer if it isn't there yet and follows mode changes, so
    plugging the monitor in (or swapping it) later just works."""

    def __init__(self, dev: str = "/dev/fb0", fps: int = 30, **_ignored):
        self.dev, self.fps = dev, max(1, int(fps))
        self.fb = None
        self.size = (1920, 1080)
        self._retry = 0.0
        self._checked = 0.0
        self.generation = 0                      # bumps whenever the framebuffer is (re)opened: the renderer must repaint everything
        self._open()

    def _open(self) -> bool:
        from .fb_fast import FastFb
        try:
            self.fb = FastFb(self.dev)
            self.size = self.fb.size
            self.generation += 1
            log.info("HDMI framebuffer %s: %dx%d %d bpp", self.dev, *self.fb.size, self.fb.info.bpp)
            return True
        except (OSError, ValueError) as e:
            self.fb = None
            log.debug("HDMI framebuffer not ready: %s", e)
            return False

    def ready(self) -> bool:
        now = time.time()
        if self.fb is None:
            if now >= self._retry:
                self._retry = now + 3.0
                self._open()
        elif now - self._checked > 3.0:                      # the monitor may have changed mode
            self._checked = now
            from .fb_fast import read_fb_info
            try:
                info = read_fb_info(self.dev)
            except (OSError, ValueError):
                info = None
            if info is None or info != self.fb.info:
                self.fb.close()
                self.fb = None
                self._open()
        return self.fb is not None

    def show(self, img: Image.Image, dirty=None) -> None:
        if not self.ready():
            return
        try:
            if dirty is not None:
                self.fb.show_regions(img, dirty)
            else:
                self.fb.show(img)
        except (OSError, ValueError) as e:
            log.warning("HDMI write failed (%s); reopening", e)
            self.fb = None

    def contrast(self, level: int) -> None:
        pass

    def off(self) -> None:
        if self.fb is not None:
            try:
                self.fb.clear()
                self.fb.close()
            except (OSError, ValueError):
                pass


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
