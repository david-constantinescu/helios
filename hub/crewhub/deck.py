"""A deck of pre-rendered pages, so the joystick feels instant.

Each page has its own persistent Renderer (canvas) and a *packed* copy of that canvas in the framebuffer's pixel format.
Pages other than the visible one are kept up to date by a low-priority background pass. Moving to another page is then a
single memory copy of an already-converted frame (a few milliseconds) instead of drawing and converting it from scratch.
Only the visible page is ever written to the screen.
"""
from __future__ import annotations

import copy
import math
import threading
from typing import Any, Dict, List, Optional, Tuple

from PIL import Image

from .fb_fast import FastFb, pack
from .hdmi_pages import Renderer
from .pages import PAGES, Nav, list_items
from .state import HubState

Box = Tuple[int, int, int, int]


class _Page:
    def __init__(self) -> None:
        self.renderer = Renderer()
        self.lock = threading.Lock()
        self.packed: Optional[bytearray] = None
        self.ready = False


class Deck:
    def __init__(self, max_pages: Optional[int] = None):
        self.pages: Dict[int, _Page] = {}
        self.max_pages = max_pages
        self.layout: Optional[Tuple[int, int, int, int]] = None      # (w, h, bpp, stride) the buffers were built for
        self.shown: Optional[int] = None                              # index of the page that is on the screen
        self._rr = 0
        self._lock = threading.Lock()

    # --- bookkeeping -------------------------------------------------------------------------------------------
    def _configure(self, fb: FastFb) -> None:
        lay = (fb.size[0], fb.size[1], fb.info.bpp, fb.info.stride)
        if lay != self.layout:
            with self._lock:
                self.pages.clear()
                self.shown = None
                self.layout = lay
                if self.max_pages is None:                              # 1080p canvases are big: keep the visible page and its neighbours
                    self.max_pages = len(PAGES) if lay[0] * lay[1] <= 1280 * 720 else 5

    def _page(self, idx: int, active: int) -> _Page:
        with self._lock:
            pg = self.pages.get(idx)
            if pg is None:
                while len(self.pages) >= (self.max_pages or len(PAGES)):          # evict the page farthest from the visible one
                    far = max((k for k in self.pages if k != active), key=lambda k: min((k - active) % len(PAGES), (active - k) % len(PAGES)), default=None)
                    if far is None:
                        break
                    del self.pages[far]
                    if self.shown == far:
                        self.shown = None
                pg = self.pages[idx] = _Page()
            return pg

    @staticmethod
    def _view(nav: Nav, idx: int) -> Nav:
        """A private copy of the navigation state, pointed at another page (for the background pass)."""
        v = copy.copy(nav)
        v.page, v.detail, v.toast, v.asleep = idx, None, None, False
        v.cursor, v.top = dict(nav.cursor), dict(nav.top)
        return v

    def _update(self, pg: _Page, fb: FastFb, img: Image.Image, dirty: List[Box]) -> List[Box]:
        """Brings the page's packed buffer (screen resolution, screen pixel format) up to date with its canvas.
        The canvas may be smaller than the screen (drawn at 720p, shown on a 1080p output): changed rectangles are scaled up
        with a bilinear filter. Returns the screen rectangles that were repacked."""
        fw, fh = fb.size
        rw, rh = img.size
        kx, ky = fw / rw, fh / rh
        stride, px = fb.info.stride, fb.info.bpp // 8
        if pg.packed is None:
            pg.packed = bytearray(stride * fh)
            dirty = [(0, 0, rw, rh)]
        out: List[Box] = []
        for x0, y0, x1, y1 in dirty:
            x0, y0, x1, y1 = max(0, x0), max(0, y0), min(rw, x1), min(rh, y1)
            if x1 <= x0 or y1 <= y0:
                continue
            if kx == 1 and ky == 1:
                fx0, fy0, fx1, fy1 = x0, y0, x1, y1
                region = img.crop((x0, y0, x1, y1))
            else:
                fx0, fy0, fx1, fy1 = int(x0 * kx), int(y0 * ky), min(fw, math.ceil(x1 * kx)), min(fh, math.ceil(y1 * ky))
                ex0, ey0 = max(0, (x0 - 2) & ~1), max(0, (y0 - 2) & ~1)              # a margin, so the filter sees real neighbours
                ex1, ey1 = min(rw, (x1 + 3) & ~1), min(rh, (y1 + 3) & ~1)
                big = img.crop((ex0, ey0, ex1, ey1)).resize((round((ex1 - ex0) * kx), round((ey1 - ey0) * ky)), Image.BILINEAR)
                ox, oy = int(ex0 * kx), int(ey0 * ky)
                region = big.crop((fx0 - ox, fy0 - oy, fx1 - ox, fy1 - oy))
            data = pack(region, fb.info.bpp)
            rowlen = (fx1 - fx0) * px
            if rowlen == stride:
                pg.packed[fy0 * stride: fy0 * stride + len(data)] = data
            else:
                for i in range(fy1 - fy0):
                    o = (fy0 + i) * stride + fx0 * px
                    pg.packed[o:o + rowlen] = data[i * rowlen:(i + 1) * rowlen]
            out.append((fx0, fy0, fx1, fy1))
        pg.ready = True
        return out

    # --- drawing -----------------------------------------------------------------------------------------------
    def draw_active(self, state: HubState, nav: Nav, size: Tuple[int, int], now: float, net: Dict[str, Any], fb: FastFb) -> int:
        """Draws the visible page and puts it on the screen. Returns the number of bytes written to the framebuffer."""
        self._configure(fb)
        idx = nav.page
        pg = self._page(idx, idx)
        with pg.lock:
            img, dirty = pg.renderer.draw(state, nav, size, now, net)
            fresh = pg.packed is None
            rects = self._update(pg, fb, img, dirty)
            if self.shown != idx or fresh:
                fb.blit_all(pg.packed)                                    # a different page: one memory copy
                self.shown = idx
                return len(pg.packed)
            return fb.blit_rects(pg.packed, rects) if rects else 0

    def background(self, state: HubState, nav: Nav, size: Tuple[int, int], now: float, net: Dict[str, Any], fb: FastFb, count: int = 2) -> None:
        """Refreshes a few of the pages that are not on screen (round-robin), so they are ready when the stick moves."""
        self._configure(fb)
        active = nav.page
        order = [(active + d) % len(PAGES) for d in (1, -1, 2, -2, 3, -3, 4, -4, 5)]       # nearest first
        budget = self.max_pages or len(PAGES)
        wanted = [i for i in order if i != active][:max(0, budget - 1)]
        for _ in range(count):
            if not wanted:
                return
            idx = wanted[self._rr % len(wanted)]
            self._rr += 1
            pg = self._page(idx, active)
            if not pg.lock.acquire(blocking=False):                       # it is being drawn right now
                continue
            try:
                img, dirty = pg.renderer.draw(state, self._view(nav, idx), size, now, net)
                self._update(pg, fb, img, dirty)
            finally:
                pg.lock.release()

    def warm(self, state: HubState, nav: Nav, size: Tuple[int, int], now: float, net: Dict[str, Any], fb: FastFb) -> None:
        """At start-up: draws every page that fits once, and every row of every list page, so the first visit to anything is
        as fast as the next (the pictures are cached). Nearest pages first."""
        self.background(state, nav, size, now, net, fb, count=(self.max_pages or len(PAGES)) if self.layout else len(PAGES))
        active = nav.page
        for idx in [(active + d) % len(PAGES) for d in (1, -1, 2, -2, 3, -3, 4, -4, 5)]:
            name = PAGES[idx]
            items = list_items(state, name)
            if idx not in self.pages or name in ("home", "radiation", "hub") or len(items) < 2:
                continue
            pg = self.pages[idx]
            with pg.lock:
                for i, (kind, _) in enumerate(items[:40]):
                    if kind == "group":
                        continue
                    v = self._view(nav, idx)
                    v.cursor[name] = i
                    pg.renderer.draw(state, v, size, now, net)
                img, _ = pg.renderer.draw(state, self._view(nav, idx), size, now, net)
                self._update(pg, fb, img, [(0, 0, img.size[0], img.size[1])])
