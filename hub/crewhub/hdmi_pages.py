"""Widescreen pages for an HDMI display (720p / 1080p / anything 16:9 or 16:10). Same navigation as the OLED and the
colour TFT (pages.Nav / handle / list_items), the same Helios look, but laid out for a TV: a page rail on the left, and on
list pages a master-detail split — the highlighted row's number and chart are always on screen, no need to open it.

Designed on a 1280×720 canvas and scaled by height/720, so one layout serves every resolution. Pure: (state, nav) → RGB image.
"""
from __future__ import annotations

import os
import time
from functools import lru_cache
from typing import Any, Callable, Dict, List, Optional, Tuple

from PIL import Image

from . import environment as env
from .pages import PAGES, Nav, cursor, list_items
from .protocol import SCENARIO_LABELS
from .state import Alert, HubState
from .tft_pages import (BG, BLUE, CARD, DIM, FAINT, LEVEL, SENSOR_NAMES, SENSOR_WORDS, SEP, TEXT, WORDS, Canvas, metric_text,
                        split_metric)

NAMES = {"home": "Home", "alerts": "Alerts", "cabin": "Cabin air", "radiation": "Radiation", "vitals": "Vitals", "activity": "Activity",
         "health": "Health", "crew": "Crew", "demo": "Demo", "hub": "Connect"}
SCENARIO_NOTES = {"normal": "A quiet day. Everything in range.", "co2": "Carbon dioxide climbs as the scrubber fails.",
                  "spike": "A solar particle event: the dose rate jumps.", "leak": "Cabin pressure falls steadily.",
                  "heat": "Cooling is lost and the cabin warms up.", "noise": "A fan runs loud and noise rises."}
M, GAP = 32, 24                 # outer margin, gutter (logical px)
RAIL_W = 210
TOP, BOTTOM = 96, 672


