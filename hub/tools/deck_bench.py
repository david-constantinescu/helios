#!/usr/bin/env python3
"""Stick-to-screen latency of the page deck:  python tools/deck_bench.py [--fb /dev/fb0 | --fake 1920x1080]"""
import argparse
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
from crewhub.deck import Deck  # noqa: E402
from crewhub.fb_fast import FastFb, FbInfo  # noqa: E402
from crewhub.pages import PAGES, Nav, handle  # noqa: E402
from preview import sample_state  # noqa: E402

NET = {"host": "helios", "ip": "192.168.31.8", "port": 8765, "token": "ZANQL8", "records": 48210, "public": "nasa.softhoarders.me"}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fb")
    ap.add_argument("--fake", default="1920x1080")
    a = ap.parse_args()
    if a.fb:
        fb = FastFb(a.fb)
    else:
        w, h = map(int, a.fake.split("x"))
        fb = FastFb(info=FbInfo(w, h, 16, w * 2), buf=bytearray(w * h * 2))
    size = fb.size
    st = sample_state()
    st.started = time.time() - 60
    nav, deck = Nav(), Deck()
    now = time.time()
    t0 = time.perf_counter()
    deck.draw_active(st, nav, size, now, NET, fb)
    print(f"{size[0]}x{size[1]} {fb.info.bpp} bpp: first frame {(time.perf_counter() - t0) * 1000:.0f} ms")
    t0 = time.perf_counter()
    deck.warm(st, nav, size, now, NET, fb)
    print(f"warm-up of {len(deck.pages)} pages: {time.perf_counter() - t0:.1f} s")
    sw, mv = [], []
    for key in ["R"] * 9 + ["L"] * 9:
        handle(nav, key, st)
        t = time.perf_counter()
        deck.draw_active(st, nav, size, now, NET, fb)
        sw.append((time.perf_counter() - t) * 1000)
    nav.go("vitals")
    deck.draw_active(st, nav, size, now, NET, fb)
    for key in ["D"] * 6 + ["U"] * 6:
        handle(nav, key, st)
        t = time.perf_counter()
        deck.draw_active(st, nav, size, now, NET, fb)
        mv.append((time.perf_counter() - t) * 1000)
    print(f"page change (left/right):  mean {statistics.mean(sw):.0f} ms, worst {max(sw):.0f} ms")
    print(f"move inside a list (up/down): mean {statistics.mean(mv):.0f} ms, worst {max(mv):.0f} ms")


if __name__ == "__main__":
    main()
