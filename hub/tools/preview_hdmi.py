#!/usr/bin/env python3
"""Renders the widescreen (HDMI) pages with sample data.
    python tools/preview_hdmi.py out_dir [--size 1920x1080] [--time]       # one PNG per page + timing
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
from crewhub.hdmi_pages import render  # noqa: E402
from crewhub.pages import PAGES, Nav, handle  # noqa: E402
from preview import sample_state  # noqa: E402

NET = {"host": "helios", "ip": "192.168.31.8", "port": 8765, "token": "ZANQL8", "records": 48210, "public": "nasa.softhoarders.me"}


def frames(st, size):
    now = time.time() // 2 * 2 + 0.75
    st.started = time.time() - 60
    out = []
    for name in PAGES:
        nav = Nav()
        nav.go(name)
        out.append((name, nav))
    nav = Nav(); nav.go("vitals"); nav.detail = "heart_rate_resting"; out.append(("vitals-detail", nav))
    nav = Nav(); nav.go("cabin"); handle(nav, "D", st); handle(nav, "D", st); handle(nav, "D", st); out.append(("cabin-co2", nav))
    nav = Nav(); nav.go("health")
    for _ in range(6):
        handle(nav, "D", st)
    out.append(("health-scrolled", nav))
    nav = Nav(); nav.go("demo"); nav.toast = ("Radiation spike", now); out.append(("demo-toast", nav))
    for name, nav in out:
        t = time.time()
        img = render(st, nav, size, now, NET)
        yield name, img, (time.time() - t) * 1000


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--size", default="1920x1080")
    a = ap.parse_args()
    w, h = map(int, a.size.split("x"))
    os.makedirs(a.out, exist_ok=True)
    total = 0.0
    for name, img, ms in frames(sample_state(), (w, h)):
        img.save(os.path.join(a.out, f"{name}.png"))
        total += ms
        print(f"{name:16s} {ms:6.0f} ms")
    print(f"mean {total / len(PAGES):.0f} ms per page")


if __name__ == "__main__":
    main()
