"""Widescreen pages for an HDMI display, in the app's Liquid Glass look: a deep ambient background with soft coloured light,
translucent glass panels with a bright rim, a floating glass tab bar, and one clear focus lens for the joystick.

Joystick: left/right = previous/next page · up/down = move through a list · press = open / act · hold = home. The tab bar at
the bottom shows where you are, and the pill beside it names what the press button will do right now.

Designed on a 1280×720 canvas and scaled by height/720, so one layout serves 720p, 1080p and other widescreens.
Retained-mode: the canvas persists and each widget is redrawn only when what it shows changes (see Renderer).
Pure: (state, nav) → RGB image plus the rectangles that changed.
"""
from __future__ import annotations

import os
import time
from functools import lru_cache
from typing import Any, Callable, Dict, List, Optional, Tuple

from PIL import Image, ImageChops, ImageDraw, ImageFilter

from . import environment as env
from . import tft_pages
from .pages import PAGES, Nav, cursor, list_items
from .protocol import SCENARIO_LABELS
from .state import Alert, HubState
from .tft_pages import (LEVEL, SENSOR_NAMES, SENSOR_WORDS, WORDS, Canvas, _cache_get, _cache_put, metric_text, split_metric)

tft_pages._MASK_LIMIT = 64 * 1024 * 1024          # glass tiles are big; the Pi has the memory

TEXT = (255, 255, 255)
DIM = (196, 202, 220)           # secondary text on glass
FAINT = (140, 148, 172)         # captions
ACCENT = (10, 132, 255)
NAMES = {"home": "Home", "alerts": "Alerts", "cabin": "Cabin air", "radiation": "Radiation", "vitals": "Vitals", "activity": "Activity",
         "health": "Health", "crew": "Crew", "demo": "Demo", "hub": "Connect"}
SCENARIO_NOTES = {"normal": "A quiet day. Everything in range.", "co2": "Carbon dioxide climbs as the scrubber fails.",
                  "spike": "A solar particle event: the dose rate jumps.", "leak": "Cabin pressure falls steadily.",
                  "heat": "Cooling is lost and the cabin warms up.", "noise": "A fan runs loud and noise rises."}
M, GAP = 40, 24                 # outer margin, gutter (logical px)
TOP, BOTTOM = 104, 616          # content area
TAB_Y, TAB_H = 634, 56
TABW = 806
PAD = 28                        # padding inside a panel


# --------------------------------------------------------------------------------------------------------------
# Glass
# --------------------------------------------------------------------------------------------------------------

