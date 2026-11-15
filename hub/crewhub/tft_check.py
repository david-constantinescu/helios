"""Puts a labelled test pattern on the TFT:  python -m crewhub.tft_check [--hold 60] [--rotate 3] [--bgr 0] [--invert 1] ...
Stop the hub first (sudo systemctl stop crewhub) — it owns the screen. Settings come from /etc/crewhub/config.json."""
import argparse
import json
import os
import time

from .tft_fast import FastTft, calibration_image


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="/etc/crewhub/config.json")
    ap.add_argument("--hold", type=float, default=60)
    for k in ("rotate", "bgr", "invert", "col_offset", "row_offset", "speed_hz", "dc", "rst"):
        ap.add_argument("--" + k.replace("_", "-"), type=int)
    a = ap.parse_args()
    cfg = {}
    if os.path.exists(a.config):
        cfg = dict(json.load(open(a.config)).get("tft") or {})
    for k in ("rotate", "bgr", "invert", "col_offset", "row_offset", "speed_hz", "dc", "rst"):
        v = getattr(a, k)
        if v is not None:
            cfg[k] = bool(v) if k in ("bgr", "invert") else v
    keys = ("width", "height", "rotate", "spi_bus", "spi_device", "dc", "rst", "speed_hz", "bgr", "invert", "col_offset", "row_offset")
    tft = FastTft(**{k: cfg[k] for k in keys if k in cfg})
    label = f"rot{cfg.get('rotate', 1)} bgr{int(cfg.get('bgr', True))} inv{int(cfg.get('invert', False))} off{cfg.get('col_offset', 0)},{cfg.get('row_offset', 0)}"
    tft.show(calibration_image(tft.w, tft.h, label))
    print("Test pattern on screen:", label)
    time.sleep(a.hold)
    tft.close()


if __name__ == "__main__":
    main()