class Screen:
    """A Canvas whose methods take logical (1280×720) units."""

    def __init__(self, w: int, h: int):
        self.c = Canvas(w, h, cache=True)
        self.k = h / 720.0
        self.lw = w / self.k
        self.w, self.h = w, h

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

    def rrect(self, box: Tuple[float, float, float, float], r: float, fill, alpha: float = 1.0) -> None:
        k = self.k
        self.c.rrect((box[0] * k, box[1] * k, box[2] * k, box[3] * k), r * k, fill, alpha)

    def card(self, x: float, y: float, w: float, h: float, r: float = 18) -> None:
        self.rrect((x, y, x + w, y + h), r, CARD)

    def dot(self, cx: float, cy: float, r: float, fill) -> None:
        self.c.dot(cx * self.k, cy * self.k, r * self.k, fill)

    def ring(self, cx: float, cy: float, r: float, thick: float, frac: float, fill) -> None:
        self.c.ring(cx * self.k, cy * self.k, r * self.k, thick * self.k, frac, fill)

    def check(self, cx: float, cy: float, size: float, fill, width: float = 2.2) -> None:
        self.c.check(cx * self.k, cy * self.k, size * self.k, fill, width * self.k)

    def hline(self, x0: float, x1: float, y: float, fill=SEP, width: float = 1) -> None:
        k = self.k
        self.c.d.line([(x0 * k, y * k), (x1 * k, y * k)], fill=fill, width=max(1, int(round(width * k))))

    def chip(self, xr: float, cy: float, text: str, color, px: float = 14) -> None:
        w = self.width(text, px, "Bold") + 24
        self.rrect((xr - w, cy - px * 0.95, xr, cy + px * 0.95), px * 0.95, color, alpha=0.22)
        self.text(xr - w / 2, cy, text, px, "Bold", color, "mm")

    def chart(self, box: Tuple[float, float, float, float], values, color, ref: Optional[float] = None) -> Optional[Tuple[float, float]]:
        k = self.k
        ib = tuple(int(round(v * k)) for v in box)
        return self.c.chart(ib, values, color, ref, lw=3.0 * k, dot=5.0 * k, dash=max(3, int(8 * k) // 2), msg_px=self._px(20))


# --------------------------------------------------------------------------------------------------------------
# Shared pieces
# --------------------------------------------------------------------------------------------------------------

@lru_cache(maxsize=8)
def _mark(sz: int) -> Image.Image:
    return Image.open(os.path.join(os.path.dirname(__file__), "assets", "helios-mark.png")).convert("RGBA").resize((sz, sz), Image.LANCZOS)


def _header_bar(S: Screen, blink: bool) -> None:
    if blink:
        S.rrect((M - 8, 18, S.lw - M + 8, 74), 16, LEVEL[3])


def _header_brand(S: Screen) -> None:
    sz = int(round(40 * S.k))
    S.c.img.paste(_mark(sz), (int((M + 16) * S.k), int(26 * S.k)), _mark(sz))
    S.text(M + 68, 46, "Helios", 26, "Bold", TEXT)


def _header_title(S: Screen, title: str) -> None:
    S.text(M + RAIL_W + GAP, 46, title, 30, "Bold", TEXT)


def _header_clock(S: Screen, state: HubState, now: float, blink: bool) -> None:
    right = S.lw - M - 16
    S.text(right, 46, time.strftime("%H:%M", time.localtime(now)), 26, "Medium", TEXT if blink else DIM, "rm")
    x = right - S.width("00:00", 26, "Medium") - 28
    S.text(x, 46, "Phone", 15, "Medium", TEXT if blink else DIM, "rm")
    S.dot(x - S.width("Phone", 15, "Medium") - 14, 46, 5, BLUE if state.clients else FAINT)
    x -= S.width("Phone", 15, "Medium") + 44
    S.text(x, 46, "Uno", 15, "Medium", TEXT if blink else DIM, "rm")
    S.dot(x - S.width("Uno", 15, "Medium") - 14, 46, 5, LEVEL[0] if state.uno_connected else FAINT)


def _rail_card(S: Screen) -> None:
    S.card(M, TOP, RAIL_W, BOTTOM - TOP)


def _rail_row(S: Screen, i: int, sel: bool, alerts: List[Alert]) -> None:
    name = PAGES[i]
    y = TOP + 16 + i * 52
    if sel:
        S.rrect((M + 10, y, M + RAIL_W - 10, y + 46), 12, BLUE)
    S.text(M + 26, y + 23, NAMES[name], 20, "Medium" if sel else "Regular", TEXT if sel else DIM)
    if name == "alerts" and alerts:
        top = max(a.level for a in alerts)
        S.rrect((M + RAIL_W - 50, y + 11, M + RAIL_W - 22, y + 35), 12, LEVEL[top] if not sel else TEXT)
        S.text(M + RAIL_W - 36, y + 23, str(len(alerts)), 14, "Bold", BG, "mm")


def _footer(S: Screen) -> None:
    S.text(S.lw / 2 + (RAIL_W + GAP) / 2, 697, "Left / right  page      Up / down  select      Press  open or acknowledge      Hold  home", 14, "Medium", FAINT, "mm")


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
               box: Tuple[float, float, float, float], empty: str, row_h: float = 56) -> None:
    x, y, w, h = box
    S.card(x, y, w, h)
    if not items:
        S.text(x + w / 2, y + h / 2, empty, 20, "Medium", DIM, "mm")
        return
    heights = [34 if it[0] == "group" else row_h for it in items]
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
            S.text(x + 30, yy + hh - 9, str(payload).upper(), 13, "Bold", FAINT, "ls")
            yy += hh
            continue
        left, right, lvl, marked = row(kind, payload)
        sel = i == cur
        if sel:
            S.rrect((x + 10, yy, x + w - 10, yy + hh), 12, BLUE)
        elif i + 1 < len(items) and i + 1 != cur and items[i + 1][0] != "group" and yy + hh + 2 < y + h - 8:
            S.hline(x + 48, x + w - 24, yy + hh - 1)
        cy = yy + hh / 2
        if marked:
            S.check(x + 30, cy, 9, TEXT if sel else BLUE, 3)
        elif lvl > 0:
            S.dot(x + 30, cy, 6, TEXT if sel else LEVEL[lvl])
        rcol = TEXT if sel else (LEVEL[lvl] if lvl > 0 else DIM)
        rw = S.text(x + w - 28, cy, right, 20, "Medium", rcol, "rm") if right else 0
        room = w - 48 - 28 - (S.width(right, 20, "Medium") + 14 if right else 0) - 14
        S.text(x + 52, cy, S.fit(left, 20, "Regular", room), 20, "Regular", TEXT)
        yy += hh
    if start > 0 or last < len(items) - 1:
        total = len(items)
        shown = last - start + 1
        th = max(24, (h - 32) * shown / total)
        ty = y + 16 + (h - 32 - th) * (start / max(1, total - shown))
        S.rrect((x + w - 8, ty, x + w - 4, ty + th), 2, FAINT)


# --------------------------------------------------------------------------------------------------------------
# Detail panes
# --------------------------------------------------------------------------------------------------------------

def _metric_pane(S: Screen, state: HubState, kind: str, key: str, metrics: Dict[str, Any], box: Tuple[float, float, float, float]) -> None:
    x, y, w, h = box
    S.card(x, y, w, h)
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
    col = LEVEL[lvl] if lvl else BLUE
    S.text(x + 32, y + 44, S.fit(label, 26, "Bold", w - 64 - 150), 26, "Bold", TEXT)
    S.chip(x + w - 32, y + 44, SENSOR_WORDS.get(lvl, "Good"), LEVEL[lvl])
    vw = S.text(x + 32, y + 150, value, 88, "Bold", TEXT, "ls")
    S.text(x + 32 + vw + 12, y + 150, unit, 30, "Medium", DIM, "ls")
    if usual is not None:
        S.text(x + 32, y + 184, "Your usual  " + metric_text(dict(metrics.get(key, {}), id=key), usual), 20, "Medium", DIM)
    cx0, cy0, cx1, cy1 = x + 100, y + 214, x + w - 32, y + h - 62
    for i in range(4):
        S.hline(cx0, cx1, cy0 + (cy1 - cy0) * i / 3, SEP)
    rng = S.chart((cx0, cy0, cx1, cy1), series, col, ref=usual)
    if rng:
        fmt_ = lambda v: (f"{v:,.0f}" if abs(v) >= 100 else (f"{v:.1f}" if abs(v) >= 1 else f"{v:.2f}"))
        S.text(x + 32, cy0, fmt_(rng[1]), 15, "Medium", DIM, "lm")
        S.text(x + 32, cy1, fmt_(rng[0]), 15, "Medium", DIM, "lm")
    S.text(cx0, y + h - 30, foot_l, 15, "Medium", FAINT, "lm")
    S.text(cx1, y + h - 30, foot_r, 15, "Medium", FAINT, "rm")


def _alert_pane(S: Screen, a: Alert, box: Tuple[float, float, float, float]) -> None:
    x, y, w, h = box
    S.card(x, y, w, h)
    S.text(x + 32, y + 44, "ALERT", 13, "Bold", FAINT)
    S.chip(x + w - 32, y + 44, WORDS.get(a.level, ""), LEVEL[a.level])
    for i, line in enumerate(S.wrap(a.text, 34, "Bold", w - 64, 5)):
        S.text(x + 32, y + 116 + i * 46, line, 34, "Bold", TEXT)
    S.rrect((x + 32, y + h - 84, x + w - 32, y + h - 32), 14, BLUE)
    S.text(x + w / 2, y + h - 58, "Press the joystick to acknowledge", 20, "Bold", TEXT, "mm")


def _crew_pane(S: Screen, state: HubState, key: str, box: Tuple[float, float, float, float]) -> None:
    x, y, w, h = box
    S.card(x, y, w, h)
    snap = state.snapshots.get(key) or {}
    person = snap.get("person") or {}
    lvl = int((snap.get("overall") or {}).get("level", 0) or 0)
    S.text(x + 32, y + 62, person.get("name", "Crew"), 44, "Bold", TEXT)
    S.chip(x + w - 32, y + 56, WORDS.get(lvl, ""), LEVEL[max(lvl, 0)])
    day = (snap.get("mission") or {}).get("day")
    if day:
        S.text(x + 32, y + 106, f"Mission day {day}", 22, "Medium", DIM)
    title = (snap.get("overall") or {}).get("title") or (snap.get("overall") or {}).get("summary") or ""
    for i, line in enumerate(S.wrap(title, 26, "Medium", w - 64, 2)):
        S.text(x + 32, y + 168 + i * 34, line, 26, "Medium", TEXT)
    alerts = snap.get("alerts") or []
    S.text(x + 32, y + 262, "ALERTS", 13, "Bold", FAINT)
    if not alerts:
        S.text(x + 32, y + 300, "None", 22, "Medium", DIM)
    for i, al in enumerate(alerts[:5]):
        S.dot(x + 38, y + 306 + i * 46, 6, LEVEL[2])
        S.text(x + 58, y + 306 + i * 46, S.fit(str(al.get("text", "")), 20, "Regular", w - 100), 20, "Regular", TEXT)


# --------------------------------------------------------------------------------------------------------------
# Pages
# --------------------------------------------------------------------------------------------------------------

def _home_boxes(box: Tuple[float, float, float, float]):
    x0, y0, W, H = box
    lw_ = round(W * 0.54)
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
    S.card(x0, y0, lw_, H)
    S.text(x0 + 32, y0 + 48, name, 30, "Bold", TEXT)
    if day:
        S.text(x0 + lw_ - 32, y0 + 48, f"Mission day {day}", 20, "Medium", DIM, "rm")
    cx, cy = x0 + 32 + 92, y0 + 214
    S.ring(cx, cy, 86, 15, 1.0 if lvl >= 0 else 0.0, col)
    if lvl == 0:
        S.check(cx, cy, 44, col, 9)
    elif lvl > 0:
        S.text(cx, cy + 4, "!", 100, "Bold", col, "mm")
    else:
        S.text(cx, cy, "–", 80, "Bold", DIM, "mm")
    tx = x0 + 32 + 92 * 2 + 36
    S.text(tx, y0 + 190, WORDS.get(lvl, ""), 48, "Bold", col, "lm")
    sub = overall.get("title") or overall.get("summary") or ("Open the iPhone app" if not p else "")
    for i, line in enumerate(S.wrap(sub, 22, "Regular", x0 + lw_ - 32 - tx, 3)):
        S.text(tx, y0 + 236 + i * 30, line, 22, "Regular", DIM)
    S.hline(x0 + 32, x0 + lw_ - 32, y0 + 340)
    S.text(x0 + 32, y0 + 372, "ALERTS", 13, "Bold", FAINT)
    if not alerts:
        S.dot(x0 + 40, y0 + 414, 6, LEVEL[0])
        S.text(x0 + 60, y0 + 414, "All quiet", 22, "Medium", DIM)
    for i, a in enumerate(alerts[:4]):
        yy = y0 + 414 + i * 44
        S.dot(x0 + 40, yy, 6, LEVEL[a.level])
        S.text(x0 + 60, yy, S.fit(a.text, 22, "Medium", lw_ - 120), 22, "Medium", TEXT)
    if alerts:
        S.text(x0 + 32, y0 + H - 34, "Press to open alerts", 18, "Bold", BLUE)


HOME_SENSORS = ("cabin_temp", "humidity", "pressure", "co2", "o2", "noise")


def _home_cabin(S: Screen, state: HubState, box: Tuple[float, float, float, float]) -> None:
    rx, y0, rw, ch = box
    S.card(rx, y0, rw, ch)
    hab = max(state.levels.values()) if state.levels else None
    S.text(rx + 28, y0 + 36, "CABIN", 13, "Bold", FAINT)
    if hab is not None:
        S.chip(rx + rw - 28, y0 + 36, SENSOR_WORDS[hab], LEVEL[hab], 13)
    keys = [k for k in HOME_SENSORS if k in state.latest]
    cw = (rw - 56) / 2
    for i, k in enumerate(keys[:6]):
        gx = rx + 28 + (i % 2) * cw
        gy = y0 + 70 + (i // 2) * 66
        S.text(gx, gy, SENSOR_NAMES.get(k, k), 15, "Medium", DIM, "lm")
        v = env.fmt(k, state.latest.get(k), unit=False)
        vw = S.text(gx, gy + 28, v, 28, "Bold", LEVEL[state.levels.get(k, 0)] if state.levels.get(k, 0) else TEXT, "lm")
        S.text(gx + vw + 6, gy + 31, env.SENSORS[k].unit, 15, "Medium", DIM, "lm")
    if not keys:
        S.text(rx + rw / 2, y0 + ch / 2 + 10, "Waiting for sensors", 20, "Medium", DIM, "mm")


def _home_rad(S: Screen, state: HubState, box: Tuple[float, float, float, float]) -> None:
    rx, ry, rw, rh = box
    S.card(rx, ry, rw, rh)
    S.text(rx + 28, ry + 36, "RADIATION", 13, "Bold", FAINT)
    rate = state.latest.get("rad_dose_rate")
    if rate is None:
        S.text(rx + rw / 2, ry + rh / 2 + 10, "No detector", 20, "Medium", DIM, "mm")
        return
    rl = state.levels.get("rad_dose_rate", 0)
    ratio = state.ratio()
    if ratio:
        S.chip(rx + rw - 28, ry + 36, f"{ratio:.1f}× normal", LEVEL[rl] if rl else LEVEL[0], 13)
    vw = S.text(rx + 28, ry + 92, f"{rate:.3f}", 40, "Bold", TEXT, "lm")
    S.text(rx + 28 + vw + 8, ry + 98, "µSv/h", 18, "Medium", DIM, "lm")
    S.chart((rx + 28, ry + 124, rx + rw - 28, ry + rh - 28), state.series("rad_dose_rate", 900), LEVEL[rl] if rl else BLUE, ref=state.background)


def _radiation(S: Screen, state: HubState, box: Tuple[float, float, float, float]) -> None:
    x, y, w, h = box
    S.card(x, y, w, h)
    rate = state.latest.get("rad_dose_rate")
    if rate is None:
        S.text(x + w / 2, y + h / 2, "No detector", 26, "Medium", DIM, "mm")
        return
    rl = state.levels.get("rad_dose_rate", 0)
    ratio = state.ratio()
    vw = S.text(x + 32, y + 112, f"{rate:.3f}", 110, "Bold", TEXT, "ls")
    S.text(x + 32 + vw + 14, y + 112, "µSv/h", 32, "Medium", DIM, "ls")
    if ratio:
        S.chip(x + w - 32, y + 56, f"{ratio:.1f}× normal", LEVEL[rl] if rl else LEVEL[0], 16)
    cx0, cy0, cx1, cy1 = x + 100, y + 150, x + w - 32, y + h - 120
    for i in range(4):
        S.hline(cx0, cx1, cy0 + (cy1 - cy0) * i / 3, SEP)
    rng = S.chart((cx0, cy0, cx1, cy1), state.series("rad_dose_rate", 900), LEVEL[rl] if rl else BLUE, ref=state.background)
    if rng:
        S.text(x + 32, cy0, f"{rng[1]:.3f}", 15, "Medium", DIM, "lm")
        S.text(x + 32, cy1, f"{rng[0]:.3f}", 15, "Medium", DIM, "lm")
    S.text(cx0, cy1 + 28, "15 minutes ago", 15, "Medium", FAINT, "lm")
    S.text(cx1, cy1 + 28, "Now", 15, "Medium", FAINT, "rm")
    stats = [("TOTAL DOSE", f"{state.cum_dose:.2f} µSv"), ("BACKGROUND", f"{state.background:.3f} µSv/h" if state.background else "—"),
             ("COUNTS", f"{state.latest.get('rad_cpm', 0):.0f} CPM" if "rad_cpm" in state.latest else "—")]
    sw = (w - 64) / 3
    for i, (cap, val) in enumerate(stats):
        S.text(x + 32 + i * sw, y + h - 66, cap, 13, "Bold", FAINT)
        S.text(x + 32 + i * sw, y + h - 36, val, 24, "Bold", TEXT)


def _hub(S: Screen, state: HubState, net: Dict[str, Any], box: Tuple[float, float, float, float]) -> None:
    x, y, w, h = box
    cw = round(w * 0.58)
    S.card(x, y, cw, h)
    S.text(x + 36, y + 48, "HUB CODE", 14, "Bold", FAINT)
    cx = x + 36
    for ch in str(net.get("token", "------")):
        cx += S.text(cx, y + 190, ch, 118, "Bold", TEXT, "ls") + 14
    S.text(x + 36, y + 238, "Enter it in Helios", 22, "Medium", DIM)
    S.text(x + 36, y + 268, "Profile  ›  Data  ›  Helios Hub", 22, "Medium", DIM)
    up = int(time.time() - state.started)
    S.hline(x + 36, x + cw - 36, y + 330)
    S.dot(x + 44, y + 376, 7, BLUE if state.clients else FAINT)
    S.text(x + 64, y + 376, f"{len(state.clients)} phone{'s' if len(state.clients) != 1 else ''} connected", 22, "Medium", TEXT)
    S.dot(x + 44, y + 420, 7, LEVEL[0] if state.uno_connected else FAINT)
    S.text(x + 64, y + 420, "Uno sensors online" if state.uno_connected else "No Uno on USB", 22, "Medium", TEXT)
    S.text(x + 36, y + 480, f"Up {up // 3600}h {up % 3600 // 60:02d}m   ·   {net.get('records', 0):,} records", 20, "Medium", DIM)
    rx = x + cw + GAP
    rw = w - cw - GAP
    S.card(rx, y, rw, h)
    S.text(rx + 32, y + 48, "ADDRESS", 14, "Bold", FAINT)
    public = net.get("public") or ""
    S.text(rx + 32, y + 100, S.fit(public or f"{net.get('host', 'helios')}.local", 28, "Bold", rw - 64), 28, "Bold", TEXT)
    S.text(rx + 32, y + 140, "from anywhere", 18, "Regular", DIM)
    S.hline(rx + 32, rx + rw - 32, y + 176)
    S.text(rx + 32, y + 218, "ON THIS NETWORK", 14, "Bold", FAINT)
    S.text(rx + 32, y + 262, f"{net.get('host', 'helios')}.local", 24, "Bold", TEXT)
    S.text(rx + 32, y + 300, f"{net.get('ip', '--')}:{net.get('port', 8765)}", 20, "Medium", DIM)


# --------------------------------------------------------------------------------------------------------------

def _sig(values) -> int:
    """A cheap fingerprint of a data series, so an unchanged chart is not redrawn."""
    return hash(tuple(round(v, 3) for v in values if v is not None))


class Renderer:
    """Retained-mode drawing: the canvas persists between frames and each widget (header, rail, a card…) is redrawn only
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

    def _px(self, lbox: Tuple[float, float, float, float]) -> Tuple[int, int, int, int]:
        S = self.S
        x, y, w, h = lbox
        return (max(0, int(x * S.k) - 2), max(0, int(y * S.k) - 2), min(S.w, int((x + w) * S.k) + 3), min(S.h, int((y + h) * S.k) + 3))

    def _clear(self, pb: Tuple[int, int, int, int], bg=BG) -> None:
        self.S.c.d.rectangle([pb[0], pb[1], pb[2] - 1, pb[3] - 1], fill=bg)

    def widget(self, name: str, lbox: Tuple[float, float, float, float], key: Any, fn: Callable[[], None], bg=BG) -> None:
        pb = self._px(lbox)
        old = self.keys.get(name)
        if old is not None and old[0] == key and old[1] == pb:
            return
        self._clear(pb, bg)
        fn()
        self.keys[name] = (key, pb)
        self.dirty.append(pb)

    def _forget(self, prefix: str) -> None:
        for k in [k for k in self.keys if k.startswith(prefix)]:
            del self.keys[k]

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
            self._clear((0, 0, S.w, S.h))
            self.keys = {}
            self.layout = self.toast = None
            self.mode = mode
            self.dirty = [(0, 0, S.w, S.h)]
        if mode == "sleep":
            return S.c.img, self._take()
        if mode == "splash":
            def splash() -> None:
                sz = int(round(200 * S.k))
                S.c.img.paste(_mark(sz), ((S.w - sz) // 2, int(190 * S.k)), _mark(sz))
                S.text(S.lw / 2, 470, "Helios", 64, "Bold", TEXT, "mm")
                S.text(S.lw / 2, 524, "Crew health, on board", 24, "Medium", DIM, "mm")
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
        x0 = M + RAIL_W + GAP
        W = S.lw - M - x0
        H = BOTTOM - TOP
        content = (x0, TOP, W, H)

        hbg = LEVEL[3] if blink else BG                           # the header flashes red behind its text on a call-now alert
        self.widget("h:bar", (M - 12, 14, S.lw - 2 * M + 24, 64), blink, lambda: _header_bar(S, blink))
        self.widget("h:brand", (M + 12, 20, 200, 52), blink, lambda: _header_brand(S), hbg)
        self.widget("h:title", (M + RAIL_W + GAP - 4, 20, 700, 52), (title, blink), lambda: _header_title(S, title), hbg)
        self.widget("h:clock", (S.lw - M - 440, 20, 424, 52), (time.strftime("%H:%M", time.localtime(now)), blink, bool(state.clients), state.uno_connected),
                    lambda: _header_clock(S, state, now, blink), hbg)
        self.widget("r:card", (M, TOP, RAIL_W, H), 1, lambda: _rail_card(S))
        for i in range(len(PAGES)):                              # one widget per row: a page change redraws just two of them
            rowkey = (i == nav.page, (len(alerts), max([a.level for a in alerts] + [0])) if PAGES[i] == "alerts" else 0)
            self.widget(f"r:{i}", (M + 6, TOP + 14 + i * 52, RAIL_W - 12, 50), rowkey, lambda i=i: _rail_row(S, i, i == nav.page, alerts), CARD)
        self.widget("footer", (RAIL_W, 684, S.lw - RAIL_W, 28), 1, lambda: _footer(S))

        layout = (page, nav.detail is not None)
        toast = nav.toast[0] if nav.toast and now - nav.toast[1] < 2.0 else None
        if layout != self.layout or toast != self.toast:
            self._forget("c:")                                   # a new page (or the toast coming or going): redraw the content area
            self._clear(self._px(content))
            self.dirty.append(self._px(content))
            self.layout, self.toast = layout, toast

        lw_ = min(470, round(W * 0.44))
        left = (x0, TOP, lw_, H)
        right = (x0 + lw_ + GAP, TOP, W - lw_ - GAP, H)
        w = self.widget

        if nav.detail is not None and page in ("cabin", "vitals", "activity", "health"):
            kind = "sensor" if nav.detail in env.SENSORS else "metric"
            w("c:detail", content, _metric_key(state, kind, nav.detail, metrics), lambda: _metric_pane(S, state, kind, nav.detail, metrics, content))
        elif page == "home":
            lb, cb, rb = _home_boxes(content)
            w("c:hl", lb, (p.get("person"), (p.get("mission") or {}).get("day"), _home_status(state, p), p.get("overall"), tuple((a.text, a.level) for a in alerts[:4]), len(alerts)),
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
                    S.ring(x0 + W / 2, TOP + 230, 90, 14, 1.0, LEVEL[0])
                    S.check(x0 + W / 2, TOP + 230, 46, LEVEL[0], 9)
                    S.text(x0 + W / 2, TOP + 400, "All quiet", 44, "Bold", TEXT, "mm")
                    S.text(x0 + W / 2, TOP + 452, "Nothing needs your attention", 22, "Medium", DIM, "mm")
                w("c:quiet", content, 1, quiet)
            else:
                def arow(k: str, a: Alert) -> Tuple[str, str, int, bool]:
                    return a.text, "", a.level, False
                rows = tuple((a.text, a.level) for _, a in items)
                w("c:list", left, (rows, cur), lambda: _list_card(S, nav, items, cur, arow, left, "", row_h=84))
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
                w("c:pane", right, 0, lambda: S.card(*right))
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
                w("c:pane", right, 0, lambda: S.card(*right))
        elif page == "demo":
            w("c:list", left, (cur, state.scenario), lambda: _list_card(S, nav, items, cur, lambda k, sc: (SCENARIO_LABELS[sc], "", 0, sc == state.scenario), left, ""))
            if items:
                sc = items[cur][1]
                w("c:pane", right, (sc, state.scenario), lambda: _demo_pane(S, sc, state.scenario, right))
            else:
                w("c:pane", right, 0, lambda: S.card(*right))

        if toast:
            text = S.fit(toast, 22, "Medium", 600)
            tw = S.width(text, 22, "Medium") + 56
            cx = x0 + W / 2
            tb = (cx - tw / 2, 600, tw, 50)
            S.rrect((cx - tw / 2, 600, cx + tw / 2, 650), 25, (58, 58, 60))
            S.text(cx, 625, text, 22, "Medium", TEXT, "mm")
            self.dirty.append(self._px(tb))
        return S.c.img, self._take()

    def _take(self) -> List[Tuple[int, int, int, int]]:
        out, self.dirty = self.dirty, []
        full = (0, 0, self.S.w, self.S.h)
        return [full] if full in out else out


def _metric_key(state: HubState, kind: str, key: str, metrics: Dict[str, Any]) -> tuple:
    if kind == "sensor":
        return ("s", key, state.latest.get(key), state.levels.get(key, 0), _sig(state.series(key, 1800)))
    m = metrics.get(key, {})
    return ("m", key, m.get("value"), m.get("level"), m.get("usual"), m.get("label"), _sig(m.get("spark") or []))


def _demo_pane(S: Screen, sc: str, running: str, box: Tuple[float, float, float, float]) -> None:
    rx, ry, rw, rh = box
    S.card(*box)
    S.text(rx + 32, ry + 70, SCENARIO_LABELS[sc], 38, "Bold", TEXT)
    for i, line in enumerate(S.wrap(SCENARIO_NOTES.get(sc, ""), 24, "Regular", rw - 64, 3)):
        S.text(rx + 32, ry + 124 + i * 34, line, 24, "Regular", DIM)
    S.rrect((rx + 32, ry + rh - 84, rx + rw - 32, ry + rh - 32), 14, BLUE if sc != running else SEP)
    S.text(rx + rw / 2, ry + rh - 58, "Running now" if sc == running else "Press to run on the Uno", 20, "Bold", TEXT, "mm")


def render(state: HubState, nav: Nav, size: Tuple[int, int] = (1920, 1080), now: Optional[float] = None,
           net: Optional[Dict[str, Any]] = None) -> Image.Image:
    """One complete frame from scratch (previews and tests). The hub keeps a Renderer so only changes are redrawn."""
    return Renderer().draw(state, nav, size, now, net)[0]
