#!/usr/bin/env python3
"""How fast can this machine draw the widescreen pages?
    python tools/hdmi_bench.py [--fb /dev/fb0 | --fake 1920x1080]
Renders every page, then a "clock tick" (the common small update), and writes them through the delta framebuffer driver."""
import argparse
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
from crewhub.fb_fast import FastFb, FbInfo  # noqa: E402
from crewhub.hdmi_pages import Renderer  # noqa: E402
from crewhub.pages import PAGES, Nav  # noqa: E402
from preview import sample_state  # noqa: E402

NET = {"host": "helios", "ip": "192.168.31.8", "port": 8765, "token": "ZANQL8", "records": 48210, "public": "nasa.softhoarders.me"}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fb", default=None)
    ap.add_argument("--fake", default="1920x1080")
    ap.add_argument("--ticks", type=int, default=30)
    a = ap.parse_args()
    if a.fb:
        fb = FastFb(a.fb)
    else:
        w, h = map(int, a.fake.split("x"))
        fb = FastFb(info=FbInfo(w, h, 32, w * 4), buf=bytearray(w * h * 4))
    size = fb.size
    print(f"output {size[0]}x{size[1]} {fb.info.bpp} bpp, stride {fb.info.stride}  ({'framebuffer ' + a.fb if a.fb else 'memory only'})")
    st = sample_state()
    st.started = time.time() - 60
    now = time.time() // 2 * 2 + 0.75
    page_ms, page_kb = [], []
    rd = Renderer()
    for name in PAGES:
        nav = Nav()
        nav.go(name)
        t0 = time.perf_counter()
        img, dirty = rd.draw(st, nav, size, now, NET)
        t1 = time.perf_counter()
        n = fb.show_regions(img, dirty)
        t2 = time.perf_counter()
        page_ms.append((t2 - t0) * 1000)
        page_kb.append(n / 1024)
        print(f"  {name:10s} render {(t1 - t0) * 1000:6.0f} ms   write {(t2 - t1) * 1000:5.0f} ms   {n / 1024:7.0f} KB")
    warm_ms = []
    for name in PAGES * 2:                                     # visit every page again: the glass and text caches are warm now
        nav = Nav()
        nav.go(name)
        t0 = time.perf_counter()
        img, dirty = rd.draw(st, nav, size, now, NET)
        fb.show_regions(img, dirty)
        warm_ms.append((time.perf_counter() - t0) * 1000)
    print(f"page change, warm: {statistics.mean(warm_ms):.0f} ms average, worst {max(warm_ms):.0f} ms")
    nav = Nav()
    nav.go("home")
    img, dirty = rd.draw(st, nav, size, now, NET)
    fb.show_regions(img, dirty)
    tick_ms, tick_kb = [], []
    for i in range(a.ticks):
        st.touch()
        t0 = time.perf_counter()
        img, dirty = rd.draw(st, nav, size, now + 60 * (i + 1), NET)       # the clock changes every tick
        n = fb.show_regions(img, dirty)
        tick_ms.append((time.perf_counter() - t0) * 1000)
        tick_kb.append(n / 1024)
    mean = statistics.mean(tick_ms)
    print(f"page change: {statistics.mean(page_ms):.0f} ms average ({1000 / statistics.mean(page_ms):.1f} fps), {statistics.mean(page_kb):.0f} KB written")
    print(f"clock tick:  {mean:.0f} ms average, worst {max(tick_ms):.0f} ms ({min(30.0, 1000 / mean):.0f} fps sustainable), {statistics.mean(tick_kb):.0f} KB written")


if __name__ == "__main__":
    main()
