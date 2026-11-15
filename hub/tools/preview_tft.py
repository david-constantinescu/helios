#!/usr/bin/env python3
"""Renders every colour (TFT) page with sample data.
    python tools/preview_tft.py sheet.png [--pages-dir DIR]     # contact sheet, plus one 1:1 PNG per page if --pages-dir
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
from PIL import Image, ImageDraw, ImageFont  # noqa: E402

from crewhub.pages import PAGES, Nav  # noqa: E402
from crewhub.tft_pages import render  # noqa: E402
from preview import sample_state  # noqa: E402

NET = {"host": "helios", "ip": "192.168.1.42", "port": 8765, "token": "ZANQL8", "records": 48210, "public": "nasa.softhoarders.me"}


def frames(st):
    now = time.time() // 2 * 2 + 0.75
    out = []
    st.started = time.time() - 60
    for name in PAGES:
        nav = Nav()
        nav.go(name)
        out.append((name, render(st, nav, (160, 128), now, NET)))
    for name, key, label in (("cabin", "co2", "cabin detail"), ("vitals", "heart_rate_resting", "vitals detail"), ("activity", "sleep_hours", "activity detail"),
                             ("radiation", None, "radiation")):
        if key is None:
            continue
        nav = Nav()
        nav.go(name)
        nav.detail = key
        out.append((label, render(st, nav, (160, 128), now, NET)))
    nav = Nav()
    nav.go("vitals")
    for _ in range(7):
        from crewhub.pages import handle
        handle(nav, "D", st)
    out.append(("vitals scrolled", render(st, nav, (160, 128), now, NET)))
    nav = Nav()
    nav.go("health")
    for _ in range(3):
        handle(nav, "D", st)
    out.append(("health groups", render(st, nav, (160, 128), now, NET)))
    nav = Nav()
    nav.go("demo")
    nav.toast = ("Radiation spike", now)
    out.append(("toast", render(st, nav, (160, 128), now, NET)))
    st2 = sample_state(spike=True)
    st2.started = time.time() - 60
    nav = Nav()
    nav.go("radiation")
    out.append(("radiation spike", render(st2, nav, (160, 128), now, NET)))
    nav = Nav()
    out.append(("home, header flash", render(st, nav, (160, 128), time.time() // 2 * 2 + 0.25, NET)))
    st3 = sample_state()
    st3.snapshots.clear()
    st3.current_person = None
    st3.started = time.time()
    out.insert(0, ("splash", render(st3, Nav(), (160, 128), time.time(), NET)))
    st3.started = time.time() - 60
    out.insert(1, ("home, no crew", render(st3, Nav(), (160, 128), now, NET)))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--pages-dir")
    a = ap.parse_args()
    fr = frames(sample_state())
    if a.pages_dir:
        os.makedirs(a.pages_dir, exist_ok=True)
        for name, img in fr:
            img.save(os.path.join(a.pages_dir, name.replace(" ", "-").replace(",", "") + ".png"))
    scale, pad, cols = 3, 14, 4
    w, h = 160 * scale, 128 * scale
    rows = (len(fr) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (w + pad) + pad, rows * (h + pad + 14) + pad), (34, 34, 38))
    d = ImageDraw.Draw(sheet)
    for i, (name, img) in enumerate(fr):
        x, y = pad + (i % cols) * (w + pad), pad + (i // cols) * (h + pad + 14)
        d.text((x, y), name, fill=(200, 200, 200))
        sheet.paste(img.resize((w, h), Image.NEAREST), (x, y + 14))
    sheet.save(a.out)
    print(a.out)


if __name__ == "__main__":
    main()
