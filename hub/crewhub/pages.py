"""OLED pages. Pure: (hub state, navigation) → 1-bit PIL image, so every page can be tested and previewed as a PNG.

Joystick: left/right = previous/next page · up/down = move through a list · press = open / act · hold = back home.
Designed for 128x64 and still usable on 128x32 (fewer rows, same pages).
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

from PIL import Image, ImageDraw

from . import environment as env
from .font5x7 import FONT
from .protocol import SCENARIO_LABELS, SCENARIOS
from .state import Alert, HubState

PAGES = ["home", "alerts", "cabin", "radiation", "vitals", "activity", "health", "crew", "demo", "hub"]
TITLES = {"home": "HELIOS", "alerts": "ALERTS", "cabin": "CABIN AIR", "radiation": "RADIATION", "vitals": "VITALS",
          "activity": "ACTIVITY", "health": "HEALTH", "crew": "CREW", "demo": "DEMO", "hub": "CONNECT"}
STATUS_WORDS = {-1: "LEARNING", 0: "ALL GOOD", 1: "WATCH", 2: "ACT", 3: "CALL NOW"}
VITALS = ["heart_rate_resting", "hrv", "spo2", "resp_rate", "body_temp", "wrist_temp", "bp_sys", "heart_rate", "walking_hr",
          "vo2max", "glucose", "weight", "breathing_disturbances"]
ACTIVITY = ["sleep_hours", "sleep_deep_h", "sleep_rem_h", "in_bed_h", "activity_steps", "active_kcal", "exercise_min", "workout_min",
            "distance_km", "flights", "stand_hours", "daylight_min", "mindful_min", "mood", "stress", "water_l", "diet_kcal"]
CABIN = ["cabin_temp", "humidity", "pressure", "co2", "o2", "noise", "light"]
CH, LH = 6, 9          # character width, line height (5x7 glyph + spacing)


# --------------------------------------------------------------------------------------------------------------
# Canvas
# --------------------------------------------------------------------------------------------------------------

def _glyphs(text: str) -> bytes:
    return text.replace("µ", "u").replace("₂", "2").replace("·", "-").replace("–", "-").replace("—", "-") \
        .encode("cp437", errors="replace")


class Canvas:
    def __init__(self, w: int, h: int):
        self.w, self.h = w, h
        self.img = Image.new("1", (w, h), 0)
        self.d = ImageDraw.Draw(self.img)

    def text(self, x: int, y: int, s: str, scale: int = 1, color: int = 1) -> int:
        px = self.img.load()
        for code in _glyphs(s):
            if x > self.w:
                break
            for col in range(5):
                bits = FONT[code * 5 + col]
                for row in range(8):
                    if bits >> row & 1:
                        for dx in range(scale):
                            for dy in range(scale):
                                xx, yy = x + col * scale + dx, y + row * scale + dy
                                if 0 <= xx < self.w and 0 <= yy < self.h:
                                    px[xx, yy] = color
            x += CH * scale
        return x

    def rtext(self, xr: int, y: int, s: str, scale: int = 1, color: int = 1) -> None:
        self.text(xr - len(_glyphs(s)) * CH * scale + scale, y, s, scale, color)

    def ctext(self, y: int, s: str, scale: int = 1, color: int = 1) -> None:
        self.text((self.w - len(_glyphs(s)) * CH * scale + scale) // 2, y, s, scale, color)

    def bar(self, y: int, h: int = LH) -> None:
        self.d.rectangle([0, y - 1, self.w - 1, y + h - 2], fill=1)

    def spark(self, values: List[float], box: Tuple[int, int, int, int], ref: Optional[float] = None) -> None:
        x0, y0, x1, y1 = box
        vals = [v for v in values if v is not None]
        if len(vals) < 2:
            self.text(x0, (y0 + y1) // 2 - 3, "Not enough data yet")
            return
        lo, hi = min(vals + ([ref] if ref is not None else [])), max(vals + ([ref] if ref is not None else []))
        if hi - lo < 1e-9:
            hi, lo = hi + 1, lo - 1
        def py(v: float) -> int:
            return int(round(y1 - (v - lo) / (hi - lo) * (y1 - y0)))
        if ref is not None:
            yr = py(ref)
            for x in range(x0, x1, 3):
                self.d.point((x, yr), fill=1)
        n = len(vals)
        pts = [(x0 + int(i * (x1 - x0) / (n - 1)), py(v)) for i, v in enumerate(vals)]
        self.d.line(pts, fill=1)
        self.d.rectangle([pts[-1][0] - 1, pts[-1][1] - 1, pts[-1][0] + 1, pts[-1][1] + 1], fill=1)


# --------------------------------------------------------------------------------------------------------------
# Navigation
# --------------------------------------------------------------------------------------------------------------

@dataclass
class Nav:
    page: int = 0
    cursor: Dict[str, int] = field(default_factory=dict)
    detail: Optional[str] = None
    last_input: float = field(default_factory=time.time)
    asleep: bool = False
    toast: Optional[Tuple[str, float]] = None

    @property
    def name(self) -> str:
        return PAGES[self.page]

    def go(self, name: str) -> None:
        self.page, self.detail = PAGES.index(name), None


def list_items(state: HubState, page: str) -> List[Tuple[str, Any]]:
    """Selectable rows for list pages: (kind, payload). Kind 'group' rows are headings (not selectable targets)."""
    p = state.person() or {}
    metrics = p.get("metrics") or {}
    if page == "alerts":
        return [("alert", a) for a in state.alerts()]
    if page == "cabin":
        return [("sensor", s) for s in CABIN if s in state.latest]
    if page == "vitals":
        return [("metric", m) for m in VITALS if m in metrics]
    if page == "activity":
        return [("metric", m) for m in ACTIVITY if m in metrics]
    if page == "health":
        out: List[Tuple[str, Any]] = []
        by_group: Dict[str, List[str]] = {}
        for mid, m in metrics.items():
            by_group.setdefault(m.get("group") or "Other", []).append(mid)
        for g in sorted(by_group):
            out.append(("group", g))
            out += [("metric", mid) for mid in sorted(by_group[g], key=lambda i: metrics[i].get("label", i))]
        return out
    if page == "crew":
        return [("person", k) for k in state.snapshots]
    if page == "demo":
        return [("scenario", s) for s in SCENARIOS]
    return []


def cursor(nav: Nav, items: List[Tuple[str, Any]]) -> int:
    """The highlighted row; never a group heading."""
    cur = min(nav.cursor.get(nav.name, 0), max(0, len(items) - 1))
    while items and items[cur][0] == "group" and cur < len(items) - 1:
        cur += 1
    return cur


def handle(nav: Nav, key: str, state: HubState) -> Optional[Tuple[str, ...]]:
    """Applies one joystick event. Returns an action for the hub to perform, if any."""
    nav.last_input = time.time()
    if nav.asleep:
        nav.asleep = False
        return None
    page = nav.name
    items = list_items(state, page)
    cur = cursor(nav, items)
    if key == "H":
        if nav.page == 0 and nav.detail is None:
            nav.asleep = True
        nav.go("home")
        return None
    if key in ("L", "R"):
        if nav.detail is not None:
            nav.detail = None
            if key == "L":
                return None
        nav.page = (nav.page + (1 if key == "R" else -1)) % len(PAGES)
        nav.detail = None
        return None
    if key in ("U", "D") and items:
        step = 1 if key == "D" else -1
        nxt = cur
        for _ in range(len(items)):
            nxt = (nxt + step) % len(items)
            if items[nxt][0] != "group":
                break
        nav.cursor[page] = nxt
        if nav.detail is not None and items[nxt][0] in ("metric", "sensor"):
            nav.detail = items[nxt][1]
        return None
    if key == "P":
        if page == "home":
            if state.alerts():
                nav.go("alerts")
            return None
        if nav.detail is not None:
            nav.detail = None
            return None
        if not items:
            return None
        kind, payload = items[cur]
        if kind == "group":
            return None
        if kind in ("metric", "sensor"):
            nav.detail = payload
            return None
        if kind == "alert":
            a: Alert = payload
            nav.toast = ("Acknowledged", time.time())
            return ("ack", a.key)
        if kind == "person":
            nav.toast = ("Showing " + ((state.snapshots.get(payload) or {}).get("person") or {}).get("name", "crew"), time.time())
            return ("select", payload)
        if kind == "scenario":
            nav.toast = (SCENARIO_LABELS[payload], time.time())
            return ("scenario", payload)
    return None


# --------------------------------------------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------------------------------------------

def fmt_metric(m: Dict[str, Any], value: Optional[float] = None) -> str:
    v = m.get("value") if value is None else value
    if v is None:
        return "--"
    d = int(m.get("decimals", 0) or 0)
    unit = m.get("unit") or ""
    if unit in ("1–5", "1-5"):
        return f"{v:.{d}f}/5"
    if m.get("id") == "bp_sys" and m.get("pair") is not None:
        return f"{v:.0f}/{m['pair']:.0f}"
    unit = {"breaths/min": "/m", "steps": "", "count": "", "floors": "fl", "mL/kg/min": "", "°C": "C"}.get(unit, unit)
    text = f"{v:,.{d}f}" if abs(v) >= 10000 else f"{v:.{d}f}"
    return f"{text}{unit if unit in ('%', 'C', 'h') else (' ' + unit if unit else '')}"


def mark(level: int) -> str:
    return {1: "!", 2: "!!", 3: "!!!"}.get(level, "")


def _rows(c: Canvas) -> int:
    return max(1, (c.h - 12) // LH)


def _header(c: Canvas, title: str, state: HubState, now: float, blink: bool) -> None:
    # The header is a solid bar; during an unacknowledged "call" alert it flashes to an outline twice a second.
    if blink:
        c.d.rectangle([0, 0, c.w - 1, LH], outline=1, fill=0)
    else:
        c.bar(1)
    col = 1 if blink else 0
    right = time.strftime("%H:%M", time.localtime(now))
    links = ("P" if state.clients else "") + ("U" if state.uno_connected else "")
    right = (links + " " if links else "") + right
    room = (c.w - 4) // CH - len(right) - 1
    c.text(2, 1, title[:room], color=col)
    c.rtext(c.w - 2, 1, right, color=col)


def _dots(c: Canvas, page: int) -> None:
    if c.h < 64:
        return
    w = len(PAGES) * 5
    x = (c.w - w) // 2
    for i in range(len(PAGES)):
        if i == page:
            c.d.rectangle([x + i * 5, 61, x + i * 5 + 2, 63], fill=1)
        else:
            c.d.point((x + i * 5 + 1, 62), fill=1)


def _list(c: Canvas, items: List[Tuple[str, Any]], cur: int, row_text, empty: str) -> None:
    rows = _rows(c)
    if not items:
        c.ctext(12 + (rows * LH) // 2 - 4, empty)
        return
    top = min(max(0, cur - rows + 1), max(0, len(items) - rows))
    top = min(top, cur)
    for i, (kind, payload) in enumerate(items[top: top + rows]):
        y = 12 + i * LH
        selected = top + i == cur
        if kind == "group":
            c.text(2, y, "-" + str(payload).upper()[:19])
            continue
        left, right = row_text(kind, payload)
        if selected:
            c.bar(y)
        col = 0 if selected else 1
        c.text(2, y, left[: max(1, 20 - len(right))], color=col)
        c.rtext(c.w - 2, y, right, color=col)
    if len(items) > rows:          # scrollbar
        h = max(3, int((rows / len(items)) * (rows * LH)))
        y = 11 + int((top / max(1, len(items) - rows)) * (rows * LH - h))
        c.d.line([(c.w - 1, y), (c.w - 1, y + h)], fill=1)


def render(state: HubState, nav: Nav, size: Tuple[int, int] = (128, 64), now: Optional[float] = None,
           net: Optional[Dict[str, Any]] = None) -> Image.Image:
    now = now or time.time()
    c = Canvas(*size)
    if nav.asleep and not state.alerts():
        return c.img
    if now - state.started < 3.0 and nav.page == 0 and not state.alerts():
        from .logo import mark
        m = mark()
        room = c.h - (16 if c.h >= 64 else 0)          # leave a line for the name on the taller screen
        if m.height > room:
            m = m.resize((max(1, m.width * room // m.height), room), Image.LANCZOS).convert("1")
        c.img.paste(m, ((c.w - m.width) // 2, (room - m.height) // 2 + 1))
        if c.h >= 64:
            c.ctext(c.h - 12, "HELIOS")
        return c.img
    page = nav.name
    alerts = state.alerts()
    blink = bool(alerts) and max(a.level for a in alerts) >= 3 and int(now * 2) % 2 == 0
    title = TITLES[page]
    p = state.person() or {}
    metrics = p.get("metrics") or {}
    if nav.detail is not None:
        title = (env.SENSORS[nav.detail].short.upper() if nav.detail in env.SENSORS
                 else (metrics.get(nav.detail, {}).get("label", nav.detail)).upper())
    _header(c, title, state, now, blink)
    items = list_items(state, page)
    cur = cursor(nav, items)

    if nav.detail is not None:
        _detail(c, state, nav.detail, metrics)
    elif page == "home":
        _home(c, state, p, alerts)
    elif page == "alerts":
        _alerts(c, items, cur)
    elif page == "cabin":
        _list(c, items, cur, lambda k, s: (env.SENSORS[s].short, env.fmt(s, state.latest.get(s)).replace("°", "") +
                                           (" " + mark(state.levels.get(s, 0)) if state.levels.get(s, 0) else "")), "Waiting for sensors")
    elif page == "radiation":
        _radiation(c, state)
    elif page in ("vitals", "activity", "health"):
        def row(k: str, mid: str) -> Tuple[str, str]:
            m = dict(metrics.get(mid, {}), id=mid)
            lvl = int(m.get("level", 0) or 0)
            return (m.get("short") or m.get("label", mid), fmt_metric(m) + (" " + mark(lvl) if lvl > 0 else ""))
        empty = "No data from phone" if not state.snapshots else "Nothing recorded"
        _list(c, items, cur, row, empty)
    elif page == "crew":
        def prow(k: str, key: str) -> Tuple[str, str]:
            s = state.snapshots.get(key) or {}
            name = (s.get("person") or {}).get("name", "Crew")
            lvl = int((s.get("overall") or {}).get("level", 0) or 0)
            return (("> " if key == state.current_person else "  ") + name, STATUS_WORDS.get(lvl, "")[:8])
        _list(c, items, cur, prow, "Connect the iPhone app")
    elif page == "demo":
        _list(c, items, cur, lambda k, s: (SCENARIO_LABELS[s], "*" if s == state.scenario else ""), "")
    elif page == "hub":
        _hub(c, state, net or {})
    if nav.toast and now - nav.toast[1] < 2.0:
        text = nav.toast[0][:20]
        w = len(text) * CH + 6
        x0, y0 = (c.w - w) // 2, c.h // 2 - 6
        c.d.rectangle([x0, y0, x0 + w, y0 + 12], fill=0, outline=1)
        c.text(x0 + 4, y0 + 3, text)
    if nav.detail is None:
        _dots(c, nav.page)
    return c.img


def _wrap(text: str, width: int) -> List[str]:
    lines, line = [], ""
    for word in text.split():
        if len(line) + len(word) + (1 if line else 0) <= width:
            line = f"{line} {word}" if line else word
        else:
            if line:
                lines.append(line)
            line = word[:width]
    if line:
        lines.append(line)
    return lines


def _alerts(c: Canvas, items: List[Tuple[str, Any]], cur: int) -> None:
    """Two lines per alert; press acknowledges the highlighted one."""
    if not items:
        c.ctext(28 if c.h >= 64 else 12, "All quiet")
        return
    per = 2 if c.h >= 64 else 1
    shown = max(1, _rows(c) // per)
    top = min(cur, max(0, len(items) - shown))
    for i, (_, a) in enumerate(items[top: top + shown]):
        y = 12 + i * per * LH
        sel = top + i == cur
        lines = _wrap(f"{mark(a.level)} {a.text}", 20)[:per]
        if sel:
            c.d.rectangle([0, y - 1, c.w - 1, y + per * LH - 2], fill=1)
        for j, line in enumerate(lines):
            c.text(2, y + j * LH, line, color=0 if sel else 1)
    if c.h >= 64:
        c.text(2, 12 + shown * per * LH, f"{cur + 1}/{len(items)} press=ack"[:21])


def _home(c: Canvas, state: HubState, p: Dict[str, Any], alerts: List[Alert]) -> None:
    name = (p.get("person") or {}).get("name")
    lvl = state.overall_level()
    overall = p.get("overall") or {}
    if p and int(overall.get("level", 0) or 0) < 0 and lvl <= 0:
        lvl = -1
    word = STATUS_WORDS.get(lvl, "")
    if c.h < 64:
        c.ctext(12, word, scale=2)
        return
    c.text(2, 12, (name or "No crew yet")[:12])
    day = (p.get("mission") or {}).get("day")
    if day:
        c.rtext(c.w - 2, 12, f"Day {day}")
    c.ctext(23, word, scale=2)
    if alerts:
        line = f"{len(alerts)} alert{'s' if len(alerts) > 1 else ''} - press"
    elif p:
        line = overall.get("title") or overall.get("summary") or ""
    else:
        line = "Open the iPhone app"
    c.ctext(42, line[:21])
    hab = max([v for v in state.levels.values()] + [0]) if state.levels else None
    ratio = state.ratio()
    cabin = "--" if hab is None else env.LEVEL_NAMES[hab]
    c.text(2, 51, f"Cabin {cabin}"[:11])
    c.rtext(c.w - 2, 51, f"Rad {ratio:.1f}x" if ratio else "Rad --")


def _radiation(c: Canvas, state: HubState) -> None:
    rate = state.latest.get("rad_dose_rate")
    if rate is None:
        c.ctext(28, "No detector")
        return
    c.text(2, 12, f"{rate:.3f}", scale=2)
    c.rtext(c.w - 2, 12, "uSv/h")
    ratio = state.ratio()
    c.rtext(c.w - 2, 21, f"{ratio:.1f}x bg" if ratio else "learning")
    if c.h < 64:
        return
    c.spark(state.series("rad_dose_rate", 900), (2, 31, c.w - 3, 49), ref=state.background)
    c.text(2, 52, f"Total {state.cum_dose:.2f}uSv"[:21])
    lvl = state.levels.get("rad_dose_rate", 0)
    if lvl:
        c.rtext(c.w - 2, 52, env.LEVEL_NAMES[lvl])


def _detail(c: Canvas, state: HubState, key: str, metrics: Dict[str, Any]) -> None:
    if key in env.SENSORS:
        series = state.series(key, 1800)
        value = env.fmt(key, state.latest.get(key)).replace("°", "")
        lvl = state.levels.get(key, 0)
        c.text(2, 12, value)
        c.rtext(c.w - 2, 12, env.LEVEL_NAMES[lvl])
        if c.h >= 64:
            c.spark(series, (2, 23, c.w - 3, 52))
            c.text(2, 55, "last 30 min")
        return
    m = dict(metrics.get(key, {}), id=key)
    c.text(2, 12, fmt_metric(m))
    usual = m.get("usual")
    if usual is not None:
        c.rtext(c.w - 2, 12, "~" + fmt_metric(m, usual))
    if c.h >= 64:
        c.spark(m.get("spark") or [], (2, 23, c.w - 3, 52), ref=usual)
        c.text(2, 55, f"14 days {('- ' + str(m.get('note')))[:10] if m.get('note') else ''}")


def _hub(c: Canvas, state: HubState, net: Dict[str, Any]) -> None:
    up = int(time.time() - state.started)
    lines = [
        f"{net.get('host', 'crewhub')}.local",
        f"{net.get('ip', '--')}:{net.get('port', 8765)}",
        f"Code {net.get('token', '--')}",
        f"Phones {len(state.clients)}  Uno {'ok' if state.uno_connected else '--'}",
        f"Up {up // 3600}h{up % 3600 // 60:02d}m  {net.get('records', 0)} rec",
    ]
    for i, line in enumerate(lines[: _rows(c)]):
        c.text(2, 12 + i * LH, line[:21])