@lru_cache(maxsize=3)
def _background(w: int, h: int) -> Image.Image:
    """Deep navy with soft blobs of blue, violet and teal light — built small, blurred, and scaled up (cheap and smooth)."""
    sw, sh = max(8, w // 8), max(8, h // 8)
    base = Image.new("RGB", (sw, sh), (5, 7, 16))
    for cx, cy, r, col in ((0.10, 0.05, 0.55, (14, 88, 230)), (0.92, 0.18, 0.55, (96, 52, 210)), (0.55, 1.05, 0.55, (14, 150, 150)),
                           (0.02, 1.0, 0.40, (170, 60, 120)), (0.62, -0.10, 0.35, (40, 110, 220))):
        layer = Image.new("RGB", (sw, sh), (0, 0, 0))
        rad = r * sh
        ImageDraw.Draw(layer).ellipse([cx * sw - rad, cy * sh - rad, cx * sw + rad, cy * sh + rad], fill=tuple(int(c * 0.62) for c in col))
        base = ImageChops.add(base, layer.filter(ImageFilter.GaussianBlur(max(2, sh // 5))))
    return base.resize((w, h), Image.BICUBIC)


def _glass_tile(bg: Image.Image, box: Tuple[int, int, int, int], r: int, tint, tint_a: float, hi: float, k: float) -> Tuple[Image.Image, Image.Image]:
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    white = Image.new("RGB", (w, h), (255, 255, 255))
    img = Image.blend(bg.crop(box), white, min(0.5, 0.10 * hi))
    sheen = ImageChops.invert(Image.linear_gradient("L").resize((w, h))).point(lambda v: int(v * 0.11 * hi))   # light from above
    img.paste(white, (0, 0), sheen)
    if tint is not None:
        img = Image.blend(img, Image.new("RGB", (w, h), tint), tint_a)
    ss = 2
    r = max(1, min(r, w // 2, h // 2))
    outer = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(outer).rounded_rectangle([0, 0, w * ss - 1, h * ss - 1], r * ss, fill=255)
    rim = max(1, int(round(1.6 * k)))
    inner = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(inner).rounded_rectangle([rim * ss, rim * ss, w * ss - 1 - rim * ss, h * ss - 1 - rim * ss], max(1, r - rim) * ss, fill=255)
    mask = outer.resize((w, h), Image.BOX)
    ring = ImageChops.subtract(outer, inner).resize((w, h), Image.BOX)
    fall = ImageChops.invert(Image.linear_gradient("L").resize((w, h))).point(lambda v: 90 + int(v * 0.65))        # rim is brighter on top
    img.paste(white, (0, 0), ImageChops.multiply(ring, fall).point(lambda v: min(255, int(v * 0.62 * hi))))
    return img, mask


@lru_cache(maxsize=8)
def _mark(sz: int) -> Image.Image:
    return Image.open(os.path.join(os.path.dirname(__file__), "assets", "helios-mark.png")).convert("RGBA").resize((sz, sz), Image.LANCZOS)


class Screen:
    """A Canvas whose methods take logical (1280×720) units, with glass drawing on top."""

    def __init__(self, w: int, h: int):
        self.c = Canvas(w, h, cache=True)
        self.k = h / 720.0
        self.lw = w / self.k
        self.w, self.h = w, h
        self.bg = _background(w, h)
        self.c.img.paste(self.bg, (0, 0))

    def restore(self, pb: Tuple[int, int, int, int]) -> None:
        """Puts the plain background back under a region before it is redrawn."""
        self.c.img.paste(self.bg.crop(pb), (pb[0], pb[1]))

    def _px(self, px: float) -> int:
        return max(7, int(round(px * self.k)))

    def text(self, x: float, y: float, t: str, px: float = 16, weight: str = "Regular", fill=TEXT, anchor: str = "lm") -> float:
        return self.c.text(x * self.k, y * self.k, t, self._px(px), weight, fill, anchor) / self.k

    def width(self, t: str, px: float = 16, weight: str = "Regular") -> float:
        return self.c.width(t, self._px(px), weight) / self.k

    def fit(self, t: str, px: float, weight: str, maxw: float) -> str:
        return self.c.fit(t, self._px(px), weight, maxw * self.k)

    def wrap(self, t: str, px: float, weight: str, maxw: float, lines: int) -> List[str]:
        return self.c.wrap(t, self._px(px), weight, maxw * self.k, lines)

    def glass(self, x: float, y: float, w: float, h: float, r: float = 28, tint=None, tint_a: float = 0.0, hi: float = 1.0) -> None:
        k = self.k
        box = (max(0, int(round(x * k))), max(0, int(round(y * k))), min(self.w, int(round((x + w) * k))), min(self.h, int(round((y + h) * k))))
        if box[2] - box[0] < 4 or box[3] - box[1] < 4:
            return
        key = ("glass",) + box + (int(round(r * k)), tint, round(tint_a, 2), round(hi, 2))
        tile = _cache_get(key)
        if tile is None:
            tile = _glass_tile(self.bg, box, int(round(r * k)), tint, tint_a, hi, k)
            _cache_put(key, tile, 4 * tile[0].size[0] * tile[0].size[1])
        self.c.img.paste(tile[0], (box[0], box[1]), tile[1])

    def panel(self, x: float, y: float, w: float, h: float, r: float = 30) -> None:
        self.glass(x, y, w, h, r)

    def focus(self, x: float, y: float, w: float, h: float, r: Optional[float] = None) -> None:
        """The joystick's focus lens: brighter, tinted glass."""
        self.glass(x, y, w, h, r if r is not None else min(h / 2.4, 22), ACCENT, 0.62, 1.5)

    def capsule(self, x: float, y: float, w: float, h: float, tint=None, tint_a: float = 0.0, hi: float = 1.0) -> None:
        self.glass(x, y, w, h, h / 2, tint, tint_a, hi)

    def dot(self, cx: float, cy: float, r: float, fill) -> None:
        self.c.dot(cx * self.k, cy * self.k, r * self.k, fill)

    def ring(self, cx: float, cy: float, r: float, thick: float, frac: float, fill) -> None:
        self.c.ring(cx * self.k, cy * self.k, r * self.k, thick * self.k, frac, fill, track=(70, 80, 112))

    def check(self, cx: float, cy: float, size: float, fill, width: float = 2.2) -> None:
        self.c.check(cx * self.k, cy * self.k, size * self.k, fill, width * self.k)

    def hline(self, x0: float, x1: float, y: float, fill=(255, 255, 255), alpha: float = 0.12, width: float = 1) -> None:
        k = self.k
        y0 = int(round(y * k))
        bx0, bx1 = int(x0 * k), int(x1 * k)
        h = max(1, int(round(width * k)))
        reg = self.c.img.crop((bx0, y0, bx1, y0 + h))
        self.c.img.paste(Image.blend(reg, Image.new("RGB", reg.size, fill), alpha), (bx0, y0))

    def chip(self, xr: float, cy: float, text: str, color, px: float = 15) -> None:
        w = self.width(text, px, "Bold") + 30
        self.capsule(xr - w, cy - px * 1.1, w, px * 2.2, color, 0.55, 1.2)
        self.text(xr - w / 2, cy, text, px, "Bold", TEXT, "mm")

    def triangle(self, pts: List[Tuple[float, float]], fill) -> None:
        k = self.k
        sp = [(x * k, y * k) for x, y in pts]
        xs, ys = [p[0] for p in sp], [p[1] for p in sp]
        self.c._shape((min(xs), min(ys), max(xs), max(ys)), lambda d, bx, by: d.polygon(
            [((x - bx) * self.c._ss, (y - by) * self.c._ss) for x, y in sp], fill=255), fill, 1.0,
            key=("tri", tuple((round(x, 1), round(y, 1)) for x, y in sp)))

    def chart(self, box: Tuple[float, float, float, float], values, color, ref: Optional[float] = None) -> Optional[Tuple[float, float]]:
        k = self.k
        ib = tuple(int(round(v * k)) for v in box)
        return self.c.chart(ib, values, color, ref, lw=3.4 * k, dot=5.5 * k, dash=max(3, int(8 * k) // 2), msg_px=self._px(20))


# --------------------------------------------------------------------------------------------------------------
# Chrome: header, tab bar, joystick hint
# --------------------------------------------------------------------------------------------------------------

def _header(S: Screen, title: str, state: HubState, now: float, blink: bool) -> None:
    if blink:
        S.glass(M - 12, 18, S.lw - 2 * M + 24, 70, 35, LEVEL[3], 0.62, 1.3)
    sz = int(round(40 * S.k))
    S.c.img.paste(_mark(sz), (int(M * S.k), int(35 * S.k)), _mark(sz))
    S.text(M + 54, 54, title, 36, "Bold", TEXT)
    clock = time.strftime("%H:%M", time.localtime(now))
    cw = S.width(clock, 24, "Medium")
    pw, uw = S.width("Phone", 16, "Medium"), S.width("Uno", 16, "Medium")
    total = cw + pw + uw + 24 + 24 + 22 + 22 + 40
    x = S.lw - M - total
    S.capsule(x, 26, total, 56)
    cx = x + 26
    S.dot(cx, 54, 6, ACCENT if state.clients else FAINT)
    S.text(cx + 14, 54, "Phone", 16, "Medium", TEXT if state.clients else DIM)
    cx += 14 + pw + 26
    S.dot(cx, 54, 6, LEVEL[0] if state.uno_connected else FAINT)
    S.text(cx + 14, 54, "Uno", 16, "Medium", TEXT if state.uno_connected else DIM)
    S.text(S.lw - M - 24, 54, clock, 24, "Medium", TEXT, "rm")


def _tabbar(S: Screen, page: int, alerts: List[Alert]) -> None:
    S.capsule(M, TAB_Y, TABW, TAB_H)
    names = [NAMES[p].replace("Cabin air", "Cabin") for p in PAGES]
    widths = [S.width(n, 18, "Medium") for n in names]
    gap = (TABW - 20 - sum(widths)) / len(PAGES)
    x = M + 10
    for i, n in enumerate(names):
        w = widths[i] + gap
        if i == page:
            S.focus(x + 2, TAB_Y + 6, w - 4, TAB_H - 12, (TAB_H - 12) / 2)
        S.text(x + w / 2, TAB_Y + TAB_H / 2, n, 18, "Bold" if i == page else "Medium", TEXT if i == page else DIM, "mm")
        if PAGES[i] == "alerts" and alerts:
            top = max(a.level for a in alerts)
            S.dot(x + w - 12, TAB_Y + 13, 9, LEVEL[top])
            S.text(x + w - 12, TAB_Y + 13, str(min(9, len(alerts))), 12, "Bold", (20, 20, 24), "mm")
        x += w


def _press_hint(page: str, detail: bool, has_items: bool, alerts: List[Alert]) -> str:
    if detail:
        return "Back"
    return {"home": "Open alerts" if alerts else "", "alerts": "Acknowledge", "demo": "Run", "crew": "Show",
            "radiation": "", "hub": ""}.get(page, "Open" if has_items else "")


def _hint(S: Screen, page: str, detail: bool, has_items: bool, alerts: List[Alert]) -> None:
    x = M + TABW + 20
    w = S.lw - M - x
    S.capsule(x, TAB_Y, w, TAB_H)
    cx, cy = x + 34, TAB_Y + TAB_H / 2
    on, off = (255, 255, 255), (112, 120, 146)
    vertical = has_items and not detail
    S.triangle([(cx - 6, cy - 9), (cx + 6, cy - 9), (cx, cy - 16)], on if vertical else off)
    S.triangle([(cx - 6, cy + 9), (cx + 6, cy + 9), (cx, cy + 16)], on if vertical else off)
    S.triangle([(cx - 9, cy - 6), (cx - 9, cy + 6), (cx - 16, cy)], on if not detail else off)
    S.triangle([(cx + 9, cy - 6), (cx + 9, cy + 6), (cx + 16, cy)], on if not detail else off)
    press = _press_hint(page, detail, has_items, alerts)
    S.dot(cx, cy, 4.5, ACCENT if press else off)
    parts = []
    if not detail:
        parts.append("Pages")
    if vertical:
        parts.append("Choose")
    if press:
        parts.append("Press: " + press)
    S.text(cx + 34, cy, S.fit("  ·  ".join(parts), 16, "Medium", w - 34 - 40), 16, "Medium", DIM)


# --------------------------------------------------------------------------------------------------------------
# Lists
# --------------------------------------------------------------------------------------------------------------

def _window(nav: Nav, items: List[Tuple[str, Any]], cur: int, heights: List[float], avail: float) -> int:
    key = "hd:" + nav.name
    start = min(nav.top.get(key, 0), cur)
    if start > 0 and cur == start and items[start - 1][0] == "group":
        start -= 1
    while start < cur and sum(heights[i] for i in range(start, cur + 1)) > avail:
        start += 1
    nav.top[key] = start
    return start


def _list_card(S: Screen, nav: Nav, items: List[Tuple[str, Any]], cur: int, row: Callable[[str, Any], Tuple[str, str, int, bool]],
               box: Tuple[float, float, float, float], empty: str, row_h: float = 62) -> None:
    x, y, w, h = box
    S.panel(x, y, w, h)
    if not items:
        S.text(x + w / 2, y + h / 2, empty, 22, "Medium", DIM, "mm")
        return
    heights = [38 if it[0] == "group" else row_h for it in items]
    avail = h - 24
    start = _window(nav, items, cur, heights, avail)
    yy = y + 12
    last = start
    for i in range(start, len(items)):
        kind, payload = items[i]
        hh = heights[i]
        if yy + hh > y + h - 8:
            break
        last = i
        if kind == "group":
            S.text(x + 34, yy + hh - 10, str(payload).upper(), 14, "Bold", FAINT, "ls")
            yy += hh
            continue
        left, right, lvl, marked = row(kind, payload)
        sel = i == cur
        if sel:
            S.focus(x + 10, yy + 2, w - 20, hh - 4)
        elif i + 1 < len(items) and i + 1 != cur and items[i + 1][0] != "group" and yy + hh + 2 < y + h - 8:
            S.hline(x + 56, x + w - 28, yy + hh - 1)
        cy = yy + hh / 2
        if marked:
            S.check(x + 36, cy, 10, TEXT if sel else ACCENT, 3)
        elif lvl > 0:
            S.dot(x + 36, cy, 7, LEVEL[lvl])
        rcol = TEXT if sel else (LEVEL[lvl] if lvl > 0 else DIM)
        if right:
            S.text(x + w - 32, cy, right, 22, "Bold" if sel else "Medium", rcol, "rm")
        room = w - 64 - 32 - (S.width(right, 22, "Medium") + 16 if right else 0)
        S.text(x + 62, cy, S.fit(left, 23, "Bold" if sel else "Regular", room), 23, "Bold" if sel else "Regular", TEXT)
        yy += hh
    if start > 0 or last < len(items) - 1:
        total = len(items)
        shown = last - start + 1
        th = max(30, (h - 40) * shown / total)
        ty = y + 20 + (h - 40 - th) * (start / max(1, total - shown))
        S.capsule(x + w - 11, ty, 5, th, None, 0, 1.6)


# --------------------------------------------------------------------------------------------------------------
# Detail panes
# --------------------------------------------------------------------------------------------------------------

def _metric_pane(S: Screen, state: HubState, kind: str, key: str, metrics: Dict[str, Any], box: Tuple[float, float, float, float]) -> None:
    x, y, w, h = box
    S.panel(x, y, w, h)
    usual = None
    if kind == "sensor":
        label = SENSOR_NAMES.get(key, env.SENSORS[key].label)
        value = env.fmt(key, state.latest.get(key), unit=False)
        unit = env.SENSORS[key].unit
        lvl = state.levels.get(key, 0)
        series = state.series(key, 1800)
        foot_l, foot_r = "30 minutes ago", "Now"
    else:
        m = dict(metrics.get(key, {}), id=key)
        label = m.get("label", key)
        value, unit = split_metric(m)
        lvl = int(m.get("level", 0) or 0)
        usual = m.get("usual")
        series = m.get("spark") or []
        foot_l, foot_r = "14 days ago", "Today"
    col = LEVEL[lvl] if lvl else ACCENT
    S.text(x + PAD + 4, y + 50, S.fit(label, 28, "Bold", w - 2 * PAD - 190), 28, "Bold", TEXT)
    S.chip(x + w - PAD - 4, y + 50, SENSOR_WORDS.get(lvl, "Good"), LEVEL[lvl])
    vw = S.text(x + PAD + 4, y + 160, value, 96, "Bold", TEXT, "ls")
    S.text(x + PAD + 4 + vw + 14, y + 160, unit, 32, "Medium", DIM, "ls")
    if usual is not None:
        S.text(x + PAD + 4, y + 196, "Your usual  " + metric_text(dict(metrics.get(key, {}), id=key), usual), 21, "Medium", DIM)
    cx0, cy0, cx1, cy1 = x + 110, y + 226, x + w - PAD - 4, y + h - 64
    for i in range(4):
        S.hline(cx0, cx1, cy0 + (cy1 - cy0) * i / 3)
    rng = S.chart((cx0, cy0, cx1, cy1), series, col, ref=usual)
    if rng:
        fmt_ = lambda v: (f"{v:,.0f}" if abs(v) >= 100 else (f"{v:.1f}" if abs(v) >= 1 else f"{v:.2f}"))
        S.text(x + PAD + 4, cy0 + 4, fmt_(rng[1]), 16, "Medium", DIM, "lm")
        S.text(x + PAD + 4, cy1 - 4, fmt_(rng[0]), 16, "Medium", DIM, "lm")
    S.text(cx0, y + h - 32, foot_l, 16, "Medium", FAINT, "lm")
    S.text(cx1, y + h - 32, foot_r, 16, "Medium", FAINT, "rm")


def _alert_pane(S: Screen, a: Alert, box: Tuple[float, float, float, float]) -> None:
    x, y, w, h = box
    S.panel(x, y, w, h)
    S.text(x + PAD + 4, y + 50, "ALERT", 14, "Bold", FAINT)
    S.chip(x + w - PAD - 4, y + 50, WORDS.get(a.level, ""), LEVEL[a.level])
    for i, line in enumerate(S.wrap(a.text, 38, "Bold", w - 2 * PAD - 8, 5)):
        S.text(x + PAD + 4, y + 130 + i * 52, line, 38, "Bold", TEXT)
    S.focus(x + PAD, y + h - 92, w - 2 * PAD, 62)
    S.text(x + w / 2, y + h - 61, "Press the joystick to acknowledge", 21, "Bold", TEXT, "mm")


def _crew_pane(S: Screen, state: HubState, key: str, box: Tuple[float, float, float, float]) -> None:
    x, y, w, h = box
    S.panel(x, y, w, h)
    snap = state.snapshots.get(key) or {}
    person = snap.get("person") or {}
    lvl = int((snap.get("overall") or {}).get("level", 0) or 0)
    S.text(x + PAD + 4, y + 70, person.get("name", "Crew"), 48, "Bold", TEXT)
    S.chip(x + w - PAD - 4, y + 60, WORDS.get(lvl, ""), LEVEL[max(lvl, 0)])
    day = (snap.get("mission") or {}).get("day")
    if day:
        S.text(x + PAD + 4, y + 118, f"Day {day}", 22, "Medium", DIM)
    title = (snap.get("overall") or {}).get("title") or (snap.get("overall") or {}).get("summary") or ""
    for i, line in enumerate(S.wrap(title, 28, "Medium", w - 2 * PAD - 8, 2)):
        S.text(x + PAD + 4, y + 184 + i * 36, line, 28, "Medium", TEXT)
    alerts = snap.get("alerts") or []
    S.text(x + PAD + 4, y + 284, "ALERTS", 14, "Bold", FAINT)
    if not alerts:
        S.text(x + PAD + 4, y + 326, "None", 23, "Medium", DIM)
    for i, al in enumerate(alerts[:4]):
        S.dot(x + PAD + 10, y + 328 + i * 48, 7, LEVEL[2])
        S.text(x + PAD + 32, y + 328 + i * 48, S.fit(str(al.get("text", "")), 22, "Regular", w - 2 * PAD - 50), 22, "Regular", TEXT)


def _demo_pane(S: Screen, sc: str, running: str, box: Tuple[float, float, float, float]) -> None:
    rx, ry, rw, rh = box
    S.panel(*box)
    S.text(rx + PAD + 4, ry + 78, SCENARIO_LABELS[sc], 42, "Bold", TEXT)
    for i, line in enumerate(S.wrap(SCENARIO_NOTES.get(sc, ""), 26, "Regular", rw - 2 * PAD - 8, 3)):
        S.text(rx + PAD + 4, ry + 136 + i * 38, line, 26, "Regular", DIM)
    if sc == running:
        S.glass(rx + PAD, ry + rh - 92, rw - 2 * PAD, 62, 31, LEVEL[0], 0.45, 1.1)
        S.text(rx + rw / 2, ry + rh - 61, "Running now", 21, "Bold", TEXT, "mm")
    else:
        S.focus(rx + PAD, ry + rh - 92, rw - 2 * PAD, 62, 31)
        S.text(rx + rw / 2, ry + rh - 61, "Press to run on the Uno", 21, "Bold", TEXT, "mm")


# --------------------------------------------------------------------------------------------------------------
# Pages
# --------------------------------------------------------------------------------------------------------------

def _home_boxes(box: Tuple[float, float, float, float]):
    x0, y0, W, H = box
    lw_ = round(W * 0.50)
    rx = x0 + lw_ + GAP
    rw = W - lw_ - GAP
    ch = round((H - GAP) * 0.5)
    return (x0, y0, lw_, H), (rx, y0, rw, ch), (rx, y0 + ch + GAP, rw, H - ch - GAP)


def _home_status(state: HubState, p: Dict[str, Any]) -> int:
    lvl = state.overall_level()
    overall = p.get("overall") or {}
    if p and int(overall.get("level", 0) or 0) < 0 and lvl <= 0:
        lvl = -1
    return lvl


def _home_left(S: Screen, state: HubState, p: Dict[str, Any], alerts: List[Alert], box: Tuple[float, float, float, float]) -> None:
    x0, y0, lw_, H = box
    name = (p.get("person") or {}).get("name") or "No crew yet"
    day = (p.get("mission") or {}).get("day")
    lvl = _home_status(state, p)
    overall = p.get("overall") or {}
    col = LEVEL[lvl if lvl in LEVEL else 0]
    S.panel(x0, y0, lw_, H)
    S.text(x0 + PAD + 8, y0 + 56, name, 34, "Bold", TEXT)
    if day:
        S.text(x0 + lw_ - PAD - 8, y0 + 56, f"Day {day}", 22, "Medium", DIM, "rm")
    cx, cy = x0 + PAD + 8 + 96, y0 + 216
    S.ring(cx, cy, 90, 16, 1.0 if lvl >= 0 else 0.0, col)
    if lvl == 0:
        S.check(cx, cy, 46, col, 10)
    elif lvl > 0:
        S.text(cx, cy + 4, "!", 108, "Bold", col, "mm")
    else:
        S.text(cx, cy, "–", 84, "Bold", DIM, "mm")
    tx = x0 + PAD + 8 + 96 * 2 + 36
    S.text(tx, y0 + 188, WORDS.get(lvl, ""), 52, "Bold", col, "lm")
    sub = overall.get("title") or overall.get("summary") or ("Open the iPhone app" if not p else "")
    for i, line in enumerate(S.wrap(sub, 24, "Regular", x0 + lw_ - PAD - tx, 3)):
        S.text(tx, y0 + 238 + i * 32, line, 24, "Regular", DIM)
    S.hline(x0 + PAD, x0 + lw_ - PAD, y0 + 332)
    rows = [(a.text, a.level) for a in alerts[:3]]
    heading = "ALERTS"
    if not rows:                                  # nothing to acknowledge: show what changed in the person's own numbers
        heading = "WHAT CHANGED"
        rows = [(c.get("text", ""), max(0, int(c.get("level", 0) or 0))) for c in (p.get("changes") or [])[:3] if c.get("text")]
    S.text(x0 + PAD + 8, y0 + 366, heading, 14, "Bold", FAINT)
    if not rows:
        S.dot(x0 + PAD + 14, y0 + 412, 7, LEVEL[0])
        S.text(x0 + PAD + 34, y0 + 412, "All quiet", 24, "Medium", DIM)
    for i, (text, lv) in enumerate(rows):
        yy = y0 + 410 + i * 46
        S.dot(x0 + PAD + 14, yy, 7, LEVEL[lv])
        S.text(x0 + PAD + 34, yy, S.fit(text, 24, "Medium", lw_ - 2 * PAD - 44), 24, "Medium", TEXT)


HOME_SENSORS = ("cabin_temp", "humidity", "pressure", "co2", "o2", "noise")


def _home_cabin(S: Screen, state: HubState, box: Tuple[float, float, float, float]) -> None:
    rx, y0, rw, ch = box
    S.panel(rx, y0, rw, ch)
    hab = max(state.levels.values()) if state.levels else None
    S.text(rx + PAD + 6, y0 + 44, "CABIN", 14, "Bold", FAINT)
    if hab is not None:
        S.chip(rx + rw - PAD - 6, y0 + 44, SENSOR_WORDS[hab], LEVEL[hab], 14)
    keys = [k for k in HOME_SENSORS if k in state.latest]
    cw = (rw - 2 * PAD - 12) / 2
    for i, k in enumerate(keys[:6]):
        gx = rx + PAD + 6 + (i % 2) * cw
        gy = y0 + 84 + (i // 2) * 52
        S.text(gx, gy, SENSOR_NAMES.get(k, k), 15, "Medium", DIM, "lm")
        v = env.fmt(k, state.latest.get(k), unit=False)
        vw = S.text(gx, gy + 26, v, 28, "Bold", LEVEL[state.levels.get(k, 0)] if state.levels.get(k, 0) else TEXT, "lm")
        S.text(gx + vw + 6, gy + 29, env.SENSORS[k].unit, 15, "Medium", DIM, "lm")
    if not keys:
        S.text(rx + rw / 2, y0 + ch / 2 + 10, "Waiting for sensors", 22, "Medium", DIM, "mm")


def _home_rad(S: Screen, state: HubState, box: Tuple[float, float, float, float]) -> None:
    rx, ry, rw, rh = box
    S.panel(rx, ry, rw, rh)
    S.text(rx + PAD + 6, ry + 44, "RADIATION", 14, "Bold", FAINT)
    rate = state.latest.get("rad_dose_rate")
    if rate is None:
        S.text(rx + rw / 2, ry + rh / 2 + 10, "No detector", 22, "Medium", DIM, "mm")
        return
    rl = state.levels.get("rad_dose_rate", 0)
    ratio = state.ratio()
    if ratio:
        S.chip(rx + rw - PAD - 6, ry + 44, f"{ratio:.1f}× normal", LEVEL[rl] if rl else LEVEL[0], 14)
    vw = S.text(rx + PAD + 6, ry + 100, f"{rate:.3f}", 44, "Bold", TEXT, "lm")
    S.text(rx + PAD + 6 + vw + 10, ry + 106, "µSv/h", 20, "Medium", DIM, "lm")
    S.chart((rx + PAD + 6, ry + 132, rx + rw - PAD - 6, ry + rh - 30), state.series("rad_dose_rate", 900), LEVEL[rl] if rl else ACCENT, ref=state.background)


def _radiation(S: Screen, state: HubState, box: Tuple[float, float, float, float]) -> None:
    x, y, w, h = box
    S.panel(x, y, w, h)
    rate = state.latest.get("rad_dose_rate")
    if rate is None:
        S.text(x + w / 2, y + h / 2, "No detector", 28, "Medium", DIM, "mm")
        return
    rl = state.levels.get("rad_dose_rate", 0)
    ratio = state.ratio()
    vw = S.text(x + PAD + 6, y + 122, f"{rate:.3f}", 118, "Bold", TEXT, "ls")
    S.text(x + PAD + 6 + vw + 16, y + 122, "µSv/h", 34, "Medium", DIM, "ls")
    if ratio:
        S.chip(x + w - PAD - 6, y + 60, f"{ratio:.1f}× normal", LEVEL[rl] if rl else LEVEL[0], 17)
    cx0, cy0, cx1, cy1 = x + 110, y + 160, x + w - PAD - 6, y + h - 118
    for i in range(4):
        S.hline(cx0, cx1, cy0 + (cy1 - cy0) * i / 3)
    rng = S.chart((cx0, cy0, cx1, cy1), state.series("rad_dose_rate", 900), LEVEL[rl] if rl else ACCENT, ref=state.background)
    if rng:
        S.text(x + PAD + 6, cy0 + 4, f"{rng[1]:.3f}", 16, "Medium", DIM, "lm")
        S.text(x + PAD + 6, cy1 - 4, f"{rng[0]:.3f}", 16, "Medium", DIM, "lm")
    S.text(cx0, cy1 + 28, "15 minutes ago", 16, "Medium", FAINT, "lm")
    S.text(cx1, cy1 + 28, "Now", 16, "Medium", FAINT, "rm")
    stats = [("TOTAL DOSE", f"{state.cum_dose:.2f} µSv"), ("BACKGROUND", f"{state.background:.3f} µSv/h" if state.background else "—"),
             ("COUNTS", f"{state.latest.get('rad_cpm', 0):.0f} CPM" if "rad_cpm" in state.latest else "—")]
    sw = (w - 2 * PAD - 12) / 3
    for i, (cap, val) in enumerate(stats):
        S.text(x + PAD + 6 + i * sw, y + h - 64, cap, 14, "Bold", FAINT)
        S.text(x + PAD + 6 + i * sw, y + h - 34, val, 26, "Bold", TEXT)


def _hub(S: Screen, state: HubState, net: Dict[str, Any], box: Tuple[float, float, float, float]) -> None:
    x, y, w, h = box
    cw = round(w * 0.58)
    S.panel(x, y, cw, h)
    S.text(x + PAD + 8, y + 52, "HUB CODE", 15, "Bold", FAINT)
    cx = x + PAD + 8
    for ch in str(net.get("token", "------")):
        cx += S.text(cx, y + 188, ch, 124, "Bold", TEXT, "ls") + 14
    S.text(x + PAD + 8, y + 236, "Enter it in Helios", 23, "Medium", DIM)
    S.text(x + PAD + 8, y + 268, "Profile  ›  Data  ›  Helios Hub", 23, "Medium", DIM)
    up = int(time.time() - state.started)
    S.hline(x + PAD, x + cw - PAD, y + 316)
    S.dot(x + PAD + 16, y + 360, 8, ACCENT if state.clients else FAINT)
    S.text(x + PAD + 38, y + 360, f"{len(state.clients)} phone{'s' if len(state.clients) != 1 else ''} connected", 23, "Medium", TEXT)
    S.dot(x + PAD + 16, y + 404, 8, LEVEL[0] if state.uno_connected else FAINT)
    S.text(x + PAD + 38, y + 404, "Uno sensors online" if state.uno_connected else "No Uno on USB", 23, "Medium", TEXT)
    S.text(x + PAD + 8, y + 460, f"Up {up // 3600}h {up % 3600 // 60:02d}m   ·   {net.get('records', 0):,} records", 21, "Medium", DIM)
    rx = x + cw + GAP
    rw = w - cw - GAP
    S.panel(rx, y, rw, h)
    S.text(rx + PAD + 6, y + 52, "ADDRESS", 15, "Bold", FAINT)
    public = net.get("public") or ""
    S.text(rx + PAD + 6, y + 104, S.fit(public or f"{net.get('host', 'helios')}.local", 30, "Bold", rw - 2 * PAD - 12), 30, "Bold", TEXT)
    S.text(rx + PAD + 6, y + 144, "from anywhere", 19, "Regular", DIM)
    S.hline(rx + PAD, rx + rw - PAD, y + 182)
    S.text(rx + PAD + 6, y + 222, "ON THIS NETWORK", 15, "Bold", FAINT)
    S.text(rx + PAD + 6, y + 266, f"{net.get('host', 'helios')}.local", 26, "Bold", TEXT)
    S.text(rx + PAD + 6, y + 304, f"{net.get('ip', '--')}:{net.get('port', 8765)}", 21, "Medium", DIM)


# --------------------------------------------------------------------------------------------------------------

def _sig(values) -> int:
    """A cheap fingerprint of a data series, so an unchanged chart is not redrawn."""
    return hash(tuple(round(v, 3) for v in values if v is not None))


def _metric_key(state: HubState, kind: str, key: str, metrics: Dict[str, Any]) -> tuple:
    if kind == "sensor":
        return ("s", key, state.latest.get(key), state.levels.get(key, 0), _sig(state.series(key, 1800)))
    m = metrics.get(key, {})
    return ("m", key, m.get("value"), m.get("level"), m.get("usual"), m.get("label"), _sig(m.get("spark") or []))


class Renderer:
    """Retained-mode drawing: the canvas persists between frames and each widget (header, tab bar, a panel…) is redrawn only
    when what it shows has changed. `draw()` returns the image and the rectangles that changed, so the framebuffer driver
    writes just those — a ticking clock costs a few KB, not a full frame."""

    def __init__(self) -> None:
        self.S: Optional[Screen] = None
        self.size: Optional[Tuple[int, int]] = None
        self.keys: Dict[str, Tuple[Any, Tuple[int, int, int, int]]] = {}
        self.dirty: List[Tuple[int, int, int, int]] = []
        self.mode: Any = None
        self.layout: Any = None
        self.toast: Any = None

    # --- plumbing ----------------------------------------------------------------------------------------------
    def _reset(self, size: Tuple[int, int]) -> None:
        self.S = Screen(*size)
        self.size = size
        self.keys = {}
        self.mode = self.layout = self.toast = None
        self.dirty = [(0, 0, size[0], size[1])]

    def _px(self, lbox: Tuple[float, float, float, float], grow: int = 2) -> Tuple[int, int, int, int]:
        S = self.S
        x, y, w, h = lbox
        return (max(0, int(x * S.k) - grow), max(0, int(y * S.k) - grow), min(S.w, int((x + w) * S.k) + grow + 1), min(S.h, int((y + h) * S.k) + grow + 1))

    def widget(self, name: str, lbox: Tuple[float, float, float, float], key: Any, fn: Callable[[], None]) -> None:
        pb = self._px(lbox)
        old = self.keys.get(name)
        if old is not None and old[0] == key and old[1] == pb:
            return
        self.S.restore(pb)
        fn()
        self.keys[name] = (key, pb)
        self.dirty.append(pb)

    def _forget(self, prefix: str) -> None:
        for k in [k for k in self.keys if k.startswith(prefix)]:
            del self.keys[k]

    def _take(self) -> List[Tuple[int, int, int, int]]:
        out, self.dirty = self.dirty, []
        full = (0, 0, self.S.w, self.S.h)
        return [full] if full in out else out

    # --- a frame -----------------------------------------------------------------------------------------------
    def draw(self, state: HubState, nav: Nav, size: Tuple[int, int] = (1920, 1080), now: Optional[float] = None,
             net: Optional[Dict[str, Any]] = None) -> Tuple[Image.Image, List[Tuple[int, int, int, int]]]:
        now = now or time.time()
        if self.S is None or self.size != tuple(size):
            self._reset(tuple(size))
        S = self.S
        self.dirty = self.dirty if self.dirty == [(0, 0, S.w, S.h)] else []
        alerts = state.alerts()
        mode = "sleep" if (nav.asleep and not alerts) else ("splash" if (now - state.started < 3.0 and nav.page == 0 and not alerts) else "normal")
        if mode != self.mode:
            if mode == "sleep":
                S.c.d.rectangle([0, 0, S.w, S.h], fill=(0, 0, 0))
            else:
                S.restore((0, 0, S.w, S.h))
            self.keys = {}
            self.layout = self.toast = None
            self.mode = mode
            self.dirty = [(0, 0, S.w, S.h)]
        if mode == "sleep":
            return S.c.img, self._take()
        if mode == "splash":
            def splash() -> None:
                sz = int(round(210 * S.k))
                S.glass(S.lw / 2 - 150, 130, 300, 300, 80)
                S.c.img.paste(_mark(sz), ((S.w - sz) // 2, int(175 * S.k)), _mark(sz))
                S.text(S.lw / 2, 500, "Helios", 64, "Bold", TEXT, "mm")
                S.text(S.lw / 2, 552, "Crew health, on board", 24, "Medium", DIM, "mm")
            self.widget("splash", (0, 0, S.lw, 720), 1, splash)
            return S.c.img, self._take()

        net = net or {}
        page = nav.name
        blink = bool(alerts) and max(a.level for a in alerts) >= 3 and int(now * 2) % 2 == 0
        p = state.person() or {}
        metrics = p.get("metrics") or {}
        items = list_items(state, page)
        cur = cursor(nav, items)
        title = NAMES[page]
        if nav.detail is not None:
            title = (SENSOR_NAMES.get(nav.detail, env.SENSORS[nav.detail].label) if nav.detail in env.SENSORS
                     else metrics.get(nav.detail, {}).get("label", nav.detail))
        W = S.lw - 2 * M
        H = BOTTOM - TOP
        content = (M, TOP, W, H)
        has_items = bool(items) and page not in ("home", "radiation", "hub")

        self.widget("header", (M - 14, 14, S.lw - 2 * M + 28, 78),
                    (title, time.strftime("%H:%M", time.localtime(now)), blink, bool(state.clients), state.uno_connected),
                    lambda: _header(S, title, state, now, blink))
        self.widget("tabs", (M - 4, TAB_Y - 4, TABW + 8, TAB_H + 8), (nav.page, len(alerts), max([a.level for a in alerts] + [0])),
                    lambda: _tabbar(S, nav.page, alerts))
        self.widget("hint", (M + TABW + 16, TAB_Y - 4, S.lw - 2 * M - TABW - 12, TAB_H + 8), (page, nav.detail is not None, has_items, bool(alerts)),
                    lambda: _hint(S, page, nav.detail is not None, has_items, alerts))

        layout = (page, nav.detail is not None)
        toast = nav.toast[0] if nav.toast and now - nav.toast[1] < 2.0 else None
        if layout != self.layout or toast != self.toast:
            self._forget("c:")                                   # a new page (or the toast coming or going): redraw the content area
            pb = self._px(content, 6)
            S.restore(pb)
            self.dirty.append(pb)
            self.layout, self.toast = layout, toast

        lw_ = min(480, round(W * 0.40))
        left = (M, TOP, lw_, H)
        right = (M + lw_ + GAP, TOP, W - lw_ - GAP, H)
        w = self.widget

        if nav.detail is not None and page in ("cabin", "vitals", "activity", "health"):
            kind = "sensor" if nav.detail in env.SENSORS else "metric"
            w("c:detail", content, _metric_key(state, kind, nav.detail, metrics), lambda: _metric_pane(S, state, kind, nav.detail, metrics, content))
        elif page == "home":
            lb, cb, rb = _home_boxes(content)
            w("c:hl", lb, (p.get("person"), (p.get("mission") or {}).get("day"), _home_status(state, p), p.get("overall"), tuple((a.text, a.level) for a in alerts[:3]), len(alerts), repr(p.get("changes"))),
              lambda: _home_left(S, state, p, alerts, lb))
            w("c:hc", cb, (tuple((k, state.latest.get(k), state.levels.get(k, 0)) for k in HOME_SENSORS if k in state.latest),
                           max(state.levels.values()) if state.levels else None), lambda: _home_cabin(S, state, cb))
            w("c:hr", rb, (round(state.latest.get("rad_dose_rate", -1), 3), state.levels.get("rad_dose_rate", 0), round(state.ratio() or 0, 1),
                           _sig(state.series("rad_dose_rate", 900)), round(state.background or 0, 4)), lambda: _home_rad(S, state, rb))
        elif page == "radiation":
            w("c:rad", content, (round(state.latest.get("rad_dose_rate", -1), 3), state.levels.get("rad_dose_rate", 0), round(state.ratio() or 0, 1),
                                 _sig(state.series("rad_dose_rate", 900)), round(state.cum_dose, 2), round(state.background or 0, 4),
                                 state.latest.get("rad_cpm")), lambda: _radiation(S, state, content))
        elif page == "hub":
            up = int(now - state.started)
            w("c:hub", content, (net.get("token"), net.get("ip"), net.get("public"), len(state.clients), state.uno_connected, net.get("records", 0), up // 60),
              lambda: _hub(S, state, net, content))
        elif page == "alerts":
            if not items:
                def quiet() -> None:
                    S.panel(*content)
                    S.ring(M + W / 2, TOP + 200, 92, 15, 1.0, LEVEL[0])
                    S.check(M + W / 2, TOP + 200, 48, LEVEL[0], 10)
                    S.text(M + W / 2, TOP + 360, "All quiet", 48, "Bold", TEXT, "mm")
                    S.text(M + W / 2, TOP + 414, "Nothing needs your attention", 24, "Medium", DIM, "mm")
                w("c:quiet", content, 1, quiet)
            else:
                def arow(k: str, a: Alert) -> Tuple[str, str, int, bool]:
                    return a.text, "", a.level, False
                rows = tuple((a.text, a.level) for _, a in items)
                w("c:list", left, (rows, cur), lambda: _list_card(S, nav, items, cur, arow, left, "", row_h=90))
                w("c:pane", right, (items[cur][1].text, items[cur][1].level), lambda: _alert_pane(S, items[cur][1], right))
        elif page in ("cabin", "vitals", "activity", "health"):
            if page == "cabin":
                def row(k: str, sid: str) -> Tuple[str, str, int, bool]:
                    return SENSOR_NAMES.get(sid, env.SENSORS[sid].label), env.fmt(sid, state.latest.get(sid)), state.levels.get(sid, 0), False
                empty = "Waiting for sensors"
            else:
                def row(k: str, mid: str) -> Tuple[str, str, int, bool]:
                    m = dict(metrics.get(mid, {}), id=mid)
                    text = split_metric(m)[0] if mid == "bp_sys" else metric_text(m)
                    return m.get("label", mid), text, int(m.get("level", 0) or 0), False
                empty = "No data from the phone yet" if not state.snapshots else "Nothing recorded"
            rows = tuple((k, payload if k == "group" else row(k, payload)) for k, payload in items)
            w("c:list", left, (rows, cur), lambda: _list_card(S, nav, items, cur, row, left, empty))
            if items and items[cur][0] in ("metric", "sensor"):
                kind, mk = items[cur]
                w("c:pane", right, _metric_key(state, kind, mk, metrics), lambda: _metric_pane(S, state, kind, mk, metrics, right))
            else:
                w("c:pane", right, 0, lambda: S.panel(*right))
        elif page == "crew":
            def prow(k: str, key: str) -> Tuple[str, str, int, bool]:
                sn = state.snapshots.get(key) or {}
                lvl = int((sn.get("overall") or {}).get("level", 0) or 0)
                return (sn.get("person") or {}).get("name", "Crew"), WORDS.get(lvl, ""), max(lvl, 0), key == state.current_person
            rows = tuple(prow(k, payload) for k, payload in items)
            w("c:list", left, (rows, cur), lambda: _list_card(S, nav, items, cur, prow, left, "Connect the iPhone app"))
            if items:
                sn = state.snapshots.get(items[cur][1]) or {}
                w("c:pane", right, (items[cur][1], repr(sn.get("person")), repr(sn.get("overall")), repr(sn.get("mission")), repr(sn.get("alerts"))),
                  lambda: _crew_pane(S, state, items[cur][1], right))
            else:
                w("c:pane", right, 0, lambda: S.panel(*right))
        elif page == "demo":
            w("c:list", left, (cur, state.scenario), lambda: _list_card(S, nav, items, cur, lambda k, sc: (SCENARIO_LABELS[sc], "", 0, sc == state.scenario), left, ""))
            if items:
                sc = items[cur][1]
                w("c:pane", right, (sc, state.scenario), lambda: _demo_pane(S, sc, state.scenario, right))
            else:
                w("c:pane", right, 0, lambda: S.panel(*right))

        if toast:
            text = S.fit(toast, 23, "Bold", 600)
            tw = S.width(text, 23, "Bold") + 64
            cx = M + W / 2
            S.glass(cx - tw / 2, 540, tw, 56, 28, (30, 32, 44), 0.55, 1.2)
            S.text(cx, 568, text, 23, "Bold", TEXT, "mm")
            self.dirty.append(self._px((cx - tw / 2, 540, tw, 56)))
        return S.c.img, self._take()


def render(state: HubState, nav: Nav, size: Tuple[int, int] = (1920, 1080), now: Optional[float] = None,
           net: Optional[Dict[str, Any]] = None) -> Image.Image:
    """One complete frame from scratch (previews and tests). The hub keeps a Renderer so only changes are redrawn."""
    return Renderer().draw(state, nav, size, now, net)[0]
