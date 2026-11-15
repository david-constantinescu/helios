"""Colour pages for the 1.8" TFT (160x128). Same navigation as the OLED (pages.Nav / handle / list_items), new look:
the Helios app's dark, rounded, Apple-style design — black background, grouped list cards, one accent, status colours.

Pure: (hub state, navigation) → RGB PIL image, so every page can be previewed as a PNG without any hardware.
"""
from __future__ import annotations

import os
import time
from functools import lru_cache
from typing import Any, Callable, Dict, List, Optional, Tuple

from PIL import Image, ImageDraw, ImageFont

from . import environment as env
from .pages import CABIN, TITLES, Nav, cursor, list_items  # noqa: F401 — re-exported for callers
from .protocol import SCENARIO_LABELS
from .state import Alert, HubState

Color = Tuple[int, int, int]
BG: Color = (0, 0, 0)
CARD: Color = (28, 28, 30)
SEP: Color = (50, 50, 53)
TEXT: Color = (255, 255, 255)
DIM: Color = (152, 152, 157)
FAINT: Color = (99, 99, 102)
BLUE: Color = (10, 132, 255)
LEVEL: Dict[int, Color] = {-1: DIM, 0: (48, 209, 88), 1: (255, 214, 10), 2: (255, 159, 10), 3: (255, 69, 58)}
WORDS = {-1: "No data", 0: "All good", 1: "Watch", 2: "Act", 3: "Call now"}
SENSOR_WORDS = {0: "Good", 1: "Watch", 2: "Act", 3: "Call now"}

SS = 4                       # shapes are drawn 4x and averaged down, so curves are smooth on a tiny panel
PAD = 5                      # outer margin
RH = 16                      # list row height
TOP, BOTTOM = 19, 118        # content area (below the header, above the page dots)

_FONTS = os.path.join(os.path.dirname(__file__), "fonts")


@lru_cache(maxsize=None)
def font(weight: str, px: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(os.path.join(_FONTS, f"Roboto-{weight}.ttf"), px)


SENSOR_NAMES = {"cabin_temp": "Temperature", "humidity": "Humidity", "pressure": "Pressure", "co2": "Carbon dioxide", "o2": "Oxygen",
                "noise": "Noise", "light": "Light", "rad_dose_rate": "Radiation", "rad_cpm": "Counts"}
UNIT_MAP = {"breaths/min": " /min", "steps": "", "count": "", "floors": " floors", "mL/kg/min": "", "%": "%", "°C": " °C", "h": " h"}


def split_metric(m: Dict[str, Any], value: Optional[float] = None) -> Tuple[str, str]:
    """('66', 'bpm') — the number and its unit, formatted for the colour screen."""
    v = m.get("value") if value is None else value
    if v is None:
        return "—", ""
    d = int(m.get("decimals", 0) or 0)
    unit = m.get("unit") or ""
    if unit in ("1–5", "1-5"):
        return f"{v:.{d}f}", "/5"
    if m.get("id") == "bp_sys" and m.get("pair") is not None:
        return f"{v:.0f}/{m['pair']:.0f}", "mmHg"
    return f"{v:,.{d}f}", UNIT_MAP.get(unit, unit).strip()


def metric_text(m: Dict[str, Any], value: Optional[float] = None) -> str:
    num, unit = split_metric(m, value)
    return num + ((unit if unit in ("%", "/5") else " " + unit) if unit else "")


def mix(a: Color, b: Color, t: float) -> Color:
    return (int(a[0] + (b[0] - a[0]) * t), int(a[1] + (b[1] - a[1]) * t), int(a[2] + (b[2] - a[2]) * t))


def clean(s: str) -> str:
    return s.replace("₂", "2").replace(" ", " ")


class Canvas:
    def __init__(self, w: int, h: int):
        self.w, self.h = w, h
        self.img = Image.new("RGB", (w, h), BG)
        self.d = ImageDraw.Draw(self.img)

    # --- text --------------------------------------------------------------------------------------------------
    def text(self, x: float, y: float, s: str, px: int = 11, weight: str = "Regular", fill: Color = TEXT, anchor: str = "lm") -> float:
        s = clean(s)
        f = font(weight, px)
        self.d.text((x, y), s, font=f, fill=fill, anchor=anchor)
        return f.getlength(s)

    def width(self, s: str, px: int = 11, weight: str = "Regular") -> float:
        return font(weight, px).getlength(clean(s))

    def fit(self, s: str, px: int, weight: str, maxw: float) -> str:
        s = clean(s)
        f = font(weight, px)
        if f.getlength(s) <= maxw:
            return s
        while len(s) > 1 and f.getlength(s + "…") > maxw:
            s = s[:-1]
        return s.rstrip() + "…"

    def wrap(self, s: str, px: int, weight: str, maxw: float, lines: int) -> List[str]:
        f = font(weight, px)
        out: List[str] = []
        cur = ""
        words = clean(s).split()
        for i, w in enumerate(words):
            t = f"{cur} {w}".strip()
            if f.getlength(t) <= maxw or not cur:
                cur = t
            else:
                out.append(cur)
                cur = w
            if len(out) == lines:
                break
        else:
            out.append(cur)
        if len(out) > lines or (len(out) == lines and " ".join(out) != " ".join(words)):
            out = out[:lines]
            out[-1] = self.fit(out[-1] + " …", px, weight, maxw) if not out[-1].endswith("…") else out[-1]
        return [self.fit(l, px, weight, maxw) for l in out if l]

    # --- smooth shapes -----------------------------------------------------------------------------------------
    def _shape(self, box: Tuple[float, float, float, float], draw_fn: Callable[[ImageDraw.ImageDraw, float, float], None],
               fill: Color, alpha: float = 1.0) -> None:
        x0, y0, x1, y1 = box
        bx, by = int(x0) - 1, int(y0) - 1
        bw, bh = int(x1) + 2 - bx, int(y1) + 2 - by
        m = Image.new("L", (bw * SS, bh * SS), 0)
        draw_fn(ImageDraw.Draw(m), bx, by)
        m = m.resize((bw, bh), Image.BOX)
        if alpha < 1:
            m = m.point(lambda v: int(v * alpha))
        self.img.paste(fill, (bx, by), m)

    def rrect(self, box: Tuple[float, float, float, float], r: float, fill: Color, alpha: float = 1.0) -> None:
        x0, y0, x1, y1 = box
        self._shape(box, lambda d, bx, by: d.rounded_rectangle(
            [(x0 - bx) * SS, (y0 - by) * SS, (x1 - bx) * SS - 1, (y1 - by) * SS - 1], r * SS, fill=255), fill, alpha)

    def dot(self, cx: float, cy: float, r: float, fill: Color, alpha: float = 1.0) -> None:
        self._shape((cx - r, cy - r, cx + r, cy + r), lambda d, bx, by: d.ellipse(
            [(cx - r - bx) * SS, (cy - r - by) * SS, (cx + r - bx) * SS - 1, (cy + r - by) * SS - 1], fill=255), fill, alpha)

    def ring(self, cx: float, cy: float, r: float, thick: float, frac: float, fill: Color, track: Optional[Color] = SEP) -> None:
        def arc(color_frac: float):
            def fn(d, bx, by):
                box = [(cx - r - bx) * SS, (cy - r - by) * SS, (cx + r - bx) * SS, (cy + r - by) * SS]
                if color_frac >= 0.999:
                    d.ellipse(box, outline=255, width=int(thick * SS))
                else:
                    d.arc(box, -90, -90 + 360 * color_frac, fill=255, width=int(thick * SS))
            return fn
        bounds = (cx - r - 1, cy - r - 1, cx + r + 1, cy + r + 1)
        if track:
            self._shape(bounds, arc(1.0), track)
        self._shape(bounds, arc(frac), fill)

    def poly(self, pts: List[Tuple[float, float]], fill: Color, width: float = 1.6, alpha: float = 1.0) -> None:
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        box = (min(xs) - width, min(ys) - width, max(xs) + width, max(ys) + width)
        self._shape(box, lambda d, bx, by: d.line([((x - bx) * SS, (y - by) * SS) for x, y in pts], fill=255,
                                                   width=max(1, int(width * SS)), joint="curve"), fill, alpha)

    def chart(self, box: Tuple[int, int, int, int], values: List[Optional[float]], color: Color, ref: Optional[float] = None) -> None:
        """Line with a soft fill under it and a dashed 'your usual' line, like the app's trend charts."""
        x0, y0, x1, y1 = box
        vals = [v for v in values if v is not None]
        if len(vals) < 2:
            self.text((x0 + x1) / 2, (y0 + y1) / 2, "Not enough data yet", 9, "Medium", FAINT, "mm")
            return
        if len(vals) > 72:                                           # raw 1 s sensor data: average into ~60 buckets
            step = len(vals) / 60.0
            vals = [sum(vals[int(i * step):max(int(i * step) + 1, int((i + 1) * step))]) / max(1, len(vals[int(i * step):max(int(i * step) + 1, int((i + 1) * step))]))
                    for i in range(60)]
        pool = vals + ([ref] if ref is not None else [])
        lo, hi = min(pool), max(pool)
        if hi - lo < 1e-9:
            lo, hi = lo - 1, hi + 1
        span = (hi - lo) * 1.12
        lo -= (hi - lo) * 0.06
        n = len(vals)

        def py(v: float) -> float:
            return y1 - (v - lo) / span * (y1 - y0)
        pts = [(x0 + i * (x1 - x0) / (n - 1), py(v)) for i, v in enumerate(vals)]
        if ref is not None:
            yr = py(ref)
            for x in range(x0, x1, 4):
                self.d.line([(x, yr), (x + 1, yr)], fill=FAINT)
        self._shape((x0, y0, x1, y1 + 1), lambda d, bx, by: d.polygon(
            [((x - bx) * SS, (y - by) * SS) for x, y in pts] + [((x1 - bx) * SS, (y1 + 1 - by) * SS), ((x0 - bx) * SS, (y1 + 1 - by) * SS)],
            fill=255), color, alpha=0.20)
        self.poly(pts, color, 1.7)
        self.dot(pts[-1][0], pts[-1][1], 2.4, color)

    def check(self, cx: float, cy: float, s: float, fill: Color, width: float = 2.2) -> None:
        self.poly([(cx - s * .55, cy + s * .02), (cx - s * .12, cy + s * .45), (cx + s * .6, cy - s * .4)], fill, width)


# --------------------------------------------------------------------------------------------------------------
# Pieces shared by the pages
# --------------------------------------------------------------------------------------------------------------

def _header(c: Canvas, title: str, state: HubState, now: float, blink: bool) -> None:
    if blink:
        c.rrect((PAD, 2, c.w - PAD, 17), 5, LEVEL[3])
    c.text(PAD + 3, 10, c.fit(title, 12, "Bold", 96), 12, "Bold", TEXT)
    c.text(c.w - PAD - 3, 10, time.strftime("%H:%M", time.localtime(now)), 10, "Medium", TEXT if blink else DIM, "rm")
    x = c.w - PAD - 3 - c.width("00:00", 10, "Medium") - 8
    c.dot(x, 10, 2.4, BLUE if state.clients else FAINT)
    c.dot(x - 8, 10, 2.4, LEVEL[0] if state.uno_connected else FAINT)


def _dots(c: Canvas, page: int, n: int) -> None:
    gap, w_active, w_dot = 4, 10, 4
    total = (n - 1) * (w_dot + gap) + w_active
    x = (c.w - total) / 2
    for i in range(n):
        if i == page:
            c.rrect((x, 122, x + w_active, 125), 1.5, TEXT)
            x += w_active + gap
        else:
            c.rrect((x, 122, x + w_dot, 125), 1.5, FAINT)
            x += w_dot + gap


def _card(c: Canvas, box: Tuple[int, int, int, int], r: int = 7) -> None:
    c.rrect(box, r, CARD)


def _chip(c: Canvas, xr: float, cy: float, text: str, color: Color) -> None:
    w = c.width(text, 9, "Bold") + 12
    c.rrect((xr - w, cy - 7, xr, cy + 7), 7, color, alpha=0.22)
    c.text(xr - w / 2, cy, text, 9, "Bold", color, "mm")


def _list(c: Canvas, nav: Nav, items: List[Tuple[str, Any]], cur: int, row: Callable[[str, Any], Tuple[str, str, int, bool]],
          empty: str, row_h: int = RH) -> None:
    box = (PAD, TOP, c.w - PAD, BOTTOM)
    _card(c, box)
    if not items:
        c.text(c.w / 2, (TOP + BOTTOM) / 2, empty, 11, "Medium", DIM, "mm")
        return

    def height(it: Tuple[str, Any]) -> int:
        return 13 if it[0] == "group" else row_h
    avail = BOTTOM - TOP - 2
    start = nav.top.get(nav.name, 0)
    start = min(start, cur)
    if start > 0 and cur == start and items[start - 1][0] == "group":
        start -= 1
    while start < cur and sum(height(items[i]) for i in range(start, cur + 1)) > avail:
        start += 1
    nav.top[nav.name] = start
    y = TOP + 1
    last = start
    for i in range(start, len(items)):
        kind, payload = items[i]
        h = height(items[i])
        if y + h > BOTTOM - 1:
            break
        last = i
        if kind == "group":
            c.text(PAD + 9, y + h - 4, str(payload).upper(), 8, "Bold", FAINT, "ls")
            y += h
            continue
        left, right, lvl, marked = row(kind, payload)
        sel = i == cur
        if sel:
            c.rrect((PAD + 2, y, c.w - PAD - 2, y + h), 5, BLUE)
        elif i + 1 < len(items) and i + 1 != cur and items[i + 1][0] != "group" and y + h + 1 < BOTTOM - 1:
            c.d.line([(PAD + 14, y + h - 1), (c.w - PAD - 8, y + h - 1)], fill=SEP)
        cy = y + h / 2
        if marked:
            c.check(PAD + 9, cy, 4.6, TEXT if sel else BLUE, 1.8)
        elif lvl > 0:
            c.dot(PAD + 9, cy, 2.6, TEXT if sel else LEVEL[lvl])
        rcol = TEXT if sel else (LEVEL[lvl] if lvl > 0 else DIM)
        rw = c.text(c.w - PAD - 8, cy, right, 11, "Medium", rcol, "rm") if right else 0
        room = c.w - 2 * PAD - 14 - 10 - (c.width(right, 11, "Medium") + 6 if right else 0)
        c.text(PAD + 15, cy, c.fit(left, 11, "Regular", room), 11, "Regular", TEXT)
        y += h
    if start > 0 or last < len(items) - 1:                          # scroll indicator
        total = len(items)
        th = max(8, (BOTTOM - TOP - 8) * (last - start + 1) / total)
        ty = TOP + 4 + (BOTTOM - TOP - 8 - th) * (start / max(1, total - (last - start + 1)))
        c.rrect((c.w - PAD - 3, ty, c.w - PAD - 1, ty + th), 1, FAINT)


# --------------------------------------------------------------------------------------------------------------
# Pages
# --------------------------------------------------------------------------------------------------------------

def _splash(c: Canvas) -> None:
    path = os.path.join(os.path.dirname(__file__), "assets", "helios-mark.png")
    if os.path.exists(path):
        m = Image.open(path).convert("RGBA")
        size = 58
        m = m.resize((size, size), Image.LANCZOS)
        c.img.paste(m, ((c.w - size) // 2, 22), m)
    c.text(c.w / 2, 94, "Helios", 18, "Bold", TEXT, "mm")
    c.text(c.w / 2, 110, "Crew health, on board", 9, "Medium", DIM, "mm")


def _home(c: Canvas, state: HubState, p: Dict[str, Any], alerts: List[Alert]) -> None:
    name = (p.get("person") or {}).get("name") or "No crew yet"
    day = (p.get("mission") or {}).get("day")
    lvl = state.overall_level()
    overall = p.get("overall") or {}
    if p and int(overall.get("level", 0) or 0) < 0 and lvl <= 0:
        lvl = -1
    col = LEVEL[lvl if lvl in LEVEL else 0]
    c.text(PAD + 3, 29, name, 12, "Bold", TEXT)
    if day:
        c.text(c.w - PAD - 3, 29, f"Day {day}", 10, "Medium", DIM, "rm")
    # status ring + word
    cx, cy = 30, 60
    c.ring(cx, cy, 18, 5, 1.0 if lvl >= 0 else 0.0, col)
    if lvl == 0:
        c.check(cx, cy, 11, col, 3.0)
    elif lvl > 0:
        c.text(cx, cy + 1, "!", 22, "Bold", col, "mm")
    else:
        c.text(cx, cy, "–", 18, "Bold", DIM, "mm")
    c.text(58, 50, WORDS.get(lvl, ""), 18, "Bold", col, "lm")
    if alerts:
        line = f"{len(alerts)} alert{'s' if len(alerts) > 1 else ''}"
        c.text(58, 68, line + " · press", 10, "Medium", BLUE)
        sub = overall.get("title") or overall.get("summary") or ""
        if sub:
            c.text(58, 80, c.fit(sub, 9, "Regular", c.w - 58 - PAD), 9, "Regular", DIM)
    else:
        sub = overall.get("title") or overall.get("summary") or ("Open the iPhone app" if not p else "")
        for i, line in enumerate(c.wrap(sub, 10, "Regular", c.w - 58 - PAD, 2)):
            c.text(58, 68 + i * 12, line, 10, "Regular", DIM)
    # two cards: cabin, radiation
    hab = max(state.levels.values()) if state.levels else None
    ratio = state.ratio()
    for i, (cap, value, vlvl) in enumerate((
            ("Cabin", "—" if hab is None else SENSOR_WORDS[hab], 0 if hab is None else hab),
            ("Radiation", f"{ratio:.1f}×" if ratio else "—", state.levels.get("rad_dose_rate", 0) if ratio else 0))):
        x0 = PAD + i * ((c.w - 2 * PAD) // 2 + 1)
        x1 = x0 + (c.w - 2 * PAD) // 2 - 1
        _card(c, (x0, 88, x1, 116), 7)
        c.text(x0 + 8, 98, cap.upper(), 8, "Bold", FAINT)
        c.dot(x0 + 11, 109, 2.6, LEVEL[vlvl] if (hab is not None or i == 1 and ratio) else FAINT)
        c.text(x0 + 18, 109, value, 11, "Bold", TEXT)


def _alerts(c: Canvas, nav: Nav, items: List[Tuple[str, Any]], cur: int) -> None:
    if not items:
        c.ring(c.w / 2, 56, 17, 4, 1.0, LEVEL[0])
        c.check(c.w / 2, 56, 10, LEVEL[0], 3.0)
        c.text(c.w / 2, 88, "All quiet", 13, "Bold", TEXT, "mm")
        c.text(c.w / 2, 103, "Nothing needs your attention", 9, "Regular", DIM, "mm")
        return
    rh = 30
    box = (PAD, TOP, c.w - PAD, BOTTOM - 12)
    _card(c, box)
    shown = (box[3] - box[1] - 2) // rh
    start = nav.top.get("alerts", 0)
    start = min(start, cur)
    if cur >= start + shown:
        start = cur - shown + 1
    nav.top["alerts"] = start
    for j, (_, a) in enumerate(items[start:start + shown]):
        y = TOP + 1 + j * rh
        sel = start + j == cur
        if sel:
            c.rrect((PAD + 2, y, c.w - PAD - 2, y + rh - 1), 5, BLUE)
        c.rrect((PAD + 7, y + 6, PAD + 10, y + rh - 7), 1.5, TEXT if sel else LEVEL[a.level])
        for k, line in enumerate(c.wrap(a.text, 10, "Medium", c.w - 2 * PAD - 26, 2)):
            c.text(PAD + 16, y + 10 + k * 11, line, 10, "Medium", TEXT)
    c.text(c.w / 2, BOTTOM - 4, f"{cur + 1} of {len(items)} · press to acknowledge", 8, "Medium", FAINT, "mm")


def _radiation(c: Canvas, state: HubState) -> None:
    rate = state.latest.get("rad_dose_rate")
    if rate is None:
        _card(c, (PAD, TOP, c.w - PAD, BOTTOM))
        c.text(c.w / 2, 66, "No detector", 12, "Medium", DIM, "mm")
        return
    lvl = state.levels.get("rad_dose_rate", 0)
    ratio = state.ratio()
    c.text(PAD + 3, 33, f"{rate:.3f}", 26, "Bold", TEXT)
    c.text(PAD + 3 + c.width(f"{rate:.3f}", 26, "Bold") + 4, 38, "µSv/h", 10, "Medium", DIM)
    if ratio:
        _chip(c, c.w - PAD, 29, f"{ratio:.1f}× normal", LEVEL[lvl] if lvl else LEVEL[0])
    _card(c, (PAD, 52, c.w - PAD, BOTTOM))
    c.chart((PAD + 7, 60, c.w - PAD - 7, 92), state.series("rad_dose_rate", 900), BLUE if not lvl else LEVEL[lvl], ref=state.background)
    c.text(PAD + 8, 104, "Last 15 min", 9, "Medium", FAINT)
    c.text(c.w - PAD - 8, 104, f"Total {state.cum_dose:.2f} µSv", 9, "Medium", DIM, "rm")


def _detail(c: Canvas, state: HubState, key: str, metrics: Dict[str, Any]) -> None:
    if key in env.SENSORS:
        series = state.series(key, 1800)
        value = env.fmt(key, state.latest.get(key), unit=False)
        unit = env.SENSORS[key].unit
        lvl = state.levels.get(key, 0)
        foot = "Last 30 min"
        usual = None
        word = SENSOR_WORDS.get(lvl, "")
    else:
        m = dict(metrics.get(key, {}), id=key)
        value, unit = split_metric(m)
        lvl = int(m.get("level", 0) or 0)
        usual = m.get("usual")
        series = m.get("spark") or []
        foot = "Last 14 days"
        word = SENSOR_WORDS.get(lvl, "")
    col = LEVEL[lvl] if lvl else BLUE
    c.text(PAD + 3, 34, value, 28, "Bold", TEXT)
    c.text(PAD + 3 + c.width(value, 28, "Bold") + 4, 40, unit, 11, "Medium", DIM)
    _chip(c, c.w - PAD, 28, word or "Good", LEVEL[lvl])
    if usual is not None:
        c.text(c.w - PAD - 2, 44, "Usual " + metric_text(dict(metrics.get(key, {}), id=key), usual), 9, "Medium", DIM, "rm")
    _card(c, (PAD, 54, c.w - PAD, BOTTOM))
    c.chart((PAD + 7, 62, c.w - PAD - 7, 94), series, col, ref=usual)
    c.text(PAD + 8, 106, foot, 9, "Medium", FAINT)
    if usual is not None:
        c.text(c.w - PAD - 8, 106, "- - usual", 9, "Medium", FAINT, "rm")


def _hub(c: Canvas, state: HubState, net: Dict[str, Any]) -> None:
    _card(c, (PAD, TOP, c.w - PAD, 66))
    c.text(PAD + 9, 28, "HUB CODE", 8, "Bold", FAINT)
    code = str(net.get("token", "------"))
    x = PAD + 9
    for ch in code:
        x += c.text(x, 48, ch, 24, "Bold", TEXT) + 3
    _card(c, (PAD, 70, c.w - PAD, BOTTOM))
    public = net.get("public") or ""
    c.text(PAD + 9, 80, c.fit(public or f"{net.get('host', 'helios')}.local", 11, "Medium", c.w - 2 * PAD - 18), 11, "Medium", TEXT)
    c.text(PAD + 9, 93, f"{net.get('ip', '--')}:{net.get('port', 8765)}", 9, "Regular", DIM)
    up = int(time.time() - state.started)
    c.dot(PAD + 12, 106, 2.6, BLUE if state.clients else FAINT)
    c.text(PAD + 19, 106, f"{len(state.clients)} phone{'s' if len(state.clients) != 1 else ''}", 9, "Medium", TEXT)
    c.dot(PAD + 66, 106, 2.6, LEVEL[0] if state.uno_connected else FAINT)
    c.text(PAD + 73, 106, "Uno" if state.uno_connected else "No Uno", 9, "Medium", TEXT)
    c.text(c.w - PAD - 8, 106, f"{up // 3600}h {up % 3600 // 60:02d}m", 9, "Medium", DIM, "rm")


# --------------------------------------------------------------------------------------------------------------

def render(state: HubState, nav: Nav, size: Tuple[int, int] = (160, 128), now: Optional[float] = None,
           net: Optional[Dict[str, Any]] = None) -> Image.Image:
    now = now or time.time()
    c = Canvas(*size)
    alerts = state.alerts()
    if nav.asleep and not alerts:
        return c.img
    if now - state.started < 3.0 and nav.page == 0 and not alerts:
        _splash(c)
        return c.img
    from .pages import PAGES
    page = nav.name
    blink = bool(alerts) and max(a.level for a in alerts) >= 3 and int(now * 2) % 2 == 0
    p = state.person() or {}
    metrics = p.get("metrics") or {}
    title = TITLES[page].title() if page != "home" else "Helios"
    if page == "hub":
        title = "Connect"
    if nav.detail is not None:
        title = (env.SENSORS[nav.detail].label if nav.detail in env.SENSORS
                 else metrics.get(nav.detail, {}).get("label", nav.detail))
    _header(c, title, state, now, blink)
    items = list_items(state, page)
    cur = cursor(nav, items)

    if nav.detail is not None:
        _detail(c, state, nav.detail, metrics)
    elif page == "home":
        _home(c, state, p, alerts)
    elif page == "alerts":
        _alerts(c, nav, items, cur)
    elif page == "cabin":
        def srow(k: str, s: str) -> Tuple[str, str, int, bool]:
            return SENSOR_NAMES.get(s, env.SENSORS[s].label), env.fmt(s, state.latest.get(s)), state.levels.get(s, 0), False
        _list(c, nav, items, cur, srow, "Waiting for sensors")
    elif page == "radiation":
        _radiation(c, state)
    elif page in ("vitals", "activity", "health"):
        def mrow(k: str, mid: str) -> Tuple[str, str, int, bool]:
            m = dict(metrics.get(mid, {}), id=mid)
            text = split_metric(m)[0] if mid == "bp_sys" else metric_text(m)
            return m.get("label", mid), text, int(m.get("level", 0) or 0), False
        _list(c, nav, items, cur, mrow, "No data from the phone yet" if not state.snapshots else "Nothing recorded")
    elif page == "crew":
        def prow(k: str, key: str) -> Tuple[str, str, int, bool]:
            s = state.snapshots.get(key) or {}
            lvl = int((s.get("overall") or {}).get("level", 0) or 0)
            return (s.get("person") or {}).get("name", "Crew"), WORDS.get(lvl, ""), max(lvl, 0), key == state.current_person
        _list(c, nav, items, cur, prow, "Connect the iPhone app")
    elif page == "demo":
        _list(c, nav, items, cur, lambda k, s: (SCENARIO_LABELS[s], "", 0, s == state.scenario), "")
    elif page == "hub":
        _hub(c, state, net or {})
    if nav.toast and now - nav.toast[1] < 2.0:
        text = c.fit(nav.toast[0], 10, "Medium", c.w - 40)
        w = c.width(text, 10, "Medium") + 20
        c.rrect(((c.w - w) / 2, 55, (c.w + w) / 2, 75), 10, (58, 58, 60))
        c.text(c.w / 2, 65, text, 10, "Medium", TEXT, "mm")
    if nav.detail is None:
        _dots(c, nav.page, len(PAGES))
    return c.img
